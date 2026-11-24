// SPDX-License-Identifier: GPL-2.0-or-later
import ARKit
import Combine
import Foundation
import simd
import Vision

/// iPhone XR input source. ARKit supplies 6DoF world tracking; Vision supplies
/// camera-space 2D hand landmarks. The latter are deliberately not advertised
/// as metric 3D finger tracking: iPhone 16e has no LiDAR depth sensor.
@MainActor
final class IOSXRTracking: NSObject, ObservableObject {
    struct HandLandmark: Identifiable {
        let id: String
        let x: Float
        let y: Float
        let confidence: Float
    }

    @Published private(set) var trackingState = "Not started"
    @Published private(set) var handLandmarks: [[HandLandmark]] = []
    @Published private(set) var headPosition = SIMD3<Float>(repeating: 0)

    private let session = ARSession()
    private let visionQueue = DispatchQueue(label: "iquest.vision.handpose", qos: .userInitiated)
    private var isRunning = false

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
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
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

    private func publish(_ transform: simd_float4x4, state: ARCamera.TrackingState) {
        let position = SIMD3<Float>(transform.columns.3.x,
                                    transform.columns.3.y,
                                    transform.columns.3.z)
        let rotationMatrix = simd_float3x3(columns: (
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        let rotation = simd_quatf(rotationMatrix)
        ki_publish_head_pose(position.x, position.y, position.z,
                             rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real)
        Task { @MainActor in
            self.headPosition = position
            switch state {
            case .normal: self.trackingState = "Tracking"
            case .notAvailable: self.trackingState = "Tracking unavailable"
            case .limited(let reason):
                self.trackingState = "Limited: \(reason)"
            @unknown default: self.trackingState = "Unknown tracking state"
            }
        }
    }

    nonisolated private func detectHands(in pixelBuffer: CVPixelBuffer) {
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
                    HandLandmark(id: joint.rawValue,
                                 x: Float(point.location.x),
                                 y: Float(point.location.y),
                                 confidence: point.confidence)
                }.sorted { $0.id < $1.id }
            }
            // Estimate the wrist's metric position from the known approximate
            // adult palm width. This is monocular scale estimation, not depth
            // sensing; the skeleton remains 2D until a real 3D source is added.
            let imageWidth = Float(CVPixelBufferGetWidth(pixelBuffer))
            let imageHeight = Float(CVPixelBufferGetHeight(pixelBuffer))
            let intrinsics = camera.intrinsics
            let fx = intrinsics.columns.0.x
            let fy = intrinsics.columns.1.y
            let cx = intrinsics.columns.2.x
            let cy = intrinsics.columns.2.y
            let cameraRotation = simd_quatf(simd_float3x3(columns: (
                SIMD3<Float>(camera.transform.columns.0.x, camera.transform.columns.0.y, camera.transform.columns.0.z),
                SIMD3<Float>(camera.transform.columns.1.x, camera.transform.columns.1.y, camera.transform.columns.1.z),
                SIMD3<Float>(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
            )))
            for observation in observations {
                guard let points = try? observation.recognizedPoints(.all),
                      let wrist = points[.wrist], wrist.confidence > 0.25,
                      let index = points[.indexMCP], index.confidence > 0.25,
                      let middle = points[.middleMCP], middle.confidence > 0.25,
                      let pinky = points[.littleMCP], pinky.confidence > 0.25 else { continue }
                let dx = Float(index.location.x - pinky.location.x) * imageWidth
                let dy = Float(index.location.y - pinky.location.y) * imageHeight
                let palmPixels = max(1, hypot(dx, dy))
                let depth = min(1.2, max(0.20, fx * 0.085 / palmPixels))
                func cameraPoint(_ point: VNRecognizedPoint) -> SIMD3<Float> {
                    let u = Float(point.location.x) * imageWidth
                    let v = (1 - Float(point.location.y)) * imageHeight
                    return SIMD3((u - cx) / fx * depth,
                                 -(v - cy) / fy * depth,
                                 -depth)
                }
                let transform = camera.transform
                func worldPoint(_ point: VNRecognizedPoint) -> SIMD3<Float> {
                    let p = cameraPoint(point)
                    let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                    return SIMD3(w.x, w.y, w.z)
                }
                let wristWorld = worldPoint(wrist)
                let across = simd_normalize(worldPoint(index) - worldPoint(pinky))
                let forwardRaw = simd_normalize(worldPoint(middle) - wristWorld)
                let normal = simd_normalize(simd_cross(across, forwardRaw))
                let forward = simd_normalize(simd_cross(normal, across))
                let handRotation = simd_quatf(simd_float3x3(columns: (across, forward, normal)))
                let worldRotation = cameraRotation * handRotation
                let hand = observation.chirality == .left ? 0 : 1
                ki_publish_hand_pose(Int32(hand), wristWorld.x, wristWorld.y, wristWorld.z,
                                     worldRotation.imag.x, worldRotation.imag.y,
                                     worldRotation.imag.z, worldRotation.real)
            }
            Task { @MainActor in self.handLandmarks = hands }
        } catch {
            Task { @MainActor in self.handLandmarks = [] }
        }
    }
}

extension IOSXRTracking: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let state = frame.camera.trackingState
        let pixelBuffer = frame.capturedImage
        Task { @MainActor in
            self.publish(transform, state: state)
        }
        detectHands(in: pixelBuffer, camera: frame.camera)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.trackingState = "ARKit error: \(error.localizedDescription)" }
    }
}
