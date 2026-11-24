#!/usr/bin/env bash
# Assemble the pinned Husk iOS app with the iQuest native bridge and Klepton XR runtime.
# Run from any directory; requires Xcode command-line tools and git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HUSK_DIR="${HUSK_DIR:-$ROOT/deps/Husk}"
HUSK_REPO="https://github.com/Leviidev/Husk.git"
HUSK_REV="29abb512d81bf8cc08babcbe7f7007cb557208ef"

if [ ! -d "$HUSK_DIR/.git" ]; then
  mkdir -p "$(dirname "$HUSK_DIR")"
  git clone --filter=blob:none "$HUSK_REPO" "$HUSK_DIR"
fi
git -C "$HUSK_DIR" fetch --depth 1 origin "$HUSK_REV"
git -C "$HUSK_DIR" checkout --detach "$HUSK_REV"

# Build Klepton's existing C runtime for the same physical-device architecture.
make -C "$ROOT" ios-runtime

mkdir -p "$HUSK_DIR/build/ios-arm64/lib" "$HUSK_DIR/src/app/IQuestXR"
cp "$ROOT/build/ios/libklepton-ios.dylib" "$HUSK_DIR/build/ios-arm64/lib/"
cp "$ROOT/ios/KleptonIOSBridge.h" "$ROOT/ios/KleptonIOSBridge.m" "$ROOT/ios/IOSXRTracking.swift" "$ROOT/ios/IOSVRCompositor.swift" "$ROOT/ios/IQuestStereo.metal" "$HUSK_DIR/src/app/IQuestXR/"
cp "$ROOT/runtime/xr/kl_ovrp.h" "$ROOT/runtime/gfx/kl_glfb.h" "$HUSK_DIR/src/app/IQuestXR/"
cp "$HUSK_DIR/src/translation-layer-next/husk-tl-unity.h" "$HUSK_DIR/src/app/IQuestXR/"

python3 - "$HUSK_DIR/src/app/project.yml" "$HUSK_DIR/src/app/Husk/HuskBridge.h" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
bridge = Path(sys.argv[2])
text = project.read_text()

# ARKit/Vision use the rear camera for head and hand tracking.
import plistlib
info_plist = bridge.parent / "Info.plist"
plist = plistlib.loads(info_plist.read_bytes())
plist["CFBundleDisplayName"] = "iQuest"
plist["NSCameraUsageDescription"] = "iQuest uses the camera for ARKit head tracking and hand tracking while playing VR games."
info_plist.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))

# The linked Klepton runtime is built for iOS 17; this project targets the
# requested iPhone 16e class of devices, not legacy iOS 15 hardware.
text = text.replace('    iOS: "15.5"', '    iOS: "17.0"', 1)
text = text.replace('    HUSK_BUNDLE_IDENTIFIER: com.husk.app', '    HUSK_BUNDLE_IDENTIFIER: com.yanyantukebo1224.iquest', 1)

source_marker = "      - path: Husk\n"
if source_marker not in text:
    raise SystemExit("Could not find the Husk app source entry in project.yml")
if "      - path: IQuestXR\n" not in text:
    text = text.replace(source_marker, source_marker + "      - path: IQuestXR\n", 1)

framework_marker = "      - framework: ../../build/ios-arm64/lib/libqemu-aarch64-softmmu.dylib\n"
framework = (
    "      - framework: ../../build/ios-arm64/lib/libklepton-ios.dylib\n"
    "        embed: true\n"
    "        codeSign: true\n"
)
if framework_marker not in text:
    raise SystemExit("Could not find the QEMU framework dependency marker")
if "libklepton-ios.dylib" not in text:
    text = text.replace(framework_marker, framework + framework_marker, 1)

search_marker = "        LIBRARY_SEARCH_PATHS:\n"
search_block = (
    "        HEADER_SEARCH_PATHS:\n"
    "          - \"$(inherited)\"\n"
    "          - \"$(SRCROOT)/IQuestXR\"\n"
    "          - \"$(SRCROOT)/../translation-layer-next\"\n"
)
if search_marker not in text:
    raise SystemExit("Could not find LIBRARY_SEARCH_PATHS in project.yml")
if "$(SRCROOT)/IQuestXR" not in text:
    text = text.replace(search_marker, search_block + search_marker, 1)
project.write_text(text)

b = bridge.read_text()
if '#import "KleptonIOSBridge.h"' not in b:
    b += '\n// iQuest XR runtime bridge.\n#import "KleptonIOSBridge.h"\n'
    bridge.write_text(b)

# Start ARKit while a supported 3D guest is in the foreground.
view = Path(sys.argv[2]).parent / "TLUnityView.swift"
v = view.read_text()
if "import Metal\n" not in v:
    v = v.replace("import QuartzCore\n", "import QuartzCore\nimport Metal\n", 1)
if "private let iQuestCompositorLayer = CAMetalLayer()" not in v:
    v = v.replace("    private let apk: String\n",
                  "    private let apk: String\n    private let iQuestCompositorLayer = CAMetalLayer()\n", 1)
if "stats.isHidden = true" not in v:
    v = v.replace('        stats.text = " "', '        stats.text = " "\n        stats.isHidden = true', 1)

metal_block = """        if let metal = layer as? CAMetalLayer {
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = scale
            metal.isOpaque = true
        }
"""
if "self.layer.addSublayer(iQuestCompositorLayer)" not in v:
    v = v.replace(metal_block, metal_block + """        iQuestCompositorLayer.device = (layer as? CAMetalLayer)?.device ?? MTLCreateSystemDefaultDevice()
        iQuestCompositorLayer.pixelFormat = .bgra8Unorm
        iQuestCompositorLayer.framebufferOnly = true
        iQuestCompositorLayer.contentsScale = scale
        iQuestCompositorLayer.isOpaque = true
        iQuestCompositorLayer.zPosition = 1000
        iQuestCompositorLayer.isHidden = true
        self.layer.addSublayer(iQuestCompositorLayer)
""", 1)
if "iQuestCompositorLayer.drawableSize = CGSize(width: w, height: h)" not in v:
    v = v.replace("        if !(engine == .ue4 && launched) { (layer as? CAMetalLayer)?.drawableSize = CGSize(width: w, height: h) }",
                  "        if !(engine == .ue4 && launched) { (layer as? CAMetalLayer)?.drawableSize = CGSize(width: w, height: h) }\n        iQuestCompositorLayer.frame = bounds\n        iQuestCompositorLayer.drawableSize = CGSize(width: w, height: h)", 1)
if "IOSVRCompositor.shared.stop()" not in v:
    v = v.replace("        } else {\n            iQuestXRTracking?.stop()",
                  "        } else {\n            IOSVRCompositor.shared.stop()\n            iQuestCompositorLayer.isHidden = true\n            iQuestXRTracking?.stop()", 1)
if "IOSVRCompositor.shared.start(guestLayer:" not in v:
    v = v.replace("        let layerPtr = Unmanaged.passUnretained(layer).toOpaque()",
                  "        let layerPtr = Unmanaged.passUnretained(layer).toOpaque()\n        if engine == .unity || engine == .ue4 || engine == .nativeactivity || engine == .godot || engine == .sdl || engine == .minecraft {\n            iQuestCompositorLayer.isHidden = false\n            if let guest = layer as? CAMetalLayer { IOSVRCompositor.shared.start(guestLayer: guest, outputLayer: iQuestCompositorLayer) }\n        }", 1)
view.write_text(v)
if "private var iQuestXRTracking: IOSXRTracking?" not in v:
    v = v.replace("    private let apk: String\n",
                  "    private let apk: String\n    private var iQuestXRTracking: IOSXRTracking?\n", 1)
if "iQuestXRTracking?.stop()" not in v:
    v = v.replace("        } else {\n            husk_unity_set_paused(true)",
                  "        } else {\n            iQuestXRTracking?.stop()\n            husk_unity_set_paused(true)", 1)
if "iQuestXRTracking?.start()" not in v:
    v = v.replace("        if window != nil {\n            husk_unity_set_paused(false)",
                  "        if window != nil {\n            husk_unity_set_paused(false)\n            iQuestXRTracking?.start()", 1)
if "if launched && (engine == .unity || engine == .ue4 || engine == .nativeactivity || engine == .godot || engine == .sdl || engine == .minecraft)" not in v:
    v = v.replace("            iQuestXRTracking?.start()\n            statsTimer",
                  "            iQuestXRTracking?.start()\n            if launched && (engine == .unity || engine == .ue4 || engine == .nativeactivity || engine == .godot || engine == .sdl || engine == .minecraft) {\n                iQuestCompositorLayer.isHidden = false\n                if let guest = layer as? CAMetalLayer { IOSVRCompositor.shared.start(guestLayer: guest, outputLayer: iQuestCompositorLayer) }\n            }\n            statsTimer", 1)
if "iQuestXRTracking = IOSXRTracking()" not in v:
    v = v.replace('        if !started { HuskLog.log("tl", "native: launch refused") }',
                  '        if !started {\n            HuskLog.log("tl", "native: launch refused")\n        } else if engine == .unity || engine == .ue4 || engine == .nativeactivity || engine == .godot || engine == .sdl || engine == .minecraft {\n            let tracking = IOSXRTracking()\n            iQuestXRTracking = tracking\n            tracking.start()\n        }', 1)
view.write_text(v)

# Route Android's guest-side dlopen/dlsym through Klepton's synthetic XR
# libraries. This is the crucial seam: neither Android's real OVRPlugin nor
# the Android OpenXR loader can be loaded as an iOS-native library.
bionic = project.parent.parent / "translation-layer-next" / "husk-tl-bionic.c"
src = bionic.read_text()
decls = (
    "\n/* iQuest synthetic Quest XR libraries (implemented by libklepton-ios). */\n"
    "extern int kl_ovrp_claims(const char *soname);\n"
    "extern void *kl_ovrp_dlopen(const char *soname);\n"
    "extern int kl_ovrp_is_handle(const void *handle);\n"
    "extern void *kl_ovrp_sym(const char *name);\n"
    "extern int kl_openxr_claims(const char *soname);\n"
    "extern void *kl_openxr_dlopen(const char *soname);\n"
    "extern int kl_openxr_is_handle(const void *handle);\n"
    "extern void *kl_openxr_sym(const char *name);\n"
)
if "kl_ovrp_claims" not in src:
    include_marker = '#include "husk-tl-ld.h"'
    if include_marker not in src:
        raise SystemExit("Could not find Husk dynamic linker include marker")
    src = src.replace(include_marker, include_marker + decls, 1)

dl_marker = "    base = base ? base + 1 : path;\n"
dl_hook = (
    "    base = base ? base + 1 : path;\n"
    "    if (kl_ovrp_claims(base)) return kl_ovrp_dlopen(base);\n"
    "    if (kl_openxr_claims(base)) return kl_openxr_dlopen(base);\n"
)
if "if (kl_ovrp_claims(base))" not in src:
    if dl_marker not in src:
        raise SystemExit("Could not find Husk dlopen soname normalization")
    src = src.replace(dl_marker, dl_hook, 1)

sym_marker = "    if (handle == (void *)-1L) {"
sym_hook = (
    "    if (kl_ovrp_is_handle(handle)) {\n"
    "        r = kl_ovrp_sym(name);\n"
    "    } else if (kl_openxr_is_handle(handle)) {\n"
    "        r = kl_openxr_sym(name);\n"
    "    } else if (handle == (void *)-1L) {"
)
if "if (kl_ovrp_is_handle(handle))" not in src:
    if sym_marker not in src:
        raise SystemExit("Could not find Husk dlsym dispatch")
    src = src.replace(sym_marker, sym_hook, 1)
bionic.write_text(src)
PY

cd "$HUSK_DIR/src/app"
xcodegen generate
echo "Prepared Husk app project with iQuest XR bridge."
echo "Next: run scripts/ci_build.sh to build the complete IPA."
