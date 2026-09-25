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
| T9 | Vendor open-jev **unmodified** under `engine/third_party/` with NOTICE | `Jev(cfg, tokenizer=...)` already accepts a custom tokenizer, so everything else (tokenizer, embeddings, checkpoints) wraps it from outside |
| T10 | **Scope is hard-enforced by `ScopeGuard`**, the only code that moves files; a test fails the build if anything else renames/moves/deletes | The user must be able to trust that nothing outside the scope is ever touched, whatever the model says |
| T11 | Scope = watched folders + **one destination root** (user-chosen, no default) + checklist of existing sub-folders | Simple to explain on one screen; a single root makes "never outside it" easy to verify |
| T12 | Protected locations are hard-coded (system dirs, `~/Library` incl. iCloud/CloudStorage, `~/.Trash`, the app); scope folders must be inside home or on an external volume, never the whole home/volume | Stops a mis-click from pointing the app at something dangerous |
| T13 | The engine sees **opaque folder ids**, never paths, and returns an id or `__none__`; unknown ids are refused | Removes any way for model output to name an arbitrary location |
| T14 | Engine runs under **`sandbox-exec`**: no network, no writes outside its model/temp dirs | "Local only" is enforced by the OS, not just by promise; verified MPS/CPU still work inside it |
| T15 | Moves use `renamex_np(RENAME_EXCL)`: atomic, same volume only, never overwrite; Finder-style `name 2.ext` on collision | No data loss even under races; cross-volume copy+delete is deferred |
| T16 | Reserved **"none of these folders fit"** option in every Choice | Files that don't belong anywhere stay put instead of being forced into the nearest folder |
| T17 | Tokenizer + word embeddings from **all-MiniLM-L6-v2** (Apache-2.0); one shared table, **frozen** | Language knowledge from day one; 23M fewer trainable params made training ~8x faster on an 8 GB Mac |
| T18 | Inference and training default to **CPU**, not MPS | At ~30M params CPU is faster (MPS launch overhead, ~1 s warm-up) |
| T19 | Engine: **uv + Python 3.12**; app: **SwiftPM** (no Xcode project) | System Python is 3.14 (torch wheels lag); only the Command Line Tools are installed — `scripts/test.sh` wires up Swift Testing without Xcode |
| T20 | Held-out eval is **hand-written** and never used for model selection | Keeps reported accuracy honest about transfer to real files |

## Open questions

- **Apple Developer account** ($99/yr) is needed to sign and notarize the DMG. Without one, users have to right-click → Open past Gatekeeper warnings.
- **Next data iteration** (see MODEL.md results): generic "Documents"/"Media"-style folders, training that forces use of folder descriptions, and more "none" cases for opaque binaries.
- **Cross-volume moves** (e.g. Downloads → external drive): refused in v1; needs a safe copy-verify-delete path.
- ~~Base training data recipe~~ → template ontology + random trees (MODEL.md §5). ~~Backbone~~ → MiniLM-L6 vocabulary/embeddings.
