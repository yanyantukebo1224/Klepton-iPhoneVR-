# PopinVR iOS platform layer

This directory is the iOS-specific platform module for the Klepton-derived runtime.
It stays separate from `visionos/`: iOS must not compile against Compositor
Services or visionOS-only ARKit providers.

## Hand tracking and depth decision

Use **MediaPipe Tasks Vision Hand Landmarker** as the primary hand landmark
provider rather than trying to infer 3D from Vision's 2D hand points.

MediaPipe provides 21 ordered landmarks per hand:
- normalized image `x/y` in [0, 1];
- model-estimated `z` relative to the wrist (not meters);
- `worldLandmarks` in meters in a hand-local coordinate frame;
- handedness and confidence.

This gives us 3D finger articulation without a separate large monocular-depth
model. Important distinction: hand-local world landmarks do **not** reveal the
hand's absolute distance from the iPhone camera.

For absolute camera-relative depth:
1. Prefer ARKit scene depth when the device supports LiDAR.
2. Otherwise keep wrist distance unavailable initially; add a separately
   calibrated monocular scale estimator only if the experience needs it.
3. Never reinterpret MediaPipe's wrist-relative `z` as meters.

The initial iPhone 16e target does not have a LiDAR scanner. Its first
non-LiDAR path should use MediaPipe's 21-point local skeleton for hand pose and
report absolute depth as unavailable rather than inventing a distance.

## Stable data contract

`Sources/PopinVRTracking/PopinVRHandSkeleton.swift` defines a fixed 21-joint
order matching MediaPipe Hands. Each joint carries scalar normalized `x/y`,
relative `z`, confidence, and optional hand-local metric position. This order
is intended to be shared with the C/C++ XR adapter and later mapped to the
Quest/OpenXR hand-joint profile.

## Current tracking foundation

`Sources/PopinVRTracking/PopinVRTracking.swift` currently obtains the iPhone
camera pose from ARKit and uses Vision hand pose as a temporary detector.
The next integration step is replacing that detector with MediaPipe Tasks
Vision and populating `PopinVRHandSkeleton`. Do not treat the temporary Vision
points as a 3D skeleton.

## Platform boundary

| Guest-facing capability | iOS provider |
|---|---|
| HMD pose / tracking origin | ARKit world tracking + device motion |
| Hand articulation | MediaPipe Hand Landmarker (21 joints) |
| Absolute hand depth | ARKit scene depth on LiDAR devices; optional calibrated estimator elsewhere |
| Controller input | GameController framework and/or external controller bridge |
| Stereo presentation | Metal-backed SBS renderer |
| Camera passthrough | ARKit captured camera frames rendered by Metal |
| Audio | AVAudioEngine / AudioToolbox |

## Next milestones

1. Integrate MediaPipe Tasks Vision and package its model asset.
2. Add a C ABI for fixed-order timestamped head pose and hand samples.
3. Build the Metal SBS renderer and lens calibration UI.
4. Add camera-background composition for optional MR passthrough.
5. Connect the iOS tracking adapter to the existing XR runtime seams.
6. Validate tracking rate, end-to-end latency, thermals, and hand loss on-device.
