#!/bin/bash
# Teach jev-folder-sort your own folder structure from files you've already sorted.
#
#   scripts/learn_my_folders.sh <root> [--per-folder N] [--install]
#
# <root>          a folder whose sub-folders are your categories (e.g. ~/Documents/Sorted).
#                 Files inside are only READ (name, metadata, first KB of text); nothing is moved.
# --per-folder N  how many recent files to read from each sub-folder (default 100).
# --install       copy the resulting model + suggested threshold into the app's own data
#                 (~/Library/Application Support/jev-folder-sort). Quit the app first.
#
# Without --install everything stays in ./.jevsort-learn/ so you can inspect the report first.
# Tip: open the app first and add plain-English descriptions to your folders in Structure; this
# script uses a separate working copy, so pass --install to put the learned model into the app.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:?usage: scripts/learn_my_folders.sh <root> [--per-folder N] [--install]}"
shift
PER=100
INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --per-folder) PER="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

APP_BIN="$REPO/build/JevFolderSort.app/Contents/MacOS/JevFolderSort"
[[ -x "$APP_BIN" ]] || APP_BIN="/Applications/jev-folder-sort.app/Contents/MacOS/JevFolderSort"
[[ -x "$APP_BIN" ]] || { echo "build the app first: scripts/build_app.sh"; exit 1; }

WORK="$REPO/.jevsort-learn"
mkdir -p "$WORK"
echo "Reading up to $PER files per folder under $ROOT (read-only)…"
JEVSORT_DATA_DIR="$WORK" JEVSORT_ENGINE="$REPO/engine" "$APP_BIN" --headless \
  --learn-from "$ROOT" --per-folder "$PER" --apply-threshold > "$WORK/report.json"

python3 - "$WORK/report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); r = d["train"]
print(f"\nExamples: {r['examples']}  (held out for testing: {r.get('holdout', 0)})")
if not r["activated"]:
    print("Not activated:", r.get("reason")); sys.exit(0)
print(f"Held-out accuracy: {r['new_accuracy']:.0%} personalised vs {r['current_accuracy']:.0%} base model")
print(f"Suggested confidence threshold: {r.get('suggested_threshold') or 'keep 90%'}")
print("\nPer folder (held-out correct / total · examples):")
for k in sorted(r.get("per_folder", {})):
    v = r["per_folder"][k]; n = r.get("examples_per_folder", {}).get(k, 0)
    print(f"  {k:40} {v['correct']}/{v['held_out']} · {n}")
thin = [k for k, n in r.get("examples_per_folder", {}).items() if n < 5]
if thin:
    print("\nFew examples (add descriptions for these in Structure):", ", ".join(sorted(thin)))
print(f"\nModel: {d.get('user_model')}")
PY

if [[ $INSTALL == 1 ]]; then
  if pgrep -f "jev-folder-sort.app/Contents/MacOS/JevFolderSort|JevFolderSort.app/Contents/MacOS/JevFolderSort" | grep -v $$ >/dev/null; then
    echo "Quit jev-folder-sort first, then re-run with --install."; exit 1
  fi
  DEST="$HOME/Library/Application Support/jev-folder-sort/models"
  mkdir -p "$DEST"
  rm -rf "$DEST/user.new" && cp -R "$WORK/models/user" "$DEST/user.new"
  rm -rf "$DEST/user" && mv "$DEST/user.new" "$DEST/user"
  echo "Installed the personalised model. Open the app; Settings → Model shows it as active."
fi
