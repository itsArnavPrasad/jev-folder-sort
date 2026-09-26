#!/bin/bash
# Build every release artifact into build/release/:
#   jev-folder-sort-<v>-arm64.dmg (+ .sha256), jevsort-model-base.zip, RELEASE_NOTES.md
# Runs the full test suites first. Signing is ad-hoc unless SIGN_IDENTITY is set
# (then use scripts/notarize.sh instead of this for the DMG).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
OUT="$REPO/build/release"
cd "$REPO"

echo "==> Tests"
(cd engine && uv run pytest -q)
scripts/test.sh

echo "==> Engine bundle, app, DMG"
scripts/bundle_engine.sh
scripts/build_app.sh --release
scripts/make_dmg.sh

echo "==> End-to-end check of the release app on the demo playground"
scripts/make_demo.sh >/dev/null
E2E_DATA="$REPO/build/e2e-data"
rm -rf "$E2E_DATA"
env -u JEVSORT_ENGINE JEVSORT_DATA_DIR="$E2E_DATA" build/JevFolderSort.app/Contents/MacOS/JevFolderSort \
  --headless --demo examples/demo --sort > build/e2e.json
python3 - <<PY
import json; d = json.load(open("build/e2e.json"))
assert d["engine_bundled"], "release app did not use its bundled engine"
assert not d["scope_issues"], d["scope_issues"]
assert d["run"]["error"] is None, d["run"]
print("e2e ok:", d["engine"], d["run"])
PY

echo "==> Artifacts"
rm -rf "$OUT" && mkdir -p "$OUT"
cp build/jev-folder-sort-$VERSION-arm64.dmg build/jev-folder-sort-$VERSION-arm64.dmg.sha256 "$OUT/"
(cd engine/checkpoints && zip -qr "$OUT/jevsort-model-base.zip" base)
MODEL="$(python3 -c "import json; print(json.load(open('engine/checkpoints/base/meta.json'))['version'])")"
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{MODEL}}/$MODEL/g" \
    -e "s/{{SHA256}}/$(cut -d' ' -f1 "$OUT/jev-folder-sort-$VERSION-arm64.dmg.sha256")/g" \
    docs/RELEASE_NOTES_TEMPLATE.md > "$OUT/RELEASE_NOTES.md"
ls -lh "$OUT"
