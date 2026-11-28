# PopinVR iOS platform layer

This directory is the first iOS-specific platform module for the Klepton-derived
runtime. It is intentionally separate from `visionos/`: iOS must not compile
against Compositor Services or visionOS-only ARKit providers.

## Current implementation

`Sources/PopinVRTracking/PopinVRTracking.swift` provides a small Swift Package
that:

- obtains the iPhone camera pose from `ARSession` + `ARWorldTrackingConfiguration`;
- runs Vision's `VNDetectHumanHandPoseRequest` on each camera frame;
- publishes the timestamp, ARKit camera transform, tracking state, and detected
  2D hand landmarks to the app on the main queue.

The hand landmarks are normalized image coordinates, not metric 3D joint poses.
This is a deliberate first milestone: Vision hand pose is not equivalent to
visionOS `HandTrackingProvider`, and the runtime must not silently treat 2D
points as a Quest hand skeleton.

The host app must add `NSCameraUsageDescription` to its Info.plist before
starting the tracker. The image orientation is configurable because the
orientation of the camera buffer depends on how the phone is mounted.

## Platform boundary

Keep the guest runtime in C. Keep iOS device services in Swift and expose a
small C-compatible bridge for the runtime:

| Guest-facing capability | iOS provider |
|---|---|
| HMD pose / tracking origin | ARKit world tracking + device motion |
| Hand observations | Vision hand landmarks; later depth/pose reconstruction |
| Controller input | GameController framework and/or external controller bridge |
| Stereo presentation | Metal-backed SBS renderer |
| Camera passthrough | ARKit captured camera frames rendered by Metal |
| Audio | AVAudioEngine / AudioToolbox |

The iOS target must not import `CompositorServices`, use `ImmersiveSpace`, or
depend on visionOS-only `HandTrackingProvider` / `HandAnchor` types.

## Next milestones

1. Add an iOS app target that embeds this package and requests camera access.
2. Render a calibration scene in side-by-side stereo with lens-distortion
   controls; keep this independent from Android guest startup.
3. Add a Metal camera-background path for optional MR passthrough.
4. Define a C ABI for timestamped head pose and hand samples, then connect it
   to the existing `runtime/xr` pose/input seams.
5. Implement the Quest/OpenXR hand-joint profile and controller profile only
   after the iOS tracking data has a stable coordinate-space contract.
6. Add iOS device build gates and tests; keep the existing macOS/visionOS
   build paths unchanged.

## Build note

This package is an isolated module, not yet wired into the generated Xcode
project. Build it on macOS with Xcode using the Swift Package manifest. The
repository's current top-level build and `visionos/run.sh` remain unchanged.
