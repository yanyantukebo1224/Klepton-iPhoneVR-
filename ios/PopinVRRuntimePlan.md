# PopinVR iOS runtime port plan

## What is already reusable

The Klepton core is largely platform-neutral C/Objective-C and already has:
- Android Bionic/JNI/NDK shims;
- ELF image loading and relocation;
- OVRPlugin replacement;
- OpenXR runtime replacement;
- GLES routing through ANGLE and Vulkan routing through MoltenVK.

The iOS port should reuse those layers rather than reimplement Android ABI
compatibility in Swift. The guest path is not a JIT: `klepton-ld` translates
Android ARM64 ELF libraries into iOS-stamped Mach-O dylibs, embeds the original
ELF in `__TEXT,__klelf`, and the runtime's `kl_load_dylib` asks dyld to map the
signed image. This is the path to use for iPhone.

## What is not reusable as-is

The current app frontend is visionOS-specific:
- Compositor Services and CompositorLayer;
- visionOS immersive-space lifecycle;
- visionOS-only ARKit providers and controller APIs.

PopinVR needs a separate iOS host app using ARKit + MetalKit. It should expose
the same guest-facing OVRPlugin/OpenXR calls to the runtime, but use iOS-native
camera, pose, hand, controller, audio, and presentation providers.

## Build gate added

`make ios-device` compiles the same `RUNTIME_SHIP` source list against
`iphoneos` and links an iOS dynamic library. This intentionally comes before
the app project: it identifies source-level platform incompatibilities in the
runtime without mixing them up with SwiftUI or renderer errors.

A green build does not prove runtime loading. The app must embed every
translated guest framework and Xcode must code-sign it. The runtime then loads
the framework through dyld/AMFI and applies the Android ELF relocations to the
read-only embedded `__klelf` image. The anonymous-mmap ELF loader is a host
fallback, not the iOS shipping path.

## Execution strategy

1. Build a minimal iOS app shell and link the iOS runtime library.
2. Package a tiny, known ARM64 guest image inside the app bundle.
3. Verify loader startup and Bionic/JNI initialization without a graphics API.
4. Add GLES via ANGLE and prove a simple guest-rendered frame.
5. Add the OpenXR/OVRPlugin session, swapchain and frame loop.
6. Only then try a real Quest APK, starting with a small, known-compatible title.

Do not make the first milestone a large Unity game. The loader, JNI, graphics,
XR and input failures need independent checkpoints so one missing API does not
look like a broken headset renderer.

## iOS graphics frontend

- MetalKit renders a side-by-side left/right eye image.
- Per-eye projection uses the ARKit camera pose plus a calibrated IPD offset.
- A post-process Metal pass applies lens distortion independently to each eye.
- ARKit camera imagery is optionally composited behind virtual content for MR.
- A calibration screen stores lens centers, distortion coefficients and IPD.

## Tracking bridge

The tracking package produces:
- timestamped ARKit camera transform;
- fixed 21-joint hand arrays;
- normalized image x/y;
- wrist-relative MediaPipe z;
- optional hand-local 3D metric coordinates;
- handedness and confidence.

The C ABI must use fixed-width integer and float fields, explicit version/size,
stable joint order, and a validity bit for optional world coordinates. It must
not assume Swift struct memory layout is a C ABI.
