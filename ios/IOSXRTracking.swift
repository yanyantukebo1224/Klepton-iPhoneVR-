// SPDX-License-Identifier: GPL-2.0-or-later
import ARKit
import Combine
import Foundation
import simd
import Vision

/// ARKit provides 6DoF head tracking. Vision provides 2D hand landmarks;
/// a monocular palm-width estimate supplies an approximate wrist depth.
struct IOSHandLandmark: Identifiable, Sendable {
        let id: String
        let x: Float
        let y: Float
        let confidence: Float
}

@MainActor
final class IOSXRTracking: NSObject, ObservableObject {
    @Published private(set) var trackingState = "Not started"
    @Published private(set) var handLandmarks: [[IOSHandLandmark]] = []
    @Published private(set) var headPosition = SIMD3<Float>(repeating: 0)

    private let session = ARSession()
    private let visionQueue = DispatchQueue(label: "iquest.vision.handpose", qos: .userInitiated)
    private var isRunning = false

    // ARSessionDelegate is delivered on visionQueue. These values are only
    // read/written there, except that start() resets them while the session is paused.
    nonisolated(unsafe) private var originTransform: simd_float4x4?
    nonisolated(unsafe) private var detectedFloorY: Float?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = visionQueue
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingState = "ARKit world tracking is unavailable"
            return
        }
        session.pause()
        originTransform = nil
        detectedFloorY = nil
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        trackingState = "Starting ARKit world tracking"
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        trackingState = "Paused"
    }

    private func publishHeadPose(_ transform: simd_float4x4,
                                 floorOffset: Float,
                                 state: ARCamera.TrackingState) {
        var position = SIMD3<Float>(transform.columns.3.x,
                                    transform.columns.3.y,
                                    transform.columns.3.z)
        position.y += floorOffset

        let rotationMatrix = simd_float3x3(columns: (
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        let rotation = simd_quatf(rotationMatrix)
        ki_publish_head_pose(position.x, position.y, position.z,
                             rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real)

        headPosition = position
        switch state {
        case .normal: trackingState = "Tracking"
        case .notAvailable: trackingState = "Tracking unavailable"
        case .limited(let reason): trackingState = "Limited: \(reason)"
        @unknown default: trackingState = "Unknown tracking state"
        }
    }

    nonisolated private func detectHands(in pixelBuffer: CVPixelBuffer,
                                         worldFromCamera: simd_float4x4,
                                         intrinsics: simd_float3x3,
                                         floorOffset: Float) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let hands = observations.map { observation in
                ((try? observation.recognizedPoints(.all)) ?? [:]).map { joint, point in
                    IOSHandLandmark(id: joint.rawValue,
                                 x: Float(point.location.x),
                                 y: Float(point.location.y),
                                 confidence: point.confidence)
                }.sorted { $0.id < $1.id }
            }

            let imageWidth = Float(CVPixelBufferGetWidth(pixelBuffer))
            let imageHeight = Float(CVPixelBufferGetHeight(pixelBuffer))
            let fx = intrinsics.columns.0.x
            let fy = intrinsics.columns.1.y
            let cx = intrinsics.columns.2.x
            let cy = intrinsics.columns.2.y

            for observation in observations {
                guard let points = try? observation.recognizedPoints(.all),
                      let wrist = points[.wrist], wrist.confidence > 0.25,
                      let index = points[.indexMCP], index.confidence > 0.25,
                      let middle = points[.middleMCP], middle.confidence > 0.25,
                      let little = points[.littleMCP], little.confidence > 0.25 else { continue }

                let dx = Float(index.location.x - little.location.x) * imageWidth
                let dy = Float(index.location.y - little.location.y) * imageHeight
                let palmPixels = max(1, hypot(dx, dy))
                // Approximate 85 mm palm width; clamp the estimate to a useful range.
                let depth = min(1.2, max(0.20, fx * 0.085 / palmPixels))

                func cameraPoint(_ point: VNRecognizedPoint) -> SIMD3<Float> {
                    let u = Float(point.location.x) * imageWidth
                    let v = (1 - Float(point.location.y)) * imageHeight
                    return SIMD3((u - cx) / fx * depth,
                                 -(v - cy) / fy * depth,
                                 -depth)
                }

                func worldPoint(_ point: VNRecognizedPoint) -> SIMD3<Float> {
                    let p = cameraPoint(point)
                    let w = worldFromCamera * SIMD4<Float>(p.x, p.y, p.z, 1)
                    return SIMD3(w.x, w.y + floorOffset, w.z)
                }

                let wristWorld = worldPoint(wrist)
                let acrossRaw = worldPoint(index) - worldPoint(little)
                let forwardRaw = worldPoint(middle) - wristWorld
                guard simd_length(acrossRaw) > 0.0001,
                      simd_length(forwardRaw) > 0.0001 else { continue }
                let across = simd_normalize(acrossRaw)
                let forwardHint = simd_normalize(forwardRaw)
                let normalRaw = simd_cross(across, forwardHint)
                guard simd_length(normalRaw) > 0.0001 else { continue }
                let normal = simd_normalize(normalRaw)
                let forward = simd_normalize(simd_cross(normal, across))
                let handRotation = simd_quatf(simd_float3x3(columns: (across, forward, normal)))
                let hand = observation.chirality == .left ? 0 : 1

                ki_publish_hand_pose(Int32(hand),
                                     wristWorld.x, wristWorld.y, wristWorld.z,
                                     handRotation.imag.x, handRotation.imag.y,
                                     handRotation.imag.z, handRotation.real)
            }

            Task { @MainActor in self.handLandmarks = hands }
        } catch {
            Task { @MainActor in self.handLandmarks = [] }
        }
    }
}

extension IOSXRTracking: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        if originTransform == nil { originTransform = cameraTransform }
        guard let originTransform else { return }

        // Make the first tracked head pose the guest origin, not ARKit's arbitrary
        // world origin. Floor/stage tracking gets a floor-height offset below.
        let relativeTransform = simd_inverse(originTransform) * cameraTransform
        let floorOffset: Float
        if ki_get_tracking_origin() == 0 {
            floorOffset = 0
        } else {
            floorOffset = detectedFloorY.map { -$0 } ?? 1.6
        }

        let state = frame.camera.trackingState
        let pixelBuffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        Task { @MainActor in
            self.publishHeadPose(relativeTransform, floorOffset: floorOffset, state: state)
        }
        detectHands(in: pixelBuffer,
                    worldFromCamera: relativeTransform,
                    intrinsics: intrinsics,
                    floorOffset: floorOffset)
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let originTransform else { return }
        let inverseOrigin = simd_inverse(originTransform)
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor,
                  plane.alignment == .horizontal,
                  plane.classification == .floor else { continue }
            let floorInOrigin = inverseOrigin * plane.transform
            detectedFloorY = floorInOrigin.columns.3.y
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.trackingState = "ARKit error: \(error.localizedDescription)" }
    }
}
