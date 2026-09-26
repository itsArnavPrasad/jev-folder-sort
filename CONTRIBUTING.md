# Contributing

Thanks for helping! A few ground rules keep this project safe to run on people's files.

## Setup

```bash
cd engine && uv sync          # Python 3.12 + PyTorch
uv run pytest -q
cd .. && scripts/test.sh      # Swift tests (works with or without Xcode)
scripts/make_demo.sh          # a messy demo folder inside the repo
scripts/build_app.sh && open build/JevFolderSort.app
```

**Test only on `examples/demo` or temp folders, never on real Desktop or Downloads.** Headless runs refuse to start without `JEVSORT_DATA_DIR`, so they can't touch the real app data:

```bash
JEVSORT_DATA_DIR=$PWD/.jevsort-data app/.build/debug/JevFolderSort --headless --demo examples/demo --sort
```

## Rules for changes

- **Only `ScopeGuard` may move files.** `noOtherCodeMovesOrDeletesFiles` fails if other app code calls `rename`, `moveItem`, `removeItem`, `unlink`, `copyItem` or `trashItem`.
- **The engine must never receive paths.** Send `FileState` and opaque folder ids.
- **Scope changes need tests.** New refusal cases go in `ScopeGuardTests`.
- **Model claims need numbers.** Report `uv run python -m jevsort_engine.eval`. Never select checkpoints on `datasets/eval/messy.py`.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
