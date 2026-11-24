# iOS XR frontend integration

This directory contains the native iOS boundary for the iQuest runtime.

## Runtime ownership

- Husk Translation Layer owns APK/ELF loading, Bionic/JNI emulation, Android activity startup, JIT memory, EGL/ANGLE and Vulkan/MoltenVK.
- Klepton owns the Quest-facing OVRPlugin/OpenXR compatibility layer.
- The iOS frontend owns ARKit tracking, camera/Vision input, lifecycle, and the Metal presentation surface.

Do not load the same guest ELF through both Husk's `tl_ld` and Klepton's `kl_image`. The bridge currently targets Husk's Unity host API (`tl_unity_start/run/stop`) and publishes ARKit head pose through `kl_ovrp_set_head_pose`. The integration script also patches Husk's guest-side `dlopen/dlsym` dispatch so Android guests requesting `libOVRPlugin.so` and `libopenxr_loader.so` receive Klepton's synthetic handles and symbol resolvers.

## Current implementation boundary

`KleptonIOSBridge.m` is the native ABI seam. It expects Husk's `husk-tl-unity.h` and Klepton's `kl_ovrp.h` to be included in the app target and the corresponding runtime objects to be linked.

`IOSXRTracking.swift` provides:
- ARKit gravity-aligned 6DoF head pose, sent to Klepton every AR frame.
- Vision hand landmarks for up to two hands.
- Approximate 3D wrist pose sent to Klepton's OVRPlugin hand-pose seam. Depth is estimated from apparent palm width, so it is a monocular approximation rather than a measured depth.

The 21 Vision landmarks remain camera-space 2D points; the current bridge does not yet populate the Quest 64-bone hand skeleton. iPhone 16e has no LiDAR, so Quest-equivalent metric finger tracking is not claimed. The hand root pose is now connected, while the finger-joint ABI/layout remains to be implemented and validated.

## Important runtime prerequisites

Husk's JIT allocator expects the app's JIT memory region to be provisioned by the supported iOS JIT workflow before guest code is loaded. A successful simulator build or a compile-only test does not grant executable memory on a physical device. Do not silently fall back to running guest code without the required permission.

The current Unity host surface is a single Metal layer. Full stereo VR requires the iOS compositor/swapchain path to consume Klepton's eye textures; passing a CAMetalLayer to the 2D Unity surface is not, by itself, a stereo compositor.
