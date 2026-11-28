#!/usr/bin/env bash
# Translate a selected Android ARM64 guest into iOS-loadable frameworks.
# Xcode must later embed and code-sign every framework in the host app.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
TARGET="${KLEPTON_TARGET:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: KLEPTON_TARGET=<target-name> ./ios/mkguest.sh"
  python3 "$ROOT/visionos/targets.py" --list
  exit 2
fi

eval "$(python3 "$ROOT/visionos/targets.py" "$TARGET")"
LD="$ROOT/build/klepton-ld"
SRC="$ROOT/$KLT_SRCDIR"
OUT="$HERE/Frameworks/$KLT_NAME"
WORK="$ROOT/build/guest-ios/$KLT_NAME"

[[ -x "$LD" ]] || { echo "Missing $LD; run make build/klepton-ld first"; exit 1; }
[[ -n "$KLT_LIBS" ]] || { echo "Target $KLT_NAME has no configured guest libraries"; exit 1; }

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

for NAME in $KLT_LIBS; do
  [[ -f "$SRC/$NAME.so" ]] || { echo "Missing guest library: $SRC/$NAME.so"; exit 1; }
  ID_NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9.-' '-')"
  # App bundle executable names cannot contain '+'. kl_image.c applies this
  # same mapping when resolving the guest's original libc++_shared.so request.
  FWNAME="$(printf '%s' "$NAME" | tr '+' 'x')"
  FW="$WORK/$FWNAME.framework"
  mkdir -p "$FW"

  "$LD" "$SRC/$NAME.so" -o "$FW/$FWNAME" --platform ios \
    --install-name "@rpath/$FWNAME.framework/$FWNAME" --quiet

  cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$FWNAME</string>
  <key>CFBundleIdentifier</key><string>dev.popinvr.guest.$ID_NAME</string>
  <key>CFBundleName</key><string>$FWNAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST

  cp -R "$FW" "$OUT/"
  printf '  %-24s %s bytes\n' "$NAME" "$(stat -f%z "$FW/$FWNAME")"
done

echo "[ios-mkguest] $KLT_NAME translated for iOS -> $OUT/"
echo "Embed each generated .framework in the iOS app target and enable Code Sign On Copy."
