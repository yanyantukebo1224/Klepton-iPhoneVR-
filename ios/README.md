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

Build the first iPhone preview on a Mac with Xcode and XcodeGen:

```sh
cd ios
brew install xcodegen
bash build_app.sh
```

This produces an unsigned IPA at `ios/build/PopinVR-unsigned.ipa`; it must be signed with your own iOS signing workflow before installation. The preview currently displays a side-by-side stereo test cube and reports ARKit/MediaPipe tracking status. It is an engineering preview, not yet headset-calibrated: lens distortion, MR passthrough, rendered hand meshes, and guest-runtime launch are still pending.

From the repository root, the guest runtime gates are:

```sh
make ios-device
make build/klepton-ld
KLEPTON_TARGET=<target-name> make ios-guest
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

The important part: Klepton already has a device-safe translated-library path.
`klepton-ld` can emit iOS-stamped Mach-O dylibs from Android ARM64 ELF libraries;
`kl_load_dylib` loads those through dyld, and the original ELF is retained in a
`__TEXT,__klelf` section. The iOS app must embed each translated library as a
framework and let Xcode code-sign it. The iOS runtime must prefer this packaged
framework path and must not rely on anonymous executable mappings or a JIT.

## Next milestones

1. Verify the iOS runtime compile/link gate in CI and fix platform-specific
   compile failures.
2. Generate iOS-stamped guest frameworks with `make ios-guest`, then embed and
   code-sign them in the app target.
3. Add a native iOS app target with a MetalKit SBS test scene and ARKit pose.
4. Add lens distortion/IPD calibration and a passthrough MR mode.
5. Connect the fixed-order hand/head tracking ABI to the OpenXR input layer.
6. Prove one small ARM64 Android guest can boot inside the iOS app before
   attempting large Quest titles.
7. Validate frame rate, motion-to-photon latency, thermals, memory use, and
   hand-tracking stability on the iPhone 16e.
