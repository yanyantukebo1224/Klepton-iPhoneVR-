#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${MOLTENVK_SRC:-$ROOT/vendor-moltenvk/src}"
TAG="${MOLTENVK_TAG:-v1.4.2}"
OUT="$ROOT/vendor-moltenvk/out"
FRAMEWORK="$SRC/Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"

if [[ ! -f "$SRC/fetchDependencies" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$SRC"
fi

cd "$SRC"
if [[ ! -d External/build ]]; then
  ./fetchDependencies --ios
fi
if [[ ! -f "$FRAMEWORK/MoltenVK" ]]; then
  make ios
fi
[[ -f "$FRAMEWORK/MoltenVK" ]] || { echo "MoltenVK iOS framework was not produced: $FRAMEWORK" >&2; exit 1; }

mkdir -p "$OUT/include" "$ROOT/ios/Vendor" "$ROOT/ios/App/ThirdPartyLicenses"
if [[ -d External/Vulkan-Headers/include/vulkan ]]; then
  cp -R External/Vulkan-Headers/include/. "$OUT/include/"
elif [[ -d External/Vulkan-Headers/include ]]; then
  cp -R External/Vulkan-Headers/include/. "$OUT/include/"
else
  echo "Vulkan-Headers include directory missing under $SRC/External" >&2
  find External -maxdepth 4 -type d -name vulkan -print
  exit 1
fi

rm -rf "$ROOT/ios/Vendor/MoltenVK.framework"
cp -R "$FRAMEWORK" "$ROOT/ios/Vendor/MoltenVK.framework"

# Keep the notices for MoltenVK and the bundled upstream dependencies with the app.
cp "$SRC/LICENSE" "$ROOT/ios/App/ThirdPartyLicenses/MoltenVK-Apache-2.0.txt"
for dep in SPIRV-Cross SPIRV-Tools cereal Vulkan-Headers; do
  for license in LICENSE LICENSE.md LICENSE.txt; do
    if [[ -f "$SRC/External/$dep/$license" ]]; then
      cp "$SRC/External/$dep/$license" "$ROOT/ios/App/ThirdPartyLicenses/$dep-$license"
      break
    fi
  done
done

echo "MoltenVK staged: $ROOT/ios/Vendor/MoltenVK.framework"
echo "Vulkan headers staged: $OUT/include"
