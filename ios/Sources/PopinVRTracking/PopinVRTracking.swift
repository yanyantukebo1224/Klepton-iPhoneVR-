import ARKit
import CoreImage
import CoreVideo
import Foundation
import MediaPipeTasksVision
import UIKit

public struct PopinVRHeadPose {
    public let timestamp: TimeInterval
    public let cameraTransform: simd_float4x4
    public let trackingState: String

    public init(timestamp: TimeInterval, cameraTransform: simd_float4x4, trackingState: String) {
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.trackingState = trackingState
    }
}

/// One synchronized sample from ARKit and MediaPipe.
public struct PopinVRTrackingFrame {
    public let timestamp: TimeInterval
    /// ARKit camera pose in the session world space; headset eye-center calibration comes later.
    public let cameraTransform: simd_float4x4
    public let trackingState: String
    /// At most two hands, each with 21 joints in fixed MediaPipe order.
    public let hands: [PopinVRHandSkeleton]

    public init(timestamp: TimeInterval, cameraTransform: simd_float4x4, trackingState: String, hands: [PopinVRHandSkeleton]) {
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.trackingState = trackingState
        self.hands = hands
    }
}

/// Converts ARKit camera buffers to BGRA, the pixel format required by MediaPipe Tasks Vision.
/// A CVPixelBufferPool reuses destination buffers to avoid per-frame allocation.
private final class PopinVRBGRAConverter {
    private let context = CIContext()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA { return source }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if pool == nil || width != poolWidth || height != poolHeight {
            var newPool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let newPool else {
                throw PopinVRTrackingError.pixelBufferConversionFailed(status)
            }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw PopinVRTrackingError.pixelBufferConversionFailed(status)
        }
        let image = CIImage(cvPixelBuffer: source)
        context.render(image, to: destination, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return destination
    }
}

/// iPhone tracking provider: ARKit 6DoF camera pose + MediaPipe 21-joint hand tracking.
/// MediaPipe z is wrist-relative; worldLandmarks are hand-local meters, not camera distance.
/// Frames are submitted asynchronously and dropped while inference is busy to bound latency.
public final class PopinVRTracking: NSObject, ARSessionDelegate, HandLandmarkerLiveStreamDelegate {
    /// Called for every ARKit camera frame, independently of slower hand inference.
    public var onPose: ((PopinVRHeadPose) -> Void)?
    /// Called when the matching asynchronous MediaPipe hand result arrives.
    public var onFrame: ((PopinVRTrackingFrame) -> Void)?
    public var onError: ((Error) -> Void)?

    private let session = ARSession()
    private let modelPath: String
    private let imageOrientation: UIImage.Orientation
    private let captureQueue = DispatchQueue(label: "dev.popinvr.tracking.arkit", qos: .userInteractive)
    private let inferenceQueue = DispatchQueue(label: "dev.popinvr.tracking.mediapipe", qos: .userInteractive)
    private let converter = PopinVRBGRAConverter()
    private let stateLock = NSLock()
    private var landmarker: HandLandmarker?
    private var poseByTimestamp: [Int: PopinVRHeadPose] = [:]
    private var inferenceInFlight = false
    private var lastSubmittedTimestamp = 0

    /// modelPath must point to Google's hand_landmarker.task bundle.
    /// imageOrientation defaults to sensor-native orientation; configure it for the chosen camera/display rotation.
    public init(modelPath: String, imageOrientation: UIImage.Orientation = .up) {
        self.modelPath = modelPath
        self.imageOrientation = imageOrientation
        super.init()
    }

    public func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw PopinVRTrackingError.worldTrackingUnavailable }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw PopinVRTrackingError.modelFileNotFound(modelPath) }

        // Use the CPU delegate for the first device milestone. Some iOS/Metal
        // combinations can terminate the process during GPU delegate startup
        // instead of throwing a recoverable Swift error. GPU inference can be
        // enabled again after device-side stability testing.
        let options = HandLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numHands = 2
        options.minHandDetectionConfidence = 0.5
        options.minHandPresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.handLandmarkerLiveStreamDelegate = self
        options.baseOptions.delegate = .CPU
        let created = try HandLandmarker(options: options)
        stateLock.lock()
        landmarker = created
        stateLock.unlock()

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        session.delegate = self
        session.delegateQueue = captureQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    public func stop() {
        session.pause()
        session.delegate = nil
        stateLock.lock()
        inferenceInFlight = false
        poseByTimestamp.removeAll(keepingCapacity: true)
        landmarker = nil
        stateLock.unlock()
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let timestamp = max(Int(frame.timestamp * 1_000), lastSubmittedTimestamp + 1)
        lastSubmittedTimestamp = timestamp
        let pose = PopinVRHeadPose(timestamp: TimeInterval(timestamp) / 1_000, cameraTransform: frame.camera.transform, trackingState: Self.describe(frame.camera.trackingState))
        DispatchQueue.main.async { [weak self] in self?.onPose?(pose) }
        stateLock.lock()
        guard !inferenceInFlight else { stateLock.unlock(); return }
        inferenceInFlight = true
        poseByTimestamp[timestamp] = pose
        if poseByTimestamp.count > 8, let oldest = poseByTimestamp.keys.min() { poseByTimestamp.removeValue(forKey: oldest) }
        stateLock.unlock()

        let cameraBuffer = frame.capturedImage
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let activeLandmarker = self.landmarker
            self.stateLock.unlock()
            guard let activeLandmarker else {
                self.finishInference(timestamp: timestamp)
                return
            }
            do {
                let bgraBuffer = try self.converter.convert(cameraBuffer)
                let image = try MPImage(pixelBuffer: bgraBuffer, orientation: self.imageOrientation)
                try activeLandmarker.detectAsync(image: image, timestampInMilliseconds: timestamp)
            } catch {
                self.finishInference(timestamp: timestamp)
                DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            }
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    public func handLandmarker(_ handLandmarker: HandLandmarker, didFinishDetection result: HandLandmarkerResult?, timestampInMilliseconds: Int, error: Error?) {
        stateLock.lock()
        let pose = poseByTimestamp.removeValue(forKey: timestampInMilliseconds)
        inferenceInFlight = false
        stateLock.unlock()
        if let error {
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            return
        }
        guard let pose else { return }
        let hands = (result?.landmarks ?? []).enumerated().compactMap { index, points in
            Self.makeHand(points: points, worldPoints: result?.worldLandmarks[safe: index], handedness: result?.handedness[safe: index])
        }
        let sample = PopinVRTrackingFrame(timestamp: pose.timestamp, cameraTransform: pose.cameraTransform, trackingState: pose.trackingState, hands: hands)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(sample) }
    }

    private func finishInference(timestamp: Int) {
        stateLock.lock()
        poseByTimestamp.removeValue(forKey: timestamp)
        inferenceInFlight = false
        stateLock.unlock()
    }

    private static func makeHand(points: [NormalizedLandmark], worldPoints: [Landmark]?, handedness: [ResultCategory]?) -> PopinVRHandSkeleton? {
        guard points.count == PopinVRHandJoint.allCases.count else { return nil }
        let category = handedness?.first
        let side: PopinVRHandSide
        switch category?.categoryName?.lowercased() {
        case "left": side = .left
        case "right": side = .right
        default: side = .unknown
        }
        let handConfidence = category?.score ?? 0
        let joints = PopinVRHandJoint.allCases.map { joint in
            let point = points[joint.rawValue]
            let world = worldPoints.flatMap { $0.count > joint.rawValue ? $0[joint.rawValue] : nil }
            let confidence = point.visibility?.floatValue ?? point.presence?.floatValue ?? handConfidence
            let worldPosition = world.map { SIMD3<Float>(x: $0.x, y: $0.y, z: $0.z) }
            return PopinVRHandJointSample(joint: joint, x: point.x, y: point.y, z: point.z, confidence: confidence, worldPosition: worldPosition)
        }
        return PopinVRHandSkeleton(side: side, handednessConfidence: handConfidence, joints: joints)
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason): return "limited:\(reason)"
        @unknown default: return "unknown"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

public enum PopinVRTrackingError: LocalizedError {
    case worldTrackingUnavailable
    case modelFileNotFound(String)
    case pixelBufferConversionFailed(CVReturn)

    public var errorDescription: String? {
        switch self {
        case .worldTrackingUnavailable:
            return "ARKit world tracking is not supported on this device."
        case .modelFileNotFound(let path):
            return "MediaPipe hand model was not found at: \(path)"
        case .pixelBufferConversionFailed(let status):
            return "Camera frame conversion to BGRA failed (CVReturn \(status))."
        }
    }
}
