# jev-folder-sort

A native macOS menu-bar app that automatically sorts your Desktop, Downloads (or any folder) into a folder structure you define, using a small **System One decision model** that runs entirely on your Mac.

Built on [open-jev](https://github.com/kyegomez/open-jev), an open-source PyTorch reconstruction of TypeSafe AI's [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev). No cloud, no API keys: your files never leave your machine.

> Status: planning. See [docs/](docs/README.md).

- Define your folder tree (or import an existing one), with optional descriptions and rules
- Every 5–15 minutes, new files are sorted into the right folder
- Unsure? The file stays put and shows up in a Review list
- Every move can be undone; the model learns from your corrections

License: Apache-2.0
