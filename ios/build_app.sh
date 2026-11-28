#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

bash ./Scripts/download_hand_model.sh
xcodegen generate --spec project.yml
xcodebuild \
  -project PopinVR.xcodeproj \
  -scheme PopinVR \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build/Build/Products/Release-iphoneos/PopinVR.app"
[[ -d "$APP" ]] || { echo "Build product not found: $APP"; exit 1; }
mkdir -p build/ipa/Payload
rm -rf build/ipa/Payload/PopinVR.app
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && /usr/bin/zip -qry ../PopinVR-unsigned.ipa Payload)
echo "Unsigned IPA ready: $HERE/build/PopinVR-unsigned.ipa"
echo "Import this IPA into your own signing workflow before installing it."
