#!/bin/bash
# Download the released base model into engine/checkpoints/base (instead of training it).
#   scripts/fetch_model.sh [tag]      default: the tag in VERSION (v<version>)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v$(cat "$REPO/VERSION")}"
URL="https://github.com/itsArnavPrasad/jev-folder-sort/releases/download/$TAG/jevsort-model-base.zip"
DEST="$REPO/engine/checkpoints"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
echo "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/model.zip"
rm -rf "$DEST/base"
unzip -q "$TMP/model.zip" -d "$DEST"
rm -rf "$TMP"
cat "$DEST/base/meta.json"
