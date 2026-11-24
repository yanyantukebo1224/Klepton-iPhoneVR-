# iPhone integration: Husk + Klepton

Status: **integration design and iOS runtime build gate**. This branch does not yet launch a Quest APK and does not produce an IPA.

## Repository baseline

The starting tree is the same Klepton source snapshot as upstream commit
`365d21efe781bc2c5e4a95c1b85ed97d4f9ebfdf`. It is still a visionOS/macOS
project: its app generator selects the `xros` SDK, and its Swift frontend imports
Compositor Services. The C runtime is a much more promising iOS port boundary
than the current Swift frontend.

## Decision: use one Android loader, not two

Husk has two execution paths:

- QEMU system emulation: a complete Android guest, but slow and unnecessary as
  the first path for Java-thin ARM64 Quest titles.
- `src/translation-layer-next`: an in-process Android application runtime.
  Its source includes an ELF linker, Bionic ABI shims, JNI/HLE, Unity and
  NativeActivity/GameActivity launchers, ANGLE/EGL, MoltenVK/Vulkan, and a
  dual-view executable-memory allocator (`husk-tl-xmem`).

For iQuest, the second path is the one worth integrating. It is already written
for iOS and exposes a `CAMetalLayer`-based host surface. JIT is allowed for this
project; Husk's xmem path already handles executable memory and the
RW/RX-address split that its loader expects.

**Do not link both Android loaders into one guest process.** Husk's
`tl_ld/tl_lib` and Klepton's `kl_image/kl_dl` both own ELF mapping,
relocations, symbol scopes, and library lifetime. Running both would give one
guest two incompatible views of the same libraries and memory. The proposed
division is:

| Responsibility | Chosen implementation |
|---|---|
| APK/split APK reading and Android ELF loading | Husk `tl_ld` |
| Bionic, pthread, JNI/HLE, activity lifecycle | Husk `translation-layer-next` |
| JIT executable arena and code/data views | Husk `tl_xmem` |
| Unity / NativeActivity / GameActivity startup | Husk launchers, selected per APK |
| Quest OVRPlugin and OpenXR API compatibility | Klepton XR implementation, ported behind a Husk-facing adapter |
| iOS stereo compositor, camera passthrough, tracking | New iOS frontend; Metal + ARKit + AVFoundation + Vision |

## Why the XR code is not a drop-in

Klepton's `runtime/xr/kl_ovrp.c` and `kl_openxr.c` are valuable and should be
preserved. But they are not standalone libraries: they call Klepton-specific
loader, JNI, EGL, Vulkan, eye-framebuffer, guest-driver, and pose functions
(`kl_* `). Husk's loader uses different types and memory ownership
(`tl_lib`, `tl_ld_sym`, `tl_jni_*`, `tl_egl_*`, `tl_vk_*`).

The integration seam therefore needs an explicit adapter:
1. Let Husk load the Android game libraries and own their addresses.
2. Intercept the guest's `libOVRPlugin.so`, Oculus Platform loader, and
   `libopenxr_loader.so` requests before the real Android libraries are loaded.
3. Expose Klepton's implemented OVRPlugin/OpenXR entry points through synthetic
   handles, while translating guest-memory, symbol, graphics, and lifecycle
   operations to Husk APIs.
4. Replace the visionOS Compositor Services frontend with an iOS renderer.
   iOS does not provide Compositor Services. The iOS renderer must produce
   stereo eye images and submit them to the iPhone display through Metal.
5. Feed the XR runtime from ARKit world tracking (6DoF), Vision hand-pose
   observations, and AVFoundation camera frames. Vision hand points are not a
   ready-made 3D finger skeleton; that reconstruction remains a separate task.

The first integration milestone should be a small provider interface in the
Husk loader for synthetic Android libraries. Do not copy all of Klepton's
`kl_image.c` into Husk or make both loaders active.

## Reuse map

### Husk files to pin and study

- `src/translation-layer-next/husk-tl-ld.[ch]`: Android ELF mapping,
  relocations, symbol scopes, constructors, `dlopen/dlsym` support.
- `husk-tl-xmem.[ch]`: JIT memory arena and RW/RX views.
- `husk-tl-bionic*.[ch]`: Linux/Bionic ABI adaptation to Darwin.
- `husk-tl-jni*.[ch]` and `husk-tl-dvm*.[ch]`: Java/JNI compatibility.
- `husk-tl-unity.[ch]`, `husk-tl-nativeactivity.[ch]`,
  `husk-tl-gameactivity.[ch]`: Android game startup/lifecycle.
- `husk-tl-egl.[ch]`, `husk-tl-vulkan.[hm]`: ANGLE and MoltenVK gateways.
- `src/app/Husk/HuskGLView.swift` and `HuskMetalPresenter.swift`:
  CAMetalLayer/Metal presentation patterns.

### Klepton files to preserve and adapt

- `runtime/xr/kl_ovrp.[ch]`: OVRPlugin replacement and eye/controller pose
  state.
- `runtime/xr/kl_openxr.[ch]`: synthetic OpenXR runtime.
- `runtime/xr/kl_ovrplat.[ch]`: Oculus Platform compatibility surface.
- `runtime/gfx/kl_reproject.[ch]`: reusable reprojection math, after its
  presentation assumptions are separated.
- `tests/t_xrspace.c`, `tests/t_xrinput.c`, `tests/t_reproject.m`,
  `tests/t_ovrpfloor.c`: XR regression tests.

## Licensing

Klepton's repository license is MIT. Husk is GPL-2.0-or-later. MIT code can be
combined with GPL-2.0-or-later code, but an iQuest distribution that incorporates
Husk code must comply with the applicable GPL terms and retain all copyright
and license notices. The CI pins Husk to a commit rather than silently tracking
its moving main branch.

## What this branch proves

- `make check`: Klepton's existing host regression suite.
- `make ios-runtime`: compiles and links the existing Klepton C runtime for
  arm64 iOS and emits `build/ios/libklepton-ios.dylib`.

The iOS dylib is **not an IPA**, not a complete app, and not proof that the
OpenXR/OVRPlugin bridge works on iPhone. The CI also syntax-checks the selected
Husk iOS runtime sources against the iPhoneOS SDK. A green CI run is a compile
gate, not a device runtime test.

## Next implementation milestones

1. Add a small synthetic-library provider hook to Husk's `tl_ld`.
2. Port the Klepton OVRPlugin/OpenXR provider to that hook, one ABI family at
   a time, with the existing XR tests retained.
3. Add an iOS `CAMetalLayer` stereo host and an ARKit pose provider.
4. Add Vision hand tracking and a camera passthrough compositor.
5. Only then build an installable iPhone app and test an actual Quest APK.

The first candidate title should be a Java-thin, ARM64 Unity Quest APK without
Google Play Services, anti-cheat, or a dependency on Quest system services.
