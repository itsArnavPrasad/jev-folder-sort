#!/bin/bash
# Assemble a self-contained engine for the release app: build/engine/
#   python/         relocatable CPython 3.12 (python-build-standalone, via uv)
#   site-packages/  torch, tokenizers, safetensors, numpy, ... (trimmed)
#   app/            jevsort_engine, datasets, open_jev (vendored)
#   checkpoints/base/
# Usage: scripts/bundle_engine.sh [checkpoint_dir]   (default engine/checkpoints/base)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/engine"
CKPT="${1:-$REPO/engine/checkpoints/base}"
[[ -f "$CKPT/model.safetensors" ]] || { echo "no checkpoint at $CKPT (train one or run scripts/fetch_model.sh)"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"/{app,site-packages,checkpoints}

echo "==> Python (python-build-standalone 3.12)"
PYDIR="$REPO/build/.python"
UV_PYTHON_INSTALL_DIR="$PYDIR" uv python install 3.12 >/dev/null
SRC_PY="$(UV_PYTHON_INSTALL_DIR="$PYDIR" uv python find 3.12 --managed-python)"
SRC_ROOT="$(cd "$(dirname "$SRC_PY")/.." && pwd -P)"
cp -R "$SRC_ROOT" "$OUT/python"
rm -f "$OUT"/python/lib/python3.12/EXTERNALLY-MANAGED
PY="$OUT/python/bin/python3"

echo "==> Packages (pinned from engine/uv.lock)"
# huggingface_hub (+hf_xet) is only used at training time to fetch MiniLM; not needed in the app.
(cd "$REPO/engine" && uv export --frozen --no-dev --no-hashes --no-emit-project -q) \
  | grep -vE '^(huggingface-hub|hf-xet|setuptools)==' > "$REPO/build/requirements.txt"
uv pip install -q --python "$PY" --target "$OUT/site-packages" -r "$REPO/build/requirements.txt"

echo "==> Engine code + model"
rsync -a --exclude __pycache__ "$REPO/engine/jevsort_engine" "$OUT/app/"
rsync -a --exclude __pycache__ --exclude generated "$REPO/engine/datasets" "$OUT/app/"
rsync -a --exclude __pycache__ "$REPO/engine/third_party/open_jev" "$OUT/app/"
rsync -a "$CKPT/" "$OUT/checkpoints/base/"

echo "==> Trim"
SP="$OUT/site-packages"
rm -rf "$SP"/torch/include "$SP"/torch/share "$SP"/torch/test \
       "$SP"/torch/_inductor/codegen/cuda "$SP"/*/tests "$SP"/numpy/_core/tests "$SP"/*.dist-info/RECORD
find "$SP" -name "*.a" -delete
rm -rf "$SP"/huggingface_hub "$SP"/hf_xet "$SP"/setuptools "$SP"/_distutils_hack "$SP"/distutils-precedence.pth
# Local symbols only; everything is re-signed when the app is assembled.
find "$SP" "$OUT/python" \( -name "*.dylib" -o -name "*.so" \) -type f -exec strip -x {} \; 2>/dev/null
# Apple Silicon refuses to load unsigned code: re-sign ad-hoc (release signing re-signs again).
find "$SP" "$OUT/python" \( -name "*.dylib" -o -name "*.so" \) -type f -exec codesign --force --sign - {} \; 2>/dev/null
LIB="$OUT/python/lib/python3.12"
rm -rf "$LIB"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} "$LIB"/site-packages/pip* \
       "$OUT"/python/lib/{tcl*,tk*,itcl*,thread*} "$OUT"/python/include "$OUT"/python/share
find "$OUT" -name __pycache__ -type d -prune -exec rm -rf {} +

echo "==> Precompile (the sandbox won't let Python write .pyc at runtime)"
"$PY" -m compileall -q -j 0 "$OUT/app" "$SP" "$LIB" >/dev/null || true

echo "==> Smoke test"
PYTHONPATH="$OUT/app:$SP" PYTHONNOUSERSITE=1 HF_HUB_OFFLINE=1 "$PY" -s -c "
import torch, tokenizers, safetensors, jevsort_engine.server, jevsort_engine.personalize
from jevsort_engine.model import load_checkpoint
from pathlib import Path
m, meta = load_checkpoint(Path('$OUT/checkpoints/base'))
print('torch', torch.__version__, '| model', meta['version'])"
du -sh "$OUT" "$SP/torch" "$OUT/python"
