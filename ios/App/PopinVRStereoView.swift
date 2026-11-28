import MetalKit
import SwiftUI
import PopinVRTracking

struct PopinVRStereoView: UIViewRepresentable {
    let headPose: PopinVRHeadPose?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.035, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        if let renderer = PopinVRStereoRenderer(view: view) {
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(headPose: headPose)
    }

    final class Coordinator {
        var renderer: PopinVRStereoRenderer?
    }
}
