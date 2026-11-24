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
                                            orientation: .right,
                                            options: [:])
        do {
            try handler.perform([request])
            let hands = (request.results ?? []).map { observation in
                ((try? observation.recognizedPoints(.all)) ?? [:]).map { joint, point in
                    HandLandmark(id: joint.rawValue,
                                 x: Float(point.location.x),
                                 y: Float(point.location.y),
                                 confidence: point.confidence)
                }.sorted { $0.id < $1.id }
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
        detectHands(in: pixelBuffer)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.trackingState = "ARKit error: \(error.localizedDescription)" }
    }
}
