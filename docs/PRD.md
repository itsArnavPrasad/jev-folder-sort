# Product Requirements — jev-folder-sort v1

## 1. Summary

jev-folder-sort is a native macOS menu-bar app that keeps folders like Desktop and Downloads tidy. You define a folder structure (the "destination tree"); every few minutes the app checks the folders it watches, and moves any new or changed files into the right place in that tree.

Every decision is made **on-device** by a small System One decision model built on [open-jev](https://github.com/kyegomez/open-jev), an open-source PyTorch reconstruction of TypeSafe AI's Jev. No file content, filename or metadata ever leaves the Mac.

## 2. Who it is for

- **Primary:** general Mac users with messy Desktop/Downloads folders. No terminal knowledge required.
- **Bar for quality:** the author must actually want to use it daily. If a feature doesn't earn its place, it doesn't ship.
- **Secondary:** developers who want to read, fork or improve a real, local System One model application.

## 3. Principles

1. **Local only.** No network calls for classification. No telemetry.
2. **Never lose a file.** Every move is logged and can be undone. When in doubt, don't move.
3. **Only the user's folders.** The app moves files into folders the user defined — it never invents new ones (v1).
4. **Lightweight.** Do what's necessary, nothing more. No bloat.
5. **Fast and cheap.** Sorting a batch of files should take seconds on Apple Silicon, with negligible battery impact.

## 4. Scope & safety (hard limits)

The user defines exactly what the app may touch, on one **Scope** settings pane, and the app enforces it in code, not just in the UI.

| Part of the scope | What it means |
|---|---|
| **Watched folders** | The only places files are ever *taken from*. Only regular files sitting directly inside them count; sub-folders, hidden files, aliases, symlinks and in-progress downloads are never touched. |
| **Destination root** | One folder, chosen by the user (no default). Every destination must be strictly inside it. |
| **Allowed destination folders** | Existing sub-folders of the root, imported from disk (up to 4 levels deep), each with a checkbox. Only checked folders can receive files. |

At the top of the pane is a plain-English summary ("jev-folder-sort only takes files sitting directly inside … It only moves them into these N folders inside …"), plus a list of any problems. **While any problem exists, nothing is moved.**

Hard rules, enforced by `ScopeGuard` (the only code in the app that can move a file):
- Protected locations can never be a watched folder, the root or a destination: system folders (`/System`, `/Library`, `/Applications`, `/usr`, `/private`, …), `~/Library` (which covers iCloud Drive and CloudStorage folders like Dropbox and Google Drive), `~/.Trash`, and the app itself. The whole home folder is too broad to be a root, and so is a whole external volume.
- Folders are never created, renamed or deleted. If an allowed folder disappears, or is replaced by a symlink, moves into it are refused.
- A watched folder can't also be a destination.
- Moves stay on the same volume and are atomic. An existing file is never overwritten; a clashing name gets a Finder-style suffix (`report 2.pdf`).
- The model never sees or returns paths. It gets opaque folder ids (`f1`, `f2`, …) and answers with one of them, or "none of these". An id that isn't an allowed folder is refused.
- The model runs in a macOS sandbox with no network access and no write access to user files.
- Every refusal is logged in Activity with its reason.

## 5. v1 scope

### 5.1 Watched folders
- The user picks one or more **source folders** to watch in the UI.
- Default suggestions: `~/Desktop` and `~/Downloads`.
- Only top-level items in a watched folder are sorted (the app does not dig into sub-folders of a source folder).

### 5.2 When sorting happens
- **Interval scan:** every 5, 10 or 15 minutes (configurable in Settings; default 10).
- Each scan diffs the folder against the previous snapshot. **Only new or changed files** are sent to the sorter; if nothing changed, nothing runs.
- **Sort now** button in the menu bar for an on-demand run.
- Files that are still being written (e.g. `.crdownload`, `.part`, `.download`, or whose size is still changing) are skipped until the next scan.

### 5.3 Destination structure
The user defines the tree of destination folders in the UI, in either of two ways:
- **Build it** in a folder-tree editor (add / rename / nest / delete folders).
- **Import it** by pointing at an existing folder on disk; the app reads its sub-folder hierarchy.

Each folder in the tree has:
| Field | Purpose |
|---|---|
| Name + path | Where files end up |
| Description (optional, recommended) | Plain-English hint for the model, e.g. "bank statements, invoices, tax documents" |
| Rules (optional) | Deterministic rules that override the model (see 5.4) |

Every allowed folder in the tree is a valid destination (not only leaves). See [§4](#4-scope--safety-hard-limits) for exactly what the app may touch.

### 5.4 Rules
Folders can carry rules. A rule that matches sends the file straight to that folder without asking the model.
- Match on: file extension, filename pattern (glob), source URL/domain (from macOS "Where from" metadata), content type (UTI).
- Rules are evaluated before the model. If multiple rules match, the most specific (deepest) folder wins; ties go to rule order.

### 5.5 What the model sees
For each file the app builds a small, structured "state":
- Filename and extension
- macOS metadata: content type/kind, size, created/modified dates, "Where from" URLs, author/title where available
- The **first N KB of extracted text** (N configurable in Settings; default 4 KB) for text-bearing files: plain text, Markdown, code, PDF, RTF, DOC/DOCX, Pages exported text where available
- Images, video, audio and archives: filename + metadata only in v1

### 5.6 Decisions and confidence
- The model returns a destination folder **and a confidence**.
- **Confidence ≥ threshold** (configurable, default 0.75): file is moved automatically.
- The model can also answer **"none of these folders fit"**. That file is left where it is too.
- **Below threshold:** the file is **left where it is** and listed in the app's **Review** list with the model's top suggestions. The user can accept a suggestion, pick another folder, or ignore the file.
- Ignored files are not re-asked on every scan unless they change.

### 5.7 Moving files
- Moves only. No renaming, no copying, no deleting.
- **Name collision** at the destination: append a numeric suffix the way Finder does (`report 2.pdf`). This is the only case the filename changes.
- Every move is written to a local history log (source path, destination path, time, reason: rule or model + confidence).

### 5.8 Learning from corrections
The model adapts to the user, locally:
- **Existing files** already inside the destination tree are used as initial examples ("bootstrap").
- **Explicit corrections:** undoing a move and re-filing it, or choosing a folder in the Review list.
- **Implicit corrections:** if a file the app moved is found in a different destination folder on a later scan, that's treated as a correction.
- Corrections are applied by periodic on-device fine-tuning (details in [MODEL.md](MODEL.md)).

### 5.9 UI screens
| Screen | Contents |
|---|---|
| **Menu bar popover** | Status (idle / scanning / sorting), last run, files sorted today, Review count, *Sort now*, *Pause*, open main window |
| **Activity / History** | Chronological list of moves with reason and confidence; undo a single move or an entire run |
| **Review** | Files below the confidence threshold with top-3 suggestions; accept / choose / ignore |
| **Structure** | Folder-tree editor, import from disk, per-folder description and rules |
| **Stats** | Files sorted (total, this week), per-folder counts, auto vs. review ratio, average decision time, corrections count |
| **Settings** | Watched folders, scan interval, confidence threshold, text read limit (N KB), "ask before moving" (preview mode), launch at login, model status (version, last trained, *Retrain now*) |

### 5.10 Platform and distribution
- macOS 14 Sonoma or later, **Apple Silicon first** (Intel best-effort, not tested for v1).
- Distributed as a signed, notarized **`.dmg` on GitHub Releases**. No Homebrew or Mac App Store in v1.
- Open source under **Apache-2.0** (same as open-jev).

## 6. Out of scope for v1

Explicitly not in v1 (see [ROADMAP.md](ROADMAP.md) for which are planned later):
- Creating new folders that aren't in the user's structure
- Renaming files
- Duplicate detection / handling
- Multiple profiles
- iCloud Drive folders and other cloud-synced locations
- OCR of images/screenshots, audio/video understanding
- Recursing into sub-folders of watched folders
- Homebrew, Mac App Store
- Any cloud / hosted model, including TypeSafe's hosted Jev API

## 7. Success criteria

- The author runs it on their own Desktop + Downloads for two weeks and keeps it on.
- ≥ 85% of files are auto-sorted correctly after bootstrap on the author's own tree; wrong auto-moves < 5%.
- A scan with no changes costs < 50 ms of CPU; sorting 100 files takes < 10 s on an M1.
- Idle memory for the app + engine < 300 MB; DMG size target < 400 MB.
- Zero files lost; every move undoable.
