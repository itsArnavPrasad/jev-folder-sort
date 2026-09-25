# Architecture

## 1. Overview

Two processes, both local:

```
┌──────────────────────── JevFolderSort.app (Swift / SwiftUI) ─────────────────────────┐
│                                                                                       │
│  Menu bar + windows ── Scheduler ── Scanner ── Extractor ── Rules ──┐                 │
│         ▲                                                           │ unmatched files │
│         │                                                           ▼                 │
│   History / Review ◄── Mover ◄── Decision gate ◄──────── EngineClient                 │
│         │                                                           │  JSON lines     │
│   SQLite (app state)                                                │  stdin/stdout   │
└─────────────────────────────────────────────────────────────────────┼─────────────────┘
                                                                      ▼
                                   ┌──────────── jevsort-engine (Python + PyTorch/MPS) ───┐
                                   │  open-jev model  ·  classify  ·  fine-tune  ·  eval  │
                                   └──────────────────────────────────────────────────────┘
```

- **The Swift app** owns everything about the Mac: UI, scheduling, file-system access, metadata and text extraction, rules, moving files, history and undo.
- **The Python engine** owns only the model: it takes file "states" and returns decisions, and it fine-tunes on corrections. It never touches the file system beyond its own model directory.

This split lets us use open-jev as-is in PyTorch (a hard requirement) while keeping the app fully native.

## 2. The file pipeline

One scan, step by step:

1. **Scheduler** fires every 5/10/15 min (or *Sort now*). Paused on low battery / Low Power Mode.
2. **Scanner** lists the top level of each watched folder and compares against the last snapshot (`path, inode, size, mtime`). Output: new or changed files. Skips hidden files, `.DS_Store`, aliases, folders, packages, in-progress downloads, and files whose size changed since the last check.
3. **Extractor** builds a state per file:
   - Metadata via Spotlight (`MDItem`): `kMDItemContentType`, `kMDItemKind`, `kMDItemWhereFroms`, `kMDItemAuthors`, `kMDItemTitle`, dates, size.
   - Text (first N KB): direct read for text/code; `PDFKit` for PDF; `NSAttributedString` for RTF/DOC/DOCX. Cut at N KB.
4. **Rules** run in Swift. A match produces a decision with `reason = rule`, confidence 1.0.
5. **EngineClient** sends all unmatched files in one batch to the engine.
6. **Decision gate** compares each confidence with the threshold → *move* or *Review*.
7. **Mover** moves the file with `FileManager.moveItem`, resolves name collisions (`name 2.ext`), and writes a history record. In preview mode, moves wait for user approval.

## 3. Engine protocol

The app starts the engine as a child process and talks over **newline-delimited JSON on stdin/stdout**. No network socket, so nothing can reach the engine from outside the app.

Request:
```json
{"id": "r42", "op": "classify",
 "tree": [{"id": "f1", "path": "Finance", "description": "bank statements, invoices"},
          {"id": "f2", "path": "Finance/Taxes", "description": "tax returns, W-2, 1099"}],
 "files": [{"id": "a1", "state": {"name": "2025_W2_acme.pdf", "ext": "pdf",
            "kind": "PDF document", "where_from": ["https://payroll.acme.com"],
            "text": "Form W-2 Wage and Tax Statement 2025 ..."}}]}
```

Response:
```json
{"id": "r42", "results": [{"file": "a1", "choice": "f2", "confidence": 0.91,
  "probabilities": {"f2": 0.88, "f1": 0.10, "...": 0.02}, "latency_ms": 38}]}
```

Other ops: `health`, `load_model`, `train` (with examples), `eval`, `shutdown`. Protocol version is sent in `health` so the app and engine can reject mismatches.

## 4. Data storage

All under `~/Library/Application Support/jev-folder-sort/`:

| Store | Contents |
|---|---|
| `app.sqlite` | Settings, watched folders, destination tree, rules, scan snapshots, move history, review queue, stats, training examples |
| `models/base/` | Shipped base checkpoint (read-only) |
| `models/user/` | User's fine-tuned checkpoint + metadata (version, trained-at, eval score) |
| `logs/` | Rotating app + engine logs (no file contents logged) |

Training examples store the extracted state + chosen folder, not the file itself.

## 5. macOS specifics

- **Not sandboxed.** A sandboxed app can't comfortably watch arbitrary folders and run a Python child process; the App Store is out of scope anyway. The app is signed with a Developer ID and notarized.
- **Permissions:** macOS asks the user once for Desktop / Downloads / Documents access (TCC prompts). No Full Disk Access needed.
- **Launch at login** via `SMAppService`.
- **Menu-bar only** (`LSUIElement`); the main window opens from the popover.
- Scans run on a background queue with utility QoS to protect battery.

## 6. Packaging the engine

The `.dmg` has to run on a Mac with no Python installed:

- A relocatable CPython (python-build-standalone) + PyTorch (arm64 wheel, CPU + MPS) + the engine package, placed in `JevFolderSort.app/Contents/Resources/engine/`.
- Trim unused parts of PyTorch (tests, headers, CUDA-free build) to keep the bundle small.
- Every binary inside is code-signed for notarization.
- Base model weights ship inside the app (tens of MB).

Expected size: a few hundred MB, most of it PyTorch. That's the cost of using open-jev directly. A later version can export inference to Core ML to drop PyTorch from the default install (see [ROADMAP.md](ROADMAP.md)).

## 7. Repository layout

```
jev-folder-sort/
├── app/                    # Xcode project (SwiftUI menu-bar app)
│   ├── JevFolderSort/
│   │   ├── UI/             # MenuBar, History, Review, Structure, Stats, Settings
│   │   ├── Core/           # Scheduler, Scanner, Extractor, Rules, Mover
│   │   ├── Engine/         # EngineClient, protocol types, process lifecycle
│   │   └── Store/          # SQLite (GRDB) models + migrations
│   └── JevFolderSortTests/
├── engine/                 # Python package: jevsort_engine
│   ├── jevsort_engine/
│   │   ├── server.py       # stdin/stdout JSON loop
│   │   ├── model.py        # wraps open-jev for file classification
│   │   ├── tokenizer.py    # pretrained tokenizer replacing HashTokenizer
│   │   ├── train.py        # base training + on-device fine-tune
│   │   └── eval.py
│   ├── third_party/open_jev/   # vendored open-jev (Apache-2.0, with NOTICE)
│   ├── datasets/           # scripts to build the base training set
│   └── tests/
├── scripts/                # build engine bundle, build + notarize DMG
├── docs/
├── LICENSE                 # Apache-2.0
└── NOTICE                  # attribution to open-jev
```

## 8. Testing

- **Swift:** unit tests for the scanner diff, rules matching, collision naming, undo, and extraction on fixture files. An integration test runs a full scan on a temporary directory against a stub engine.
- **Engine:** protocol round-trip tests, deterministic inference tests, and an accuracy eval on a held-out "messy folder" fixture set.
- **Safety test:** random scans + undos over a fixture tree must always leave every file present exactly once.
