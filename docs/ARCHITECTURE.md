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
                       │  jevsort-engine (Python + PyTorch) · open-jev · classify         │
                       └──────────────────────────────────────────────────────────────────┘
```

- **The Swift app** owns everything about the Mac: UI, scheduling, file-system access, metadata and text extraction, rules, moving files, history.
- **The Python engine** owns only the model. It receives file "states" and opaque folder ids, and returns a folder id. It never receives a path and can't write anywhere but its model and temp directories.

This split lets us use open-jev in PyTorch (a hard requirement) while keeping the app fully native.

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
- Other ops: `health` (returns protocol version, model version, `model` or `stub`, device), `load_model`, `shutdown`.
- Errors come back as `{"ok": false, "error": "..."}` and never crash the loop.
- Protocol version: 1. `EngineClient` refuses an engine that reports a different one.

Engine sandbox profile (in `EngineClient.swift`): `(deny network*)` except unix sockets, and `(deny file-write*)` except the model directory, the system temp directories and `/dev/null`. Verified: inside the sandbox, the engine can't reach the network or write to `~/Desktop`.

## 5. Data storage

All under `~/Library/Application Support/jev-folder-sort/`:

| Store | Contents |
|---|---|
| `app.sqlite` (GRDB) | `setting`, `source_folder`, `dest_folder`, `rule`, `snapshot`, `run`, `move_history`, `pending_review` |
| `models/` (M6+) | The user's fine-tuned checkpoint |

During development the engine runs from the repo's `engine/` folder, with its checkpoint in `engine/checkpoints/base/`. Training examples (M6) store the extracted state and the chosen folder, not the file itself.

## 6. macOS specifics

- **Not sandboxed.** A sandboxed app can't comfortably watch arbitrary folders and run a Python child process, and the App Store is out of scope. The app is ad-hoc signed for development, and will be Developer ID signed and notarized for release (M8).
- **Permissions:** macOS asks once for Desktop, Downloads or Documents access (the `NS…FolderUsageDescription` strings in Info.plist). No Full Disk Access is needed.
- **Menu-bar only** (`LSUIElement`), with SwiftUI `MenuBarExtra`, a `Settings` scene and an `Activity` window.
- **Launch at login** uses `SMAppService.mainApp`, which only works when running from the `.app` bundle.

## 7. Packaging the engine (M8)

The release `.dmg` must run on a Mac with no Python installed. The plan:
- Bundle a relocatable CPython (python-build-standalone), the arm64 PyTorch wheel and the engine package inside `JevFolderSort.app/Contents/Resources/engine/`, trimmed and code-signed.
- Ship the base checkpoint as a release asset (58 MB in fp16).

Core ML export, which would drop PyTorch from the install, is on the roadmap.

## 8. Repository layout

```
jev-folder-sort/
├── app/                                  # SwiftPM package (builds with Command Line Tools only)
│   ├── Package.swift
│   ├── Sources/JevFolderSortCore/
│   │   ├── Scope/       Scope.swift (config, policy, issues) · ScopeGuard.swift · FolderImport.swift
│   │   ├── Pipeline/    Scanner · Extractor · Rules · Pipeline · Scheduler
│   │   ├── Engine/      EngineClient.swift (process, sandbox, protocol)
│   │   └── Store/       AppDatabase.swift (GRDB schema + queries)
│   ├── Sources/JevFolderSort/            # SwiftUI: AppModel, PopoverView, SettingsView, ActivityView
│   └── Tests/JevFolderSortCoreTests/     # Swift Testing
├── engine/                               # uv project, Python 3.12
│   ├── jevsort_engine/  tokenizer · state · model · baseline · server · train · eval
│   ├── datasets/        ontology.py · generate.py · eval/messy.py (hand-written held-out set)
│   ├── third_party/open_jev/             # vendored, unmodified (Apache-2.0)
│   └── tests/
├── scripts/             build_app.sh · test.sh
├── docs/
├── LICENSE · NOTICE
```

## 9. Development

```bash
cd engine && uv sync && uv run pytest               # engine + tests
uv run python -m jevsort_engine.train               # train the base checkpoint (~45 min on CPU)
uv run python -m jevsort_engine.eval --model checkpoints/base
scripts/test.sh                                     # Swift tests (works without Xcode)
scripts/build_app.sh && open build/JevFolderSort.app
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
- **Integration:** the real Python engine in `--stub` mode runs through `EngineClient` inside the sandbox, doing an end-to-end sort on a temp tree.
