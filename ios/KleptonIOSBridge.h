// SPDX-License-Identifier: GPL-2.0-or-later
// Objective-C boundary between the iOS frontend and Husk/Klepton C runtimes.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts a Unity Android guest through Husk's Translation Layer.
/// The caller must have obtained JIT/executable-memory permission before calling.
bool ki_start_unity_guest(const char *apkPath,
                          const char *dataDirectory,
                          const char *packageName,
                          int pixelWidth,
                          int pixelHeight,
                          CAMetalLayer * _Nullable metalLayer,
                          const char * _Nullable angleEGL,
                          const char * _Nullable angleGLES);

void ki_stop_guest(void);
void ki_set_guest_paused(bool paused);
void ki_guest_touch(int phase, int fingerID, float x, float y);
unsigned long ki_guest_frames(void);

/// Publishes the latest ARKit world pose to Klepton's OVRPlugin compatibility layer.
void ki_publish_head_pose(float px, float py, float pz,
                          float qx, float qy, float qz, float qw);

NS_ASSUME_NONNULL_END
