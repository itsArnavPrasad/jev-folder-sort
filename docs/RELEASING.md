# Releasing

## 1. Build everything

```bash
cd engine && uv sync && cd ..
# a trained model must be at engine/checkpoints/base (train it, or scripts/fetch_model.sh)
scripts/release.sh
```

`release.sh` does the following:
- Runs the engine and Swift test suites.
- Bundles the engine: a standalone Python, PyTorch and the model.
- Builds the release app and the DMG.
- Runs the **release app headless on the demo playground**, checking that it used its own bundled engine.
- Writes the artifacts to `build/release/`:

| File | What |
|---|---|
| `jev-folder-sort-<v>-arm64.dmg` | The app (~340 MB, fully offline) |
| `jev-folder-sort-<v>-arm64.dmg.sha256` | Checksum |
| `jevsort-model-base.zip` | Base model, for building from source |
| `RELEASE_NOTES.md` | Paste into the GitHub release |

## 2. Check it by hand

1. Mount the DMG, drag the app to `/Applications`, then right-click → Open.
2. Point the scope at `examples/demo` (`scripts/make_demo.sh`) and never at your real folders while testing.
3. Sort now → Review → Undo → Structure (add a rule) → Stats.

## 3. Publish on GitHub

```bash
git tag v$(cat VERSION) && git push origin main --tags
```

On github.com, go to **Releases → Draft a new release** and pick the tag:
- Paste in `build/release/RELEASE_NOTES.md`.
- Upload the DMG, its `.sha256` file, and `jevsort-model-base.zip`. The zip must keep that exact name, because `scripts/fetch_model.sh` downloads it by name.

## Signing and notarization

Release builds are **ad-hoc signed** by default. Users see Gatekeeper's "can't be checked for malicious software" message once, and open the app with right-click → Open.

To remove that message, you need a paid Apple Developer account ($99/year):

```bash
security find-identity -v -p codesigning        # your "Developer ID Application: …" identity
xcrun notarytool store-credentials jevsort --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/notarize.sh
```

`notarize.sh` then:
1. Signs every binary with the hardened runtime.
2. Builds and signs the DMG.
3. Submits it to Apple's notary service and waits.
4. Staples the ticket.

Untested so far: it needs a real Developer ID.

## Bumping the version

Edit `VERSION`, and add an entry to `CHANGELOG.md`.
