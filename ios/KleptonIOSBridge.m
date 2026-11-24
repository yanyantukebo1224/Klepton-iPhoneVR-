// SPDX-License-Identifier: GPL-2.0-or-later
#import "KleptonIOSBridge.h"

#include "husk-tl-unity.h"
#include "kl_ovrp.h"
#include "kl_glfb.h"

#import <Metal/Metal.h>
#import <simd/simd.h>

#include <stdatomic.h>

static atomic_bool g_guest_started = false;

bool ki_start_unity_guest(const char *apkPath,
                          const char *dataDirectory,
                          const char *packageName,
                          int pixelWidth,
                          int pixelHeight,
                          CAMetalLayer *metalLayer,
                          const char *angleEGL,
                          const char *angleGLES) {
    if (!apkPath || !dataDirectory || !packageName ||
        pixelWidth <= 0 || pixelHeight <= 0) return false;

    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_guest_started, &expected, true)) {
        return false;
    }

    tl_unity_config config = {
        .apk_path = apkPath,
        .data_dir = dataDirectory,
        .package_name = packageName,
        .width = pixelWidth,
        .height = pixelHeight,
        .metal_layer = (__bridge void *)metalLayer,
        .angle_egl = angleEGL,
        .angle_gles = angleGLES,
        .frame_dir = NULL,
        .frame_every = 0,
    };

    if (!tl_unity_start(&config) || !tl_unity_run()) {
        atomic_store(&g_guest_started, false);
        return false;
    }
    return true;
}

void ki_stop_guest(void) {
    if (!atomic_exchange(&g_guest_started, false)) return;
    tl_unity_stop();
}

void ki_set_guest_paused(bool paused) {
    if (atomic_load(&g_guest_started)) tl_unity_set_paused(paused);
}

void ki_guest_touch(int phase, int fingerID, float x, float y) {
    if (atomic_load(&g_guest_started)) tl_unity_touch(phase, fingerID, x, y);
}

unsigned long ki_guest_frames(void) {
    return atomic_load(&g_guest_started) ? tl_unity_frames() : 0;
}

void ki_publish_head_pose(float px, float py, float pz,
                          float qx, float qy, float qz, float qw) {
    kl_ovrp_set_head_pose(px, py, pz, qx, qy, qz, qw);
}

void ki_publish_hand_pose(int hand, float px, float py, float pz,
                          float qx, float qy, float qz, float qw) {
    kl_ovrp_set_hand_pose(hand, px, py, pz, qx, qy, qz, qw);
}

static NSLock *g_iquest_eye_lock;
static NSMutableDictionary<NSString *, id<MTLTexture>> *g_iquest_eye_textures;
static NSMutableArray<id<MTLTexture>> *g_iquest_eye_lifetime;
static id<MTLDevice> g_iquest_device;
static id<MTLRenderPipelineState> g_iquest_pipeline;
static id<MTLSamplerState> g_iquest_sampler;
static id<MTLCommandQueue> g_iquest_queue;
static id<MTLSharedEvent> g_iquest_fence;
static CAMetalLayer *g_iquest_guest_layer;

static NSString *iquest_eye_key(int eye, int stage) {
    return [NSString stringWithFormat:@"%d:%d", eye, stage];
}

static MTLPixelFormat iquest_pixel_format(uint32_t glFormat) {
    switch (glFormat) {
        case 0x881A: return MTLPixelFormatRGBA16Float;       // GL_RGBA16F
        case 0x8C43: return MTLPixelFormatRGBA8Unorm_sRGB;   // GL_SRGB8_ALPHA8
        case 0x8058: return MTLPixelFormatRGBA8Unorm;        // GL_RGBA8
        default: return MTLPixelFormatInvalid;
    }
}

static int iquest_eye_texture_provider(int eye, int stage, int width, int height,
                                       uint32_t internalFormat,
                                       kl_mtl_eye_texture *out, void *context) {
    if (!out || width <= 0 || height <= 0) return 0;
    CAMetalLayer *guestLayer = (__bridge CAMetalLayer *)context;
    id<MTLDevice> device = guestLayer.device ?: MTLCreateSystemDefaultDevice();
    MTLPixelFormat format = iquest_pixel_format(internalFormat);
    if (!device || format == MTLPixelFormatInvalid) return 0;
    guestLayer.device = device;
    if (!g_iquest_eye_lock) {
        @synchronized([NSObject class]) {
            if (!g_iquest_eye_lock) {
                g_iquest_eye_lock = [NSLock new];
                g_iquest_eye_textures = [NSMutableDictionary new];
                g_iquest_eye_lifetime = [NSMutableArray new];
            }
        }
    }
    NSString *key = iquest_eye_key(eye, stage);
    [g_iquest_eye_lock lock];
    id<MTLTexture> texture = g_iquest_eye_textures[key];
    if (!texture || texture.width != (NSUInteger)width ||
        texture.height != (NSUInteger)height || texture.pixelFormat != format) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:(NSUInteger)width
                                                              height:(NSUInteger)height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        texture = [device newTextureWithDescriptor:descriptor];
        if (!texture) {
            [g_iquest_eye_lock unlock];
            return 0;
        }
        g_iquest_eye_textures[key] = texture;
        [g_iquest_eye_lifetime addObject:texture];
    }
    out->texture = (__bridge void *)texture;
    out->slice = 0;
    out->w = width;
    out->h = height;
    [g_iquest_eye_lock unlock];
    return 1;
}

void ki_install_metal_eye_provider(CAMetalLayer *guestLayer) {
    if (!guestLayer) return;
    g_iquest_guest_layer = guestLayer;
    if (!guestLayer.device) guestLayer.device = MTLCreateSystemDefaultDevice();
    g_iquest_device = guestLayer.device;
    if (!g_iquest_queue) g_iquest_queue = [g_iquest_device newCommandQueue];
    if (!g_iquest_fence && [g_iquest_device respondsToSelector:@selector(newSharedEvent)]) {
        g_iquest_fence = [g_iquest_device newSharedEvent];
        if (g_iquest_fence) kl_glfb_set_gpu_fence((__bridge void *)g_iquest_fence);
    }
    kl_glfb_set_mtl_provider(iquest_eye_texture_provider,
                             (__bridge void *)guestLayer);
}

static BOOL iquest_build_pipeline(CAMetalLayer *outputLayer) {
    if (g_iquest_pipeline) return YES;
    id<MTLDevice> device = outputLayer.device ?: g_iquest_device;
    if (!device) return NO;
    outputLayer.device = device;
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    id<MTLFunction> vertex = [library newFunctionWithName:@"iquest_stereo_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"iquest_stereo_fragment"];
    if (!vertex || !fragment) return NO;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = outputLayer.pixelFormat;
    g_iquest_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!g_iquest_pipeline) {
        NSLog(@"[iquest] stereo pipeline failed: %@", error);
        return NO;
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_iquest_sampler = [device newSamplerStateWithDescriptor:sampler];
    return g_iquest_sampler != nil;
}

void ki_render_stereo_frame(CAMetalLayer *outputLayer) {
    if (!outputLayer || !iquest_build_pipeline(outputLayer)) return;
    id<CAMetalDrawable> drawable = [outputLayer nextDrawable];
    if (!drawable) return;
    if (!g_iquest_queue) g_iquest_queue = [g_iquest_device newCommandQueue];
    id<MTLCommandBuffer> command = [g_iquest_queue commandBuffer];
    if (g_iquest_fence && kl_glfb_has_gpu_fence()) {
        uint64_t fenceValue = kl_glfb_gpu_fence_value();
        if (fenceValue > 0) [command encodeWaitForEvent:g_iquest_fence value:fenceValue];
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:g_iquest_pipeline];
    [encoder setFragmentSamplerState:g_iquest_sampler atIndex:0];

    int stage = kl_glfb_last_render_stage();
    if (stage < 0 || stage >= KL_MTL_MAX_STAGES) stage = 0;
    double halfWidth = (double)drawable.texture.width * 0.5;
    double height = (double)drawable.texture.height;
    for (int eye = 0; eye < 2; eye++) {
        int slice = 0;
        void *raw = kl_glfb_eye_mtl_texture(eye, stage, &slice);
        if (!raw) continue;
        id<MTLTexture> texture = (__bridge id<MTLTexture>)raw;
        if (texture.textureType == MTLTextureType2DArray ||
            texture.textureType == MTLTextureTypeCube) {
            id<MTLTexture> view = [texture newTextureViewWithPixelFormat:texture.pixelFormat
                                                            textureType:MTLTextureType2D
                                                                 levels:NSMakeRange(0, 1)
                                                                 slices:NSMakeRange((NSUInteger)slice, 1)];
            if (view) texture = view;
        }
        MTLViewport viewport = { eye * halfWidth, 0, halfWidth, height, 0, 1 };
        [encoder setViewport:viewport];
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
    }
    [encoder endEncoding];
    [command presentDrawable:drawable];
    [command commit];
}

int ki_get_tracking_origin(void) {
    return kl_ovrp_tracking_origin();
}
