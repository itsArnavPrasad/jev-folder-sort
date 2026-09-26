<p align="center"><img src="app/Assets/icon-1024.png" width="128" alt=""></p>

# jev-folder-sort

A native macOS menu-bar app that keeps your Desktop and Downloads (or any folder) tidy. It sorts new files into a folder structure you define, using a small **System One decision model** that runs **entirely on your Mac**.

It's built on [open-jev](https://github.com/kyegomez/open-jev), an open-source PyTorch reconstruction of TypeSafe AI's [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev). There's no cloud and no API key, and your files never leave your machine.

## How it works

1. **You define the scope** on one screen:
   - the folders to watch;
   - one destination root;
   - which of its folders may receive files.

   The app can't touch anything outside that. This is enforced in code, not just the UI, and covered by tests.
2. **Every 5, 10 or 15 minutes**, it looks at new files in the watched folders:
   - your **rules** run first (extension, filename, download site, file type);
   - then the local **model** picks one of your folders, or answers "none of these fit".
3. **Confident** decisions are carried out. **Unsure** files stay where they are and show up in **Review**.
4. **Everything is undoable**, a single move or a whole run.
5. **It learns from you, on-device**, from:
   - files already in your folders;
   - your Review choices;
   - files you move to a different folder after it sorted them.

**Privacy:**
- The model runs in a macOS sandbox with **no network access** and no write access to your files.
- It never sees file paths, only names, metadata and the first few KB of text.
- It answers with the id of one of *your* allowed folders.

## Install

1. Download the latest **`jev-folder-sort-<version>-arm64.dmg`** from [Releases](https://github.com/itsArnavPrasad/jev-folder-sort/releases). It needs Apple Silicon and macOS 14 or later.
2. Drag **jev-folder-sort** into **Applications**.
3. **First launch:** the app isn't notarized by Apple yet, so right-click it and choose **Open → Open**. You only do this once.
4. Click the tray icon in the menu bar and follow the welcome window. Starting in **Preview mode** is a good idea: it suggests moves without making any.

The DMG is about 340 MB because it bundles Python, PyTorch and the model, so nothing else needs to be installed.

## Build from source

You need macOS 14+ on Apple Silicon, [uv](https://docs.astral.sh/uv/), and the Xcode Command Line Tools. Full Xcode is optional.

```bash
git clone https://github.com/itsArnavPrasad/jev-folder-sort && cd jev-folder-sort
cd engine && uv sync && cd ..
scripts/fetch_model.sh                    # or train it: cd engine && uv run python -m jevsort_engine.train
scripts/test.sh                           # Swift tests
scripts/make_demo.sh                      # messy demo folder inside the repo: examples/demo
scripts/build_app.sh && open build/JevFolderSort.app
```

Point the scope at `examples/demo/Inbox` (watch) and `examples/demo/Sorted` (root) to try it safely. For the self-contained DMG, see [docs/RELEASING.md](docs/RELEASING.md).

## How good is the model?

It's small (30M parameters, a few milliseconds per file) and was trained on synthetic data. Accuracy and calibration are reported honestly on a hand-written held-out set in [docs/MODEL.md](docs/MODEL.md).

The default confidence threshold is conservative, so unsure files wait in Review rather than being moved wrongly. Personalisation on your own folders improves it further.

## Docs

- [Product requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Model](docs/MODEL.md)
- [Roadmap](docs/ROADMAP.md)
- [Decisions](docs/DECISIONS.md)
- [Releasing](docs/RELEASING.md)
- [Contributing](CONTRIBUTING.md)

## License

Apache-2.0. open-jev is vendored under the same license (see [NOTICE](NOTICE)). Not affiliated with TypeSafe AI.
