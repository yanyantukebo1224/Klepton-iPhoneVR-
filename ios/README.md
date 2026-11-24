# iOS XR frontend integration

This directory contains the native iOS boundary for the iQuest runtime.

## Runtime ownership

- Husk Translation Layer owns APK/ELF loading, Bionic/JNI emulation, Android activity startup, JIT memory, EGL/ANGLE and Vulkan/MoltenVK.
- Klepton owns the Quest-facing OVRPlugin/OpenXR compatibility layer.
- The iOS frontend owns ARKit tracking, camera/Vision input, lifecycle, and the Metal presentation surface.

Do not load the same guest ELF through both Husk's `tl_ld` and Klepton's `kl_image`. The bridge currently targets Husk's Unity host API (`tl_unity_start/run/stop`) and publishes the ARKit head pose through `kl_ovrp_set_head_pose`.

## Current implementation boundary

`KleptonIOSBridge.m` is the native ABI seam. It expects Husk's `husk-tl-unity.h` and Klepton's `kl_ovrp.h` to be included in the app target and the corresponding runtime objects to be linked.

`IOSXRTracking.swift` provides:
- ARKit gravity-aligned 6DoF head pose, sent to Klepton every AR frame.
- Vision hand landmarks for up to two hands.

Vision landmarks are normalized 2D camera points. They are not a metric 3D skeleton and are not yet forwarded as OVRPlugin hand joints. iPhone 16e has no LiDAR, so a depth-aware hand reconstruction or a different sensing strategy is still required before claiming Quest-equivalent 3D finger tracking.

## Important runtime prerequisites

Husk's JIT allocator expects the app's JIT memory region to be provisioned by the supported iOS JIT workflow before guest code is loaded. A successful simulator build or a compile-only test does not grant executable memory on a physical device. Do not silently fall back to running guest code without the required permission.

The current Unity host surface is a single Metal layer. Full stereo VR requires the iOS compositor/swapchain path to consume Klepton's eye textures; passing a CAMetalLayer to the 2D Unity surface is not, by itself, a stereo compositor.
