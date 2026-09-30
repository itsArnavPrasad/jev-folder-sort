# Architecture

## 1. Overview

Two processes, both local:

```
┌──────────────────────── JevFolderSort.app (Swift / SwiftUI) ─────────────────────────┐
│                                                                                       │
│  Menu bar + windows ── Scheduler ── Scanner ── Extractor ── Rules ──┐                 │
│         ▲                                                           │ unmatched files │
│         │                                                           ▼                 │
│   Activity / Review ◄── ScopeGuard ◄── Confidence gate ◄──── EngineClient             │
│         │               (only mover)                                │  JSON lines     │
│   SQLite (app state)                                                │  stdin/stdout   │
└─────────────────────────────────────────────────────────────────────┼─────────────────┘
                                                                      ▼
                       ┌──── sandbox-exec: no network, no writes to user files ───────────┐
                       │  jevsort-engine (Python + PyTorch) · MiniLM + decision head      │
                       └──────────────────────────────────────────────────────────────────┘
```

- **The Swift app** owns everything about the Mac: UI, scheduling, file-system access, metadata and text extraction, rules, moving files, history.
- **The Python engine** owns only the model. It receives file "states" and opaque folder ids, and returns a folder id. It never receives a path and can't write anywhere but its model and temp directories.

This split keeps the model in PyTorch (where it is trained and personalised) while the app stays fully native.

## 2. Scope enforcement

What the app may touch is defined by the user on the Scope pane ([PRD §4](PRD.md#4-scope--safety-hard-limits)) and enforced in `app/Sources/JevFolderSortCore/Scope/`:

- **`ScopeConfig`**: watched folders, one destination root, and destination folders (id, path relative to the root, description, allowed flag). `issues(policy:)` lists everything wrong with a configuration; the pipeline refuses to run while there are any.
- **`ScopePolicy`**: the hard-coded protected locations (`/System`, `/Library`, `/Applications`, `/usr`, `/private`, `~/Library`, `~/.Trash`, the app bundle, …). It also requires every scope folder to be strictly inside the home folder or strictly inside a volume under `/Volumes`.
- **`ScopeGuard`**: **the only code in the app that moves files.** `move(sourcePath:folderID:)` re-checks everything immediately before moving:
  - the scope is still valid;
  - the id is an allowed folder;
  - the source is a regular, visible, non-alias file whose canonical parent is a watched folder;
  - the destination still exists, isn't a symlink or package, and is strictly inside the root;
  - source and destination are on the same volume;
  - the file's device and inode haven't changed.

  It then moves the file with `renamex_np(…, RENAME_EXCL)`, which is atomic and never overwrites. A clash retries with `name 2.ext`, `name 3.ext`, and so on.
- **`ScopeGuard.undo(entry)`** is the only way back. It works only if the *same file* (same inode) is still where the app put it, that place is inside the root, and the file's original folder is still watched. It never overwrites. The restored file goes onto the Review list and into the snapshot, so it isn't re-sorted straight away.
- **`FolderEditor`** covers the one user-initiated exception: *New folder* in the Structure editor. It `mkdir`s a single empty folder directly inside the root, or inside an existing scope folder. The sorter itself never creates folders, and nothing deletes or renames them.
- A test (`noOtherCodeMovesOrDeletesFiles`) fails if any other source file uses `rename`, `moveItem`, `removeItem`, `unlink`, `copyItem` or `trashItem`.

## 3. The file pipeline

`Pipeline.run(trigger:)`, one run step by step:

1. **Scheduler** fires every 5/10/15 min, or on *Sort now*. It skips a run while paused, in Low Power Mode, or while another run is in progress.
2. **Scope check.** If `ScopeConfig.issues` isn't empty, the run stops with an error and nothing is scanned.
3. **Scanner** lists the top level of each watched folder and diffs `(inode, size, mtime)` against the `snapshot` table. It skips hidden files, directories, packages, symlinks and in-progress downloads (`.crdownload`, `.part`, `.download`, …). A 2-second stability re-check defers files that are still being written.
4. **Extractor** builds a `FileState`:
   - Spotlight metadata: kind, content type, "Where from" URLs, title, authors, size.
   - Up to N KB of text: a direct read for text and code, `PDFKit` for PDFs (first 20 pages at most), `NSAttributedString` for RTF/DOC/DOCX.
5. **Rules** (extension, filename glob, source domain, UTI) run for allowed folders only. The deepest matching folder wins.
6. **EngineClient** sends the files that no rule matched in one batch, with the allowed folders as `{id, relative path, description}`.
7. **Confidence gate.** An answer of `__none__`, an unknown id, or a confidence below the threshold → the file stays where it is and goes onto `pending_review`. In preview mode, even confident answers only become suggestions.
8. **ScopeGuard** moves everything else. Each outcome is written to `move_history`: moved, pending, preview, or refused with a reason. Files left in place are added to the snapshot, so they aren't asked about again until they change.

## 3a. Review, undo and learning

- **`Actions`** handles what the user does in the UI:
  - filing a Review item into a chosen allowed folder, through `ScopeGuard`;
  - leaving it where it is;
  - undoing a move or a whole run.

  Filing from Review saves the file's `FileState` and chosen folder as a training example (`review`, or `refile` after an undo).
- **`LearningCollector`** is **read-only** in the destination tree:
  - **Bootstrap:** reads up to 25 newest visible files at the top level of each allowed folder and saves them as `bootstrap` examples.
  - **Implicit corrections:** each run, it checks moves from the last 30 days. If a moved file's inode now sits in a *different* allowed folder, the user re-filed it: that becomes an `implicit` example and the history row is marked `corrected_to`.
- **`Learner`** decides when to train and runs a *separate* sandboxed engine process (`train_user` op), so sorting isn't blocked:
  - It trains automatically once there are ≥ 20 new examples, learning is on, and the Mac is on AC power (`IOPSGetProvidingPowerSourceType`). There's also *Retrain now*.
  - It always fine-tunes from the **base** checkpoint using all examples, which avoids drift from repeated fine-tunes.
  - The engine trains only the read-out and heads, holds out 20% of the examples, and writes `models/user/` atomically, **only if** the new model is at least as good there as the one in use.
  - The main engine then restarts, and serves the user checkpoint when there is one.
  - *Forget personalisation* asks the engine to delete its own `models/user/` (the `reset_user` op).

## 4. Engine protocol

The app starts `sandbox-exec -p <profile> python -m jevsort_engine.server [--model DIR | --stub]` and talks newline-delimited JSON over stdin/stdout. Diagnostics go to stderr.

Request:
```json
{"id": 7, "op": "classify",
 "tree": [{"id": "f1", "path": "Finance", "description": "bank statements, invoices"},
          {"id": "f2", "path": "Finance/Taxes", "description": "tax returns, W-2, 1099"}],
 "files": [{"id": "c0", "state": {"name": "2025_W2_acme.pdf", "ext": "pdf", "kind": "PDF document",
            "where_from": ["https://payroll.acme.com"], "text": "Form W-2 Wage and Tax Statement 2025 ..."}}]}
```

Response:
```json
{"id": 7, "ok": true, "results": [{"file": "c0", "choice": "f2", "confidence": 0.91,
  "top": [{"folder": "f2", "p": 0.91}, {"folder": "f1", "p": 0.06}, {"folder": "__none__", "p": 0.02}],
  "latency_ms": 38.2}]}
```

- `choice` is always one of the given folder ids or the reserved `__none__` ("none of these folders fit"). This follows from the Choice head's structure.
- `confidence` is the top-1 probability.
- Other ops: `health` (returns protocol version, model version, `model` or `stub`, device), `load_model`, `train_user` (base, out, tree, examples → report), `reset_user`, `shutdown`.
- Errors come back as `{"ok": false, "error": "..."}` and never crash the loop.
- Protocol version: 1. `EngineClient` refuses an engine that reports a different one.

Engine sandbox profile (in `EngineClient.swift`): `(deny network*)` except unix sockets, and `(deny file-write*)` except the model directory, the system temp directories and `/dev/null`. Verified: inside the sandbox, the engine can't reach the network or write to `~/Desktop`.

## 5. Data storage

All under `~/Library/Application Support/jev-folder-sort/`, or `$JEVSORT_DATA_DIR` if that's set (tests and headless runs use a folder inside the repo):

| Store | Contents |
|---|---|
| `app.sqlite` (GRDB) | `setting`, `source_folder`, `dest_folder`, `rule`, `snapshot`, `run`, `move_history` (with `dest_inode`, `undone_at`, `corrected_to`, `latency_ms`), `pending_review`, `training_example` |
| `models/user/` | The personalised checkpoint (written only by the sandboxed engine; the sandbox's `MODEL_DIR`) |

During development the engine runs from the repo's `engine/` folder, with its checkpoint in `engine/checkpoints/base/`. Training examples (M6) store the extracted state and the chosen folder, not the file itself.

## 6. macOS specifics

- **Not sandboxed.** A sandboxed app can't comfortably watch arbitrary folders and run a Python child process, and the App Store is out of scope. The app is ad-hoc signed for development, and will be Developer ID signed and notarized for release (M8).
- **Permissions:** macOS asks once for Desktop, Downloads or Documents access (the `NS…FolderUsageDescription` strings in Info.plist). No Full Disk Access is needed.
- **Menu-bar only** (`LSUIElement`), with SwiftUI `MenuBarExtra`, a `Settings` scene and an `Activity` window.
- **Launch at login** uses `SMAppService.mainApp`, which only works when running from the `.app` bundle.

## 7. Packaging (M8)

`scripts/bundle_engine.sh` builds `build/engine/`. It runs without any Python installed on the target Mac:
- `python/`: a relocatable CPython 3.12 (python-build-standalone, fetched by uv).
- `site-packages/`: the exact versions from `engine/uv.lock`, minus training-only packages (`huggingface_hub`, `hf_xet`, `setuptools`). Headers, tests and static libraries are trimmed, local symbols are stripped (−59 MB on `libtorch_cpu`), and each library is re-signed.
- `app/`: `jevsort_engine` and `datasets` (used for replay during personalisation).
- `checkpoints/base/`: the model.
- Everything is precompiled to `.pyc`, because the sandbox forbids writing bytecode at runtime.

`scripts/build_app.sh --release` embeds that at `JevFolderSort.app/Contents/Resources/engine/`. It then signs from the inside out: every `.dylib`/`.so`, the Python and `torch_shm_manager` executables (with `scripts/engine.entitlements`), then the app. Signing is ad-hoc by default, or uses `SIGN_IDENTITY` with the hardened runtime. `EngineLaunch.bundled` finds the bundled engine and sets `PYTHONPATH`, `PYTHONNOUSERSITE` and `PYTHONDONTWRITEBYTECODE`.

`scripts/make_dmg.sh` builds a drag-to-Applications DMG (~340 MB) with first-launch instructions and a SHA-256. `scripts/notarize.sh` signs with a Developer ID, then notarizes and staples. `scripts/release.sh` runs:
1. all the tests;
2. the bundle, app and DMG builds;
3. a **headless end-to-end run of the release app on the demo playground**;
4. writing the artifacts to `build/release/`.

See [RELEASING.md](RELEASING.md).

### Headless mode

`JevFolderSort --headless [--demo DIR] [--stub] [--preview] [--sort] [--undo-last-run] [--train]` runs the real pipeline without UI and prints a JSON summary. It **refuses to run unless `JEVSORT_DATA_DIR` is set**, so scripted runs can't touch the real app data. It's used by `release.sh` and for manual end-to-end checks against `examples/demo`.

## 8. Repository layout

```
jev-folder-sort/
├── app/                                  # SwiftPM package (builds with Command Line Tools only)
│   ├── Sources/JevFolderSortCore/
│   │   ├── Scope/       Scope · ScopeGuard (move + undo) · FolderImport · FolderEditor
│   │   ├── Pipeline/    Scanner · Extractor · Rules · Pipeline · Scheduler · Actions · Learning · Learner
│   │   ├── Engine/      EngineClient (process, sandbox, protocol, EngineLaunch dev/bundled)
│   │   └── Store/       AppDatabase (schema v2, stats)
│   ├── Sources/JevFolderSort/            # SwiftUI: AppModel, MainWindow (Review/Activity/Structure/Stats),
│   │                                     #   SettingsView, PopoverView, OnboardingView, Headless
│   ├── Assets/                           # AppIcon.icns
│   └── Tests/JevFolderSortCoreTests/     # Swift Testing; fixtures in app/.test-fixtures (gitignored)
├── engine/                               # uv project, Python 3.12
│   ├── jevsort_engine/  decision (typed questions, read-out, heads, RLCD) · minilm (encoder + prior) · model · state
│   │                    tokenizer · baseline · server · train · eval · personalize
│   ├── datasets/        ontology · generate · eval/messy.py + eval/plain_english.py (held-out) · eval/dev.py (selection)
│   └── tests/
├── examples/demo/                        # generated by scripts/make_demo.sh (gitignored)
├── scripts/             test · build_app · bundle_engine · make_dmg · notarize · release · make_demo · fetch_model · make_icon
├── .github/workflows/ci.yml
└── docs/
```

## 9. Development

```bash
cd engine && uv sync && uv run pytest               # engine + tests
uv run python -m jevsort_engine.train               # train the base checkpoint (~1 h on CPU), or scripts/fetch_model.sh
uv run python -m jevsort_engine.eval --model checkpoints/base
scripts/test.sh                                     # Swift tests (works without Xcode)
scripts/make_demo.sh                                # demo playground inside the repo
scripts/build_app.sh && open build/JevFolderSort.app
JEVSORT_DATA_DIR=$PWD/.jevsort-data app/.build/debug/JevFolderSort --headless --demo examples/demo --sort
```

## 10. Testing

- **Engine (pytest):**
  - tokenizer and state normalisation;
  - tree validation;
  - the choice is always a given id or `__none__` (checked for both the model and the stub);
  - key-order invariance;
  - checkpoint round-trip;
  - protocol round-trip, including bad requests.
- **ScopeGuard (Swift Testing):**
  - symlink escape through a source or a destination, `..` traversal, nested files;
  - hidden files, symlinked files and directories as sources;
  - unknown, unchecked and path-like folder ids;
  - folder paths that escape the root;
  - a deleted destination, which must not be recreated;
  - a destination that is a file;
  - protected and too-broad roots and sources, and a watched folder that is also a destination;
  - collisions, which must never overwrite;
  - an invalid scope, which must block every move.

  A **randomized test** (8 seeds) throws 80 moves with random ids at 40 files plus decoys. Every file must survive exactly once, no decoy may move, and every moved file must be directly inside an allowed folder. Cross-volume refusal is implemented but not covered by an automated test, since that needs a second volume.
- **Pipeline:** a scripted classifier checks:
  - confident moves, low-confidence and `__none__` files staying put, and a path-like id from the "model" being refused;
  - that the engine sees no absolute paths;
  - that the first N KB of text is sent;
  - that unchanged files aren't asked about again;
  - that rules beat the model, preview mode moves nothing, an invalid scope runs nothing, and in-progress downloads are skipped.
- **Undo/Review/Learning:**
  - undo puts files back and they aren't re-sorted;
  - a double undo is refused;
  - undo of a replaced file is refused, and so is undo into an unwatched folder;
  - undo never overwrites;
  - undoing a run undoes all of its moves;
  - filing from Review goes through the guard and records an example, and can't escape the scope;
  - "leave it" isn't asked again;
  - folder creation stays inside the root and rejects bad names;
  - bootstrap reads allowed folders only and moves nothing;
  - re-filing a sorted file is detected as a correction.
- **Integration (real engine, sandboxed):**
  - an end-to-end sort in stub mode;
  - a 300-file batch round-trips intact;
  - personalisation end to end: bootstrap, fine-tune, the user model written only inside the models dir, and reset.
- **Engine:** personalisation learns a user mapping from random weights, and refuses to run with too few examples.
- **Release:** `release.sh` runs the release app headless on `examples/demo` and asserts it used its bundled engine.
- **CI** (`.github/workflows/ci.yml`, macOS 15) runs the engine tests, the Swift tests and a development build.
