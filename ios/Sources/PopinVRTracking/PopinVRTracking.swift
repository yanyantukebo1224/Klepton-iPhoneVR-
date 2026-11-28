import ARKit
import Foundation
import ImageIO
import Vision

/// A 2D hand landmark returned by Vision.
///
/// Coordinates are normalized to the camera image and use Vision's
/// lower-left origin. They are not world-space or metric 3D coordinates.
public struct PopinVRHandLandmark {
    public let joint: String
    public let x: Float
    public let y: Float
    public let confidence: Float

    public init(joint: String, x: Float, y: Float, confidence: Float) {
        self.joint = joint
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

/// A hand detected in the current camera frame.
public struct PopinVRTrackedHand {
    /// "left", "right", or "unknown" from Vision's chirality estimate.
    public let side: String
    public let landmarks: [PopinVRHandLandmark]

    public init(side: String, landmarks: [PopinVRHandLandmark]) {
        self.side = side
        self.landmarks = landmarks
    }
}

/// One synchronized sample from ARKit and Vision.
public struct PopinVRTrackingFrame {
    public let timestamp: TimeInterval
    /// ARKit camera pose in the current AR session's world coordinate space.
    public let cameraTransform: simd_float4x4
    public let trackingState: String
    public let hands: [PopinVRTrackedHand]

    public init(
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        trackingState: String,
        hands: [PopinVRTrackedHand]
    ) {
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.trackingState = trackingState
        self.hands = hands
    }
}

/// iOS tracking input for PopinVR.
///
/// ARKit supplies the device pose. Vision supplies 2D hand landmarks from the
/// rear camera image. This deliberately does not claim to provide the same
/// metric 3D hand skeleton as visionOS HandTrackingProvider; depth recovery
/// and Quest/OpenXR joint mapping belong in a later adapter.
public final class PopinVRTracking: NSObject, ARSessionDelegate {
    public var onFrame: ((PopinVRTrackingFrame) -> Void)?
    public var onError: ((Error) -> Void)?

    private let session = ARSession()
    private let visionQueue = DispatchQueue(
        label: "dev.popinvr.tracking.vision",
        qos: .userInitiated
    )
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let imageOrientation: CGImagePropertyOrientation

    public init(imageOrientation: CGImagePropertyOrientation = .up) {
        self.imageOrientation = imageOrientation
        super.init()
        handRequest.maximumHandCount = 2
    }

    /// Starts world tracking and camera-based hand landmark detection.
    ///
    /// The containing app must include NSCameraUsageDescription in its
    /// Info.plist. Call this only while the app is in the foreground.
    public func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw PopinVRTrackingError.worldTrackingUnavailable
        }

        let configuration = ARWorldTrackingConfiguration()
        session.delegate = self
        session.delegateQueue = visionQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    public func stop() {
        session.pause()
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let hands: [PopinVRTrackedHand]
        do {
            hands = try detectHands(in: frame.capturedImage)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
            return
        }

        let sample = PopinVRTrackingFrame(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            trackingState: describe(frame.camera.trackingState),
            hands: hands
        )

        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(sample)
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func detectHands(in pixelBuffer: CVPixelBuffer) throws -> [PopinVRTrackedHand] {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: imageOrientation,
            options: [:]
        )
        try handler.perform([handRequest])

        return try (handRequest.results ?? []).map { observation in
            let recognized = try observation.recognizedPoints(.all)
            let landmarks = recognized.map { joint, point in
                PopinVRHandLandmark(
                    joint: String(describing: joint),
                    x: Float(point.location.x),
                    y: Float(point.location.y),
                    confidence: point.confidence
                )
            }

            let side: String
            switch observation.chirality {
            case .left: side = "left"
            case .right: side = "right"
            @unknown default: side = "unknown"
            }

            return PopinVRTrackedHand(side: side, landmarks: landmarks)
        }
    }

    private func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            return "limited:\(reason)"
        @unknown default:
            return "unknown"
        }
    }
}

public enum PopinVRTrackingError: Error {
    case worldTrackingUnavailable
}
