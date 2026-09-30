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
| T1 | ~~Engine is **open-jev**~~ (superseded by T32/T38): a local Jev-style model, not TypeSafe's hosted Jev | No API access; local-only requirement |
| T2 | We train open-jev ourselves: pretrained tokenizer/embeddings → synthetic base training → on-device personalisation | open-jev ships with random weights and a placeholder hash tokenizer |
| T3 | Native **SwiftUI** menu-bar app + **Python engine child process** over stdin/stdout JSON | Native Mac UX, while using open-jev in PyTorch unchanged; no network port |
| T4 | Low-confidence files **stay in place** and go to the Review list | Consistent with P4 (no app-created "Review" folder); never move when unsure |
| T5 | Rules run before the model | Free, instant, fully predictable |
| T6 | Non-sandboxed, Developer ID signed + notarized | Needed for folder access + child process; required for a smooth DMG install |
| T7 | Bundle relocatable Python + PyTorch in the app | Users shouldn't need Python; size cost accepted for v1, Core ML later |
| T8 | App state in SQLite (GRDB) in Application Support | One small, durable, local store for history, undo and training examples |
| T9 | ~~Vendor open-jev unmodified~~ (superseded by T38): vendor open-jev **unmodified** under `engine/third_party/` with NOTICE | `Jev(cfg, tokenizer=...)` already accepts a custom tokenizer, so everything else (tokenizer, embeddings, checkpoints) wraps it from outside |
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
| T21 | Checkpoints selected on a separate hand-written **dev set** (top-1 − ½·ECE); messy eval stays held-out | Synthetic val overfit badly in base-0.1.0 (92% val vs 61% eval) |
| T22 | **Undo goes through `ScopeGuard`** and requires the same inode, a location inside the root, and a still-watched original folder; undone files go to Review | Undo is also a move and gets the same guarantees; it avoids re-sorting a file the user just rejected |
| T23 | The Structure editor may **create** a folder inside the root (user action, `mkdir` only); nothing ever deletes or renames folders | Matches "build the tree in the UI" without giving the sorter the power to create folders |
| T24 | Learning **reads** allowed destination folders (bootstrap, implicit corrections) but never moves inside them | User approved read-only access; moves still only originate from watched folders |
| T25 | Personalisation always fine-tunes **from base with all examples**, trains read-out + heads only, with synthetic replay; it activates only if not worse on a 20% hold-out, in a **separate sandboxed trainer process**, on AC power | No drift or forgetting; a bad fine-tune can't replace a good model; sorting isn't blocked |
| T26 | **All testing inside the repo**: fixtures in `app/.test-fixtures`, the demo in `examples/demo`, `JEVSORT_DATA_DIR`; headless mode refuses to run without it | The user's own files and app data are never touched by tests |
| T27 | Release DMG **bundles everything** (python-build-standalone 3.12, pinned PyTorch, model) → ~340 MB | Works fully offline with nothing installed, consistent with "local only" |
| T28 | **Ad-hoc signing** now, `notarize.sh` for later | No Developer ID yet; README explains the one-time right-click → Open |
| T29 | GitHub: everything prepared and committed locally; **the maintainer pushes and publishes** | Publishing is the owner's action |
| T30 | No co-author trailers in commit messages | Maintainer preference |
| T31 | **Plain-English folder descriptions are the primary way to steer the sorter** | Maintainer's product goal: "explain what the folder should look like, and it sorts like that" |
| T32 | **Replace open-jev's encoders with one shared pretrained MiniLM** (`arch="minilm"`), keeping open-jev's read-out, heads and RLCD; vendored code stays untouched (subclass) | From-scratch encoders capped at ~60% and ignored descriptions (51–53% on the plain-English set); untrained MiniLM matching alone scores 79% there. See MODEL_HISTORY.md |
| T33 | Own ~100-line BERT implementation instead of the `transformers` library | No big new dependency in the bundle; verified identical to sentence-transformers |
| T34 | Choice logits = open-jev learned score (zero-init) + **learned-scale cosine prior** between file and `path: description` | Descriptions work from step 0 and can't be "trained away"; training learns corrections |
| T35 | Skip external datasets and teacher distillation for now | Maintainer choice: focus on description-following; revisit if needed (research notes in MODEL.md) |
| T36 | "Learn from my folders" = read-only bootstrap of up to 100 files/folder, per-folder hold-out, suggested threshold at ≥95% held-out precision (needs ≥10 held-out files) | Fast, safe onboarding for someone whose folders are already organised |
| T37 | A generative SLM is a future **System Two fallback** for low-confidence files, not a replacement | 10–100× slower/larger, weaker calibration, output must be constrained; the System One path stays default |
| T38 | **Remove open-jev entirely**: fold the ~300 lines we still used (typed questions, state flattening, read-out, heads, RLCD) into our own `decision.py` with attribution; delete the vendored package; drop the from-scratch v0.1/v0.2 architecture | Maintainer request; our model only used those pieces. Same parameter names, so minilm-0.3.0 loads and scores identically |
| T39 | **Evaluated Laya; not adopted** as the engine or bundled | Zero-shot on our held-out sets it scored 31–51% vs our 77–85%, at 150–580 ms/file vs 4–7 ms, 843 MB vs ~60 MB, and can't be personalised on-device (GPU fine-tuning). As a second opinion it rescued ~9% of unsure files. See MODEL_HISTORY.md |

## Open questions

- **Apple Developer account** ($99/yr): needed to notarize (`scripts/notarize.sh`, untested until an identity exists). Until then users right-click → Open once.
- **Cross-volume moves** (e.g. Downloads → external drive): refused in v1; needs a safe copy-verify-delete path.
- ~~Base training data recipe~~ → template ontology + random trees (MODEL.md §5). ~~Backbone~~ → MiniLM-L6 vocabulary/embeddings.
