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
cp "$ROOT/ios/KleptonIOSBridge.h" "$ROOT/ios/KleptonIOSBridge.m" "$ROOT/ios/IOSXRTracking.swift" "$HUSK_DIR/src/app/IQuestXR/"
cp "$ROOT/runtime/xr/kl_ovrp.h" "$HUSK_DIR/src/app/IQuestXR/"
cp "$HUSK_DIR/src/translation-layer-next/husk-tl-unity.h" "$HUSK_DIR/src/app/IQuestXR/"

python3 - "$HUSK_DIR/src/app/project.yml" "$HUSK_DIR/src/app/Husk/HuskBridge.h" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
bridge = Path(sys.argv[2])
text = project.read_text()

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
if "IQuestXR" not in text.split(search_marker)[0]:
    text = text.replace(search_marker, search_block + search_marker, 1)
project.write_text(text)

b = bridge.read_text()
if '#import "KleptonIOSBridge.h"' not in b:
    b += '\n// iQuest XR runtime bridge.\n#import "KleptonIOSBridge.h"\n'
    bridge.write_text(b)

# Start ARKit only while a Unity guest is in the foreground.
view = Path(sys.argv[2]).parent / "TLUnityView.swift"
v = view.read_text()
if "private var iQuestXRTracking: IOSXRTracking?" not in v:
    v = v.replace("    private let apk: String\n",
                  "    private let apk: String\n    private var iQuestXRTracking: IOSXRTracking?\n", 1)
if "iQuestXRTracking?.stop()" not in v:
    v = v.replace("        } else {\n            husk_unity_set_paused(true)",
                  "        } else {\n            iQuestXRTracking?.stop()\n            husk_unity_set_paused(true)", 1)
if "iQuestXRTracking = IOSXRTracking()" not in v:
    v = v.replace('        if !started { HuskLog.log("tl", "native: launch refused") }',
                  '        if !started {\n            HuskLog.log("tl", "native: launch refused")\n        } else if engine == .unity {\n            let tracking = IOSXRTracking()\n            iQuestXRTracking = tracking\n            tracking.start()\n        }', 1)
view.write_text(v)
PY

cd "$HUSK_DIR/src/app"
xcodegen generate
echo "Prepared Husk app project with iQuest XR bridge."
echo "Next: run scripts/ci_build.sh to build the complete IPA."
