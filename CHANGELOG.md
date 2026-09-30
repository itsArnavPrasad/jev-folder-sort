# Changelog

## 0.1.0 — first release

- Native SwiftUI menu-bar app for macOS 14+ (Apple Silicon).
- **Scope, enforced in code:**
  - watched folders, one destination root, and a checklist of allowed folders;
  - protected locations can't be chosen;
  - `ScopeGuard` is the only code that moves files, and never overwrites.
- **Sorting:** runs every 5, 10 or 15 minutes on new or changed files.
  - Rules run first (extension, name, source domain, file type).
  - Then the local model, including a "none of these fit" answer.
  - Anything below the confidence threshold goes to Review.
- **Review:** accept a suggestion, move a file to any allowed folder, or leave it where it is.
- **Undo:** a single move or a whole run.
- **Structure editor:** folder tree, descriptions, rules, and creating a folder inside the root.
- **On-device learning:**
  - from files already in your folders (read-only), Review choices and re-files;
  - the new model only activates if it isn't worse on held-out examples;
  - retrains automatically on mains power.
- Stats and onboarding.
- **Model** `minilm-0.4.0`: a System One decision head on a pretrained MiniLM encoder, with a description-matching prior. No longer depends on open-jev. **Describe folders in plain English and it follows the descriptions** (see docs/MODEL_HISTORY.md, docs/MODEL.md). It runs in a sandbox with no network access and never sees paths.
- **Learn from my folders**: in the app, or `scripts/learn_my_folders.sh`. Reads your already-sorted files (read-only), fine-tunes, and reports per-folder accuracy and a suggested threshold.
- **Self-contained DMG** with a bundled Python and PyTorch, so nothing needs to be installed.
