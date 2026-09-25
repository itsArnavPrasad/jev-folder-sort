# jev-folder-sort

A native macOS menu-bar app that automatically sorts your Desktop, Downloads (or any folder) into a folder structure you define, using a small **System One decision model** that runs entirely on your Mac.

Built on [open-jev](https://github.com/kyegomez/open-jev), an open-source PyTorch reconstruction of TypeSafe AI's [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev). No cloud, no API keys: your files never leave your machine.

> **Status:** early development (milestones M0–M3 of [the roadmap](docs/ROADMAP.md)). Not packaged for end users yet.

- **You define the scope.** Pick the folders to watch, one destination root, and tick which of its sub-folders may receive files. The app can't move anything outside that, and this is enforced in code and covered by tests.
- Every 5–15 minutes, new files are sorted into the right folder by rules you set, or by the local model.
- Unsure, or nothing fits? The file stays where it is and goes on a review list.
- The model runs in a macOS sandbox with no network access. It sees file names, metadata and the first few KB of text, and answers with one of your folders or "none of these".

## Try it (developers)

Requires macOS 14+, Apple Silicon, [uv](https://docs.astral.sh/uv/), and the Xcode Command Line Tools.

```bash
cd engine
uv sync                                   # Python 3.12 + PyTorch
uv run python -m jevsort_engine.train     # train the base model (~45 min on CPU), or skip to use the keyword stub
cd ..
scripts/test.sh                           # Swift tests
scripts/build_app.sh && open build/JevFolderSort.app
```

Then open **Settings → Scope**, add a watched folder, choose a destination root, and tick the folders you want files moved into. Try it on a test folder first, or turn on **Preview mode** in General.

## Docs

[Product requirements](docs/PRD.md) · [Architecture](docs/ARCHITECTURE.md) · [Model](docs/MODEL.md) · [Roadmap](docs/ROADMAP.md) · [Decisions](docs/DECISIONS.md)

## License

Apache-2.0. open-jev is vendored under the same license (see [NOTICE](NOTICE)). Not affiliated with TypeSafe AI.
