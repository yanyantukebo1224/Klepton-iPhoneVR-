// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

/// Side-by-side stereo output for a phone mounted in a passive VR viewer.
/// The guest renders into persistent eye textures; this display loop samples
/// those textures at the phone's refresh rate.
@MainActor
final class IOSVRCompositor: NSObject {
    static let shared = IOSVRCompositor()

    private weak var guestLayer: CAMetalLayer?
    private weak var outputLayer: CAMetalLayer?
    private var displayLink: CADisplayLink?
    private var installed = false

    func start(guestLayer: CAMetalLayer, outputLayer: CAMetalLayer) {
        self.guestLayer = guestLayer
        self.outputLayer = outputLayer
        ki_install_metal_eye_provider(guestLayer)
        outputLayer.device = guestLayer.device
        if installed {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(drawFrame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            return
        }
        installed = true
        let link = CADisplayLink(target: self, selector: #selector(drawFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func drawFrame(_ link: CADisplayLink) {
        guard let outputLayer else { return }
        ki_render_stereo_frame(outputLayer)
    }
}
