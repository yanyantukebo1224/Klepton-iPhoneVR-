// SPDX-License-Identifier: GPL-2.0-or-later
#import "KleptonIOSBridge.h"

#include "husk-tl-unity.h"
#include "kl_ovrp.h"

#include <stdatomic.h>

static atomic_bool g_guest_started = false;

bool ki_start_unity_guest(const char *apkPath,
                          const char *dataDirectory,
                          const char *packageName,
                          int pixelWidth,
                          int pixelHeight,
                          CAMetalLayer *metalLayer,
                          const char *angleEGL,
                          const char *angleGLES) {
    if (!apkPath || !dataDirectory || !packageName ||
        pixelWidth <= 0 || pixelHeight <= 0) return false;

    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_guest_started, &expected, true)) {
        return false;
    }

    tl_unity_config config = {
        .apk_path = apkPath,
        .data_dir = dataDirectory,
        .package_name = packageName,
        .width = pixelWidth,
        .height = pixelHeight,
        .metal_layer = (__bridge void *)metalLayer,
        .angle_egl = angleEGL,
        .angle_gles = angleGLES,
        .frame_dir = NULL,
        .frame_every = 0,
    };

    if (!tl_unity_start(&config) || !tl_unity_run()) {
        atomic_store(&g_guest_started, false);
        return false;
    }
    return true;
}

void ki_stop_guest(void) {
    if (!atomic_exchange(&g_guest_started, false)) return;
    tl_unity_stop();
}

void ki_set_guest_paused(bool paused) {
    if (atomic_load(&g_guest_started)) tl_unity_set_paused(paused);
}

void ki_guest_touch(int phase, int fingerID, float x, float y) {
    if (atomic_load(&g_guest_started)) tl_unity_touch(phase, fingerID, x, y);
}

unsigned long ki_guest_frames(void) {
    return atomic_load(&g_guest_started) ? tl_unity_frames() : 0;
}

void ki_publish_head_pose(float px, float py, float pz,
                          float qx, float qy, float qz, float qw) {
    kl_ovrp_set_head_pose(px, py, pz, qx, qy, qz, qw);
}

void ki_publish_hand_pose(int hand, float px, float py, float pz,
                          float qx, float qy, float qz, float qw) {
    kl_ovrp_set_hand_pose(hand, px, py, pz, qx, qy, qz, qw);
}
