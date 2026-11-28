# PopinVR iOS platform layer

This is the iPhone platform layer for PopinVR. It is deliberately separate
from `visionos/`: iOS must not compile against Compositor Services or
visionOS-only ARKit providers.

## Current implementation

- ARKit world tracking supplies the phone camera's 6DoF pose.
- MediaPipe Tasks Vision Hand Landmarker supplies up to two hands with 21
  ordered joints each.
- Live inference is asynchronous. While one inference is running, newer camera
  frames are dropped instead of queued, keeping tracking latency bounded.
- ARKit's camera image is converted to BGRA using a reusable CoreVideo pixel
  buffer pool because MediaPipe's iOS pixel-buffer input requires BGRA.
- The tracker tries the MediaPipe Metal delegate first and falls back to CPU
  if GPU initialization fails.

## Hand tracking and depth contract

MediaPipe outputs:
- normalized image `x/y` in [0, 1] (image origin at the top-left);
- model-estimated `z` relative to the wrist (not meters);
- `worldLandmarks` in meters in a hand-local coordinate frame;
- handedness and confidence.

This provides 3D finger articulation without a separate large monocular-depth
model. Hand-local world landmarks do **not** reveal the hand's absolute
distance from the iPhone camera.

For absolute camera-relative depth:
1. Prefer ARKit scene depth on devices that support LiDAR.
2. On the iPhone 16e, report absolute wrist distance as unavailable for now.
3. Never reinterpret MediaPipe's wrist-relative `z` as meters.

## Get the model

Run:

```sh
./Scripts/download_hand_model.sh
```

The script downloads Google's version-pinned float16 model and verifies its
SHA-256. The resulting file is `ios/Models/hand_landmarker.task`. The app
target must copy that file into its bundle and pass its resolved absolute path
to `PopinVRTracking(modelPath:) `. The model is intentionally not committed
as a binary to this source repository.

## Build gates

From the repository root:

```sh
make ios-device
```

This compiles and links the shared Klepton shipping runtime against the
iPhoneOS SDK. It is a compile/link gate, not proof that guest code can execute
on a physical iPhone.

For the Swift tracking package:

```sh
cd ios
xcodebuild -scheme PopinVRTracking -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions runs both gates on pushes to the PopinVR feature branch.

## Main runtime architecture

The project has two parallel layers:

| Layer | iOS implementation |
|---|---|
| Head pose / tracking origin | ARKit world tracking |
| Hand articulation | MediaPipe Hand Landmarker, 21 joints per hand |
| Absolute hand depth | ARKit scene depth only on supported LiDAR hardware |
| Stereo display | MetalKit / Metal, side-by-side eye viewports |
| Lens correction | Metal post-process pass, per-eye calibration |
| MR background | ARKit camera frames composited by Metal |
| Android guest ABI | Existing Klepton JNI / Bionic / NDK compatibility layer |
| Quest XR ABI | Existing OVRPlugin and OpenXR replacement layers |
| Guest loader | Shared Klepton ELF image loader; iOS execution policy remains a separate validation gate |

The current upstream Klepton app frontend uses Compositor Services on visionOS.
That frontend cannot simply be compiled for iOS. PopinVR will use a dedicated
MetalKit iOS frontend while reusing the platform-neutral runtime and XR
compatibility layers.

iOS also has a stricter executable-code and signing model than macOS. A
successful compile is not enough: the next runtime milestone must verify that
the app can load its packaged guest images under iOS signing and memory
protections. We will not assume the macOS JIT or dynamic-loading path works
unchanged.

## Next milestones

1. Verify the iOS runtime compile/link gate in CI and fix platform-specific
   compile failures.
2. Add a native iOS app target with a MetalKit SBS test scene and ARKit pose.
3. Add lens distortion/IPD calibration and a passthrough MR mode.
4. Connect the fixed-order hand/head tracking ABI to the OpenXR input layer.
5. Prove one small ARM64 Android guest can boot inside the iOS app before
   attempting large Quest titles.
6. Validate frame rate, motion-to-photon latency, thermals, memory use, and
   hand-tracking stability on the iPhone 16e.
