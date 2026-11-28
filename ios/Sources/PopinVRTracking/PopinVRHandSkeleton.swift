import Foundation
import simd

/// Stable joint order matching MediaPipe Hands / Hand Landmarker (21 points).
/// Keep this order fixed across Swift, C, and the guest OpenXR adapter.
public enum PopinVRHandJoint: Int, CaseIterable, Sendable {
    case wrist = 0
    case thumbCMC, thumbMCP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case pinkyMCP, pinkyPIP, pinkyDIP, pinkyTip
}

/// Per-joint values suitable for a compact C ABI.
///
/// x/y are normalized image coordinates [0, 1], with origin at the image top-left.
/// z is MediaPipe's wrist-relative depth (not meters and not camera-space Z).
/// worldPosition is MediaPipe's hand-local 3D estimate in meters, when present.
public struct PopinVRHandJointSample: Sendable {
    public let joint: PopinVRHandJoint
    public let x: Float
    public let y: Float
    public let z: Float
    public let confidence: Float
    public let worldPosition: SIMD3<Float>?

    public init(
        joint: PopinVRHandJoint,
        x: Float,
        y: Float,
        z: Float,
        confidence: Float,
        worldPosition: SIMD3<Float>? = nil
    ) {
        self.joint = joint
        self.x = x.isFinite ? min(max(x, 0), 1) : 0
        self.y = y.isFinite ? min(max(y, 0), 1) : 0
        self.z = z.isFinite ? z : 0
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.worldPosition = worldPosition
    }
}

/// A complete MediaPipe-style hand sample in stable joint order.
public struct PopinVRHandSkeleton: Sendable {
    public let side: PopinVRHandSide
    public let handednessConfidence: Float
    public let joints: [PopinVRHandJointSample]

    public init?(
        side: PopinVRHandSide,
        handednessConfidence: Float,
        joints: [PopinVRHandJointSample]
    ) {
        guard joints.count == PopinVRHandJoint.allCases.count,
              joints.enumerated().allSatisfy({ $0.element.joint.rawValue == $0.offset }) else {
            return nil
        }
        self.side = side
        self.handednessConfidence = min(max(handednessConfidence, 0), 1)
        self.joints = joints
    }

    /// Hand-local metric joints. These are useful for finger articulation,
    /// but do not provide the hand's absolute distance from the phone.
    public var handLocalPositions: [SIMD3<Float>?] {
        joints.map(\.worldPosition)
    }
}

public enum PopinVRHandSide: Int, Sendable {
    case unknown = 0
    case left = 1
    case right = 2
}

/// Camera-relative depth is kept separate from MediaPipe's wrist-relative Z.
/// A future calibrated depth provider (LiDAR/depth camera) can populate it.
public struct PopinVRHandDepth: Sendable {
    /// Estimated distance from the camera to the wrist, in meters.
    /// nil means the current device/provider cannot measure absolute depth.
    public let wristDistanceMeters: Float?
    /// MediaPipe's relative per-joint Z values, in model-relative units.
    public let jointRelativeZ: [Float]

    public init(wristDistanceMeters: Float?, jointRelativeZ: [Float]) {
        self.wristDistanceMeters = wristDistanceMeters
        self.jointRelativeZ = jointRelativeZ
    }
}
