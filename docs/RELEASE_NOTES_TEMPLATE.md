# jev-folder-sort {{VERSION}}

A macOS menu-bar app that sorts your files into your own folder structure, using a small System One decision model ([open-jev](https://github.com/kyegomez/open-jev)) that runs **entirely on your Mac**.

## Install

1. Download `jev-folder-sort-{{VERSION}}-arm64.dmg` (Apple Silicon, macOS 14+).
2. Open it and drag **jev-folder-sort** into **Applications**.
3. **First launch:** this build isn't notarized by Apple, so macOS will warn you. **Right-click the app → Open → Open** (once). Or go to System Settings → Privacy & Security → **Open Anyway**.
4. Click the tray icon in the menu bar, and follow the welcome window to choose:
   - the folders to watch;
   - a destination root;
   - which of its folders may receive files.

   Starting in **preview mode** is recommended.

## What's in it

- **You define the scope; the app can't move anything outside it.** This is enforced in code, and a test fails if anything else in the codebase moves files.
- **Rules first, then the local model.** Unsure files stay where they are and go to **Review**.
- **Undo** any move, or a whole run.
- **Learns from you, on-device:** from files already in your folders, your Review choices, and files you re-file.
- **Private by design:**
  - the model runs in a macOS sandbox with **no network access**;
  - it never sees file paths;
  - it only reads names, metadata and the first few KB of text.

Model: `{{MODEL}}`. See [MODEL.md](https://github.com/itsArnavPrasad/jev-folder-sort/blob/main/docs/MODEL.md) for how it was trained and evaluated.

## Checksums

```
SHA-256  jev-folder-sort-{{VERSION}}-arm64.dmg
{{SHA256}}
```

`jevsort-model-base.zip` is the same base model, for building from source (`scripts/fetch_model.sh`).

Not affiliated with TypeSafe AI.
