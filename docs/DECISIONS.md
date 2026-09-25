# Decision Log

Product and technical decisions for v1, with the reasoning behind each.

## Product decisions

| # | Decision | Notes |
|---|---|---|
| P1 | Built for general Mac users, and good enough for the author to use daily | |
| P2 | Watched folders are configurable in the UI; defaults are Desktop + Downloads | |
| P3 | Sorting runs on an interval (5 / 10 / 15 min, configurable), only on new or changed files; plus *Sort now* | FSEvents "instant mode" is a future option |
| P4 | Files only go into folders the user defined | Creating new folders is a future feature |
| P5 | Structure is defined in the UI: build a tree, or import an existing folder hierarchy | |
| P6 | Folders can carry rules, which override the model | |
| P7 | Move only, no renaming (except Finder-style suffix on name collisions) | Renaming is a future feature |
| P8 | The model reads filename, metadata and the first N KB of text; N configurable | Images: metadata only in v1 |
| P9 | Everything runs locally. No cloud APIs, no telemetry | |
| P10 | The model learns from the user's corrections | See MODEL.md stages B/C |
| P11 | Screens: menu bar, History/Undo, Review, Structure, Stats, Settings | Keep only what's necessary |
| P12 | macOS 14+, Apple Silicon first | |
| P13 | Distributed as a `.dmg` on GitHub Releases only | No Homebrew / App Store in v1 |
| P14 | Name: **jev-folder-sort** (same as the repo); license Apache-2.0 | |
| P15 | Out of scope: duplicates, multiple profiles, iCloud folders | Stay lightweight |

## Technical decisions

| # | Decision | Why |
|---|---|---|
| T1 | Engine is **open-jev** (PyTorch), not TypeSafe's hosted Jev | No API access; local-only requirement |
| T2 | We train open-jev ourselves: pretrained tokenizer/embeddings → synthetic base training → on-device personalisation | open-jev ships with random weights and a placeholder hash tokenizer |
| T3 | Native **SwiftUI** menu-bar app + **Python engine child process** over stdin/stdout JSON | Native Mac UX, while using open-jev in PyTorch unchanged; no network port |
| T4 | Low-confidence files **stay in place** and go to the Review list | Consistent with P4 (no app-created "Review" folder); never move when unsure |
| T5 | Rules run before the model | Free, instant, fully predictable |
| T6 | Non-sandboxed, Developer ID signed + notarized | Needed for folder access + child process; required for a smooth DMG install |
| T7 | Bundle relocatable Python + PyTorch in the app | Users shouldn't need Python; size cost accepted for v1, Core ML later |
| T8 | App state in SQLite (GRDB) in Application Support | One small, durable, local store for history, undo and training examples |
| T9 | Vendor open-jev under `engine/third_party/` with NOTICE | We need to modify it (tokenizer, checkpoints); Apache-2.0 allows this with attribution |

## Open questions

- **Apple Developer account** ($99/yr) is needed to sign and notarize the DMG. Without one, users have to right-click → Open past Gatekeeper warnings.
- **Base training data**: exact recipe for the synthetic corpus, and whether to use a local LLM once at dev time to help generate realistic text snippets.
- **Backbone choice** for pretrained embeddings (which small encoder, license-compatible with Apache-2.0).
