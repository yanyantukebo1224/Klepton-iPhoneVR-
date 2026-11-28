import MetalKit
import simd
import PopinVRTracking

private struct PopinVRVertex {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

private struct PopinVRUniforms {
    var mvp: simd_float4x4
}

/// First device-viewer milestone: two eye viewports, ARKit head pose and
/// calibrated eye separation. Lens distortion is intentionally a separate
/// post-process milestone, not faked by warping the geometry.
final class PopinVRStereoRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let poseLock = NSLock()
    private var cameraTransform = matrix_identity_float4x4
    private let ipdMeters: Float = 0.064
    private let verticalFOV: Float = 90 * .pi / 180

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "stereoVertex"),
              let fragmentFunction = library.makeFunction(name: "stereoFragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        let vertices: [PopinVRVertex] = [
            .init(position: [-0.5, -0.5, -0.5], color: [1.0, 0.25, 0.18]),
            .init(position: [ 0.5, -0.5, -0.5], color: [1.0, 0.55, 0.18]),
            .init(position: [ 0.5,  0.5, -0.5], color: [0.25, 0.75, 1.0]),
            .init(position: [-0.5,  0.5, -0.5], color: [0.35, 1.0, 0.65]),
            .init(position: [-0.5, -0.5,  0.5], color: [0.8, 0.3, 1.0]),
            .init(position: [ 0.5, -0.5,  0.5], color: [1.0, 0.8, 0.2]),
            .init(position: [ 0.5,  0.5,  0.5], color: [0.25, 1.0, 0.8]),
            .init(position: [-0.5,  0.5,  0.5], color: [0.8, 0.9, 1.0])
        ]
        let indices: [UInt16] = [
            0, 2, 1, 0, 3, 2,
            4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4,
            2, 3, 7, 2, 7, 6,
            1, 2, 6, 1, 6, 5,
            3, 0, 4, 3, 4, 7
        ]
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<PopinVRVertex>.stride * vertices.count
        ), let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt16>.stride * indices.count
        ) else {
            return nil
        }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<PopinVRVertex>.stride

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.depthAttachmentPixelFormat = .depth32Float
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState

        super.init()
        view.delegate = self
    }

    func update(headPose: PopinVRHeadPose?) {
        guard let headPose else { return }
        poseLock.lock()
        cameraTransform = headPose.cameraTransform
        poseLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        poseLock.lock()
        let head = cameraTransform
        poseLock.unlock()

        let width = drawable.texture.width
        let height = drawable.texture.height
        let eyeWidth = max(1, width / 2)
        let aspect = Float(eyeWidth) / Float(max(1, height))
        let projection = perspective(fovY: verticalFOV, aspect: aspect, near: 0.03, far: 100)
        var model = matrix_identity_float4x4
        model.columns.3.z = -2.0

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        for eye in 0..<2 {
            let offset = eye == 0 ? -ipdMeters * 0.5 : ipdMeters * 0.5
            var eyeOffset = matrix_identity_float4x4
            eyeOffset.columns.3.x = offset
            let eyeWorldTransform = head * eyeOffset
            let viewMatrix = simd_inverse(eyeWorldTransform)
            var uniforms = PopinVRUniforms(mvp: projection * viewMatrix * model)

            encoder.setViewport(MTLViewport(
                originX: Double(eye * eyeWidth),
                originY: 0,
                width: Double(eyeWidth),
                height: Double(height),
                znear: 0,
                zfar: 1
            ))
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PopinVRUniforms>.stride,
                index: 1
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexCount,
                indexType: .uint16,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func perspective(
        fovY: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / max(aspect, 0.001)
        let z = far / (near - far)
        let w = near * far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, w, 0)
        ))
    }
}
