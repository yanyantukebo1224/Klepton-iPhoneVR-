import SceneKit
import SwiftUI
import UIKit
import simd
import PopinVRTracking

/// A real articulated 3D preview built from MediaPipe's 21 hand landmarks.
/// Joint positions are hand-local; this preview intentionally does not claim
/// that they are already transformed into ARKit world space.
struct PopinVRHandModelView: UIViewRepresentable {
    let frame: PopinVRTrackingFrame?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.makeScene()
        view.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.085, alpha: 1)
        view.isPlaying = true
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNodes.filter { $0.name == "tracked-hand" }.forEach { $0.removeFromParentNode() }
        guard let frame else { return }

        for (handIndex, hand) in frame.hands.enumerated() {
            let root = SCNNode()
            root.name = "tracked-hand"
            let tint: UIColor = hand.side == .left
                ? UIColor(red: 0.18, green: 0.82, blue: 1.0, alpha: 1)
                : UIColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 1)

            let positions: [SIMD3<Float>] = hand.joints.map { joint in
                if let p = joint.worldPosition {
                    return SIMD3<Float>(p.x, -p.y, p.z)
                }
                // Fallback for providers that only expose image-space landmarks.
                return SIMD3<Float>((joint.x - 0.5) * 0.16, (0.5 - joint.y) * 0.16, joint.z * 0.035)
            }
            guard positions.count == 21 else { continue }

            let wrist = positions[0]
            let xOffset: Float = frame.hands.count > 1 ? (handIndex == 0 ? -0.085 : 0.085) : 0
            let local = positions.map { $0 - wrist + SIMD3<Float>(xOffset, 0, 0) }

            // Palm volume: an ellipsoid centered on the four metacarpal joints.
            let palmCenter = (local[5] + local[9] + local[13] + local[17]) / 4
            let palm = SCNSphere(radius: 0.027)
            palm.segmentCount = 24
            palm.firstMaterial = Self.material(tint, roughness: 0.42)
            let palmNode = SCNNode(geometry: palm)
            palmNode.simdPosition = palmCenter
            palmNode.scale = SCNVector3(1.15, 1.45, 0.34)
            root.addChildNode(palmNode)

            let chains: [[Int]] = [
                [0, 1, 2, 3, 4],
                [0, 5, 6, 7, 8],
                [0, 9, 10, 11, 12],
                [0, 13, 14, 15, 16],
                [0, 17, 18, 19, 20]
            ]

            for (chainIndex, chain) in chains.enumerated() {
                for segment in 0..<(chain.count - 1) {
                    let aIndex = chain[segment]
                    let bIndex = chain[segment + 1]
                    guard hand.joints[aIndex].confidence > 0.05,
                          hand.joints[bIndex].confidence > 0.05 else { continue }
                    let radius: CGFloat = chainIndex == 0 ? 0.0052 : 0.0046
                    root.addChildNode(Self.makeBone(from: local[aIndex], to: local[bIndex], radius: radius, color: tint))
                }
            }

            for (index, point) in local.enumerated() where hand.joints[index].confidence > 0.05 {
                let radius: CGFloat = [0, 5, 9, 13, 17].contains(index) ? 0.006 : 0.0048
                let joint = SCNSphere(radius: radius)
                joint.segmentCount = 12
                joint.firstMaterial = Self.material(tint, roughness: 0.32)
                let node = SCNNode(geometry: joint)
                node.simdPosition = point
                root.addChildNode(node)
            }
            scene.rootNode.addChildNode(root)
        }
        view.setNeedsDisplay()
    }

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.zNear = 0.01
        camera.zFar = 4
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0.42)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 850
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-0.2, 0.25, 0.35)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 400
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(0.25, -0.15, 0.2)
        scene.rootNode.addChildNode(fillNode)
        return scene
    }

    private static func material(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.metalness.contents = 0.18
        material.roughness.contents = roughness
        material.lightingModel = .physicallyBased
        return material
    }

    private static func makeBone(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: CGFloat, color: UIColor) -> SCNNode {
        let delta = end - start
        let length = max(simd_length(delta), 0.001)
        let geometry = SCNCapsule(capRadius: radius, height: CGFloat(length))
        geometry.radialSegmentCount = 10
        geometry.firstMaterial = material(color, roughness: 0.38)
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(delta)
        )
        return node
    }
}
