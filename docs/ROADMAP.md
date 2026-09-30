# Roadmap

## v1 milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | ✅ **Engine spike** | (Historical: vendored open-jev, since replaced by our own model, see MODEL_HISTORY.md) runs locally (CPU, MPS optional); pretrained tokenizer swapped in; `classify` works over the stdin/stdout protocol |
| M1 | ✅ **Base model** | Synthetic dataset + training script; base checkpoint beats a filename-keyword baseline on the held-out eval; ECE measured |
| M2 | ✅ **App skeleton** | Menu-bar app, settings persisted in SQLite, engine child process start/stop/health |
| M3 | ✅ **Core pipeline** | Interval scanner with snapshot diff, extractor (metadata + first N KB), rules, mover with collision handling, history log |
| M4 | ✅ **Structure editor** | Build tree in UI, import from disk, per-folder descriptions and rules |
| M5 | ✅ **Review + undo** | Confidence gate, Review list, undo single move / whole run, preview mode |
| M6 | ✅ **Learning** | Bootstrap on existing files, correction capture (explicit + implicit), background fine-tune with safety check |
| M7 | ✅ **Stats + polish** | Stats screen, launch at login, pause, battery awareness, onboarding flow |
| M8 | ✅ **Release** | Bundled Python + PyTorch, signed + notarized `.dmg` on GitHub Releases, README with install steps and demo GIF |

**Status (2026-09-27):** all of M0–M8 is done on branch `feat/m0-m3`:
- **M5:** preview mode and the confidence gate shipped in M3, and Review and undo are in the main window.
- **M7:** battery awareness means interval runs are skipped in Low Power Mode, and training only runs on AC power.
- **M8:**
  - The DMG is ad-hoc signed. `scripts/notarize.sh` is ready for when there's a Developer ID.
  - The demo GIF still needs to be recorded (see RELEASING.md).

M0–M1 carry the most risk (does a small local open-jev sort well enough?), so they come first. M2–M5 can use a stub engine in parallel.

## Future versions

Deliberately deferred from v1:

- **System Two fallback.** For files the fast model is unsure about (the Review queue), optionally ask a small local generative model (e.g. a 0.5–1.5B model via MLX) with constrained output over the allowed folders. It could also act as an offline *teacher* to distill into the fast model. The fast System One path stays the default.
- **Bigger or multilingual encoder** (e5/bge small or base, 30–110M) as a drop-in for MiniLM.

- **Create new folders.** Let the model propose a new sub-folder when nothing fits well (with user approval).
- **Rename files.** Suggest clean, consistent names (e.g. `2025-03 Acme Invoice.pdf`).
- **Core ML inference.** Export the trained model to Core ML to drop PyTorch from the default install and shrink the DMG; keep PyTorch only for fine-tuning.
- **Image understanding.** OCR screenshots and scanned documents with Apple Vision; add image content to the state.
- **Instant mode.** FSEvents-driven sorting as files arrive, as an alternative to interval scans.
- **Sub-folder recursion** for watched folders.
- **Homebrew cask** distribution.

Considered and **not planned** (to stay lightweight): duplicate handling, multiple profiles, iCloud Drive / cloud-synced folders, Mac App Store, any hosted/cloud model.
