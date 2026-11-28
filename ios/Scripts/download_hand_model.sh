#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/Models"
DEST="$MODEL_DIR/hand_landmarker.task"
TMP="$DEST.download"

URL="https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
SHA256="fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"

mkdir -p "$MODEL_DIR"
if [[ -f "$DEST" ]] && echo "$SHA256  $DEST" | shasum -a 256 -c --status; then
  echo "Hand Landmarker model already verified: $DEST"
  exit 0
fi

echo "Downloading the pinned MediaPipe Hand Landmarker model..."
curl --fail --location --retry 3 --output "$TMP" "$URL"
echo "$SHA256  $TMP" | shasum -a 256 -c -
mv "$TMP" "$DEST"
echo "Model ready: $DEST"
