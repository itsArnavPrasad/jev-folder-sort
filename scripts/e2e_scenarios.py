#!/usr/bin/env python3
"""End-to-end scenario benchmark: build each scenario in the repo, run the real app
headless on it, and score every file.

    scripts/e2e_scenarios.py [--app PATH] [--threshold 0.9] [--only student,developer] [--learn]

Everything happens under examples/scenarios-out/ (gitignored). Real files are
made with cupsfilter (PDF), textutil (DOCX) and sips (images), so text
extraction is exercised exactly as on a real Mac.
"""
from __future__ import annotations

import argparse, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "examples"))
from scenarios import SCENARIOS  # noqa: E402

OUT = REPO / "examples" / "scenarios-out"
ICON = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"


def make_file(path: Path, kind: str, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if kind in ("pdf", "docx"):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as t:
            t.write(text + "\n")
        if kind == "pdf":
            with open(path, "wb") as f:
                subprocess.run(["cupsfilter", "-i", "text/plain", t.name], stdout=f, stderr=subprocess.DEVNULL, check=True)
        else:
            subprocess.run(["textutil", "-convert", "docx", t.name, "-output", str(path)], check=True)
        os.unlink(t.name)
    elif kind in ("png", "jpg"):
        fmt = "png" if kind == "png" else "jpeg"
        subprocess.run(["sips", "-s", "format", fmt, ICON, "--out", str(path)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
    elif kind == "txt":
        path.write_text(text)
    else:
        path.write_bytes(b"")


def build(name: str, spec: dict) -> Path:
    root = OUT / name
    shutil.rmtree(root, ignore_errors=True)
    for folder in spec["folders"]:
        (root / "Sorted" / folder).mkdir(parents=True, exist_ok=True)
    for fname, kind, text, _ in spec["files"]:
        make_file(root / "Inbox" / fname, kind, text)
    for folder, fname, kind, text in spec.get("existing", []):
        make_file(root / "Sorted" / folder / fname, kind, text)
    (root / "descriptions.json").write_text(json.dumps(spec["folders"], indent=2))
    return root


def run(app: Path, root: Path, threshold: float, learn: bool) -> dict:
    data = root / ".data"
    env = {**os.environ, "JEVSORT_DATA_DIR": str(data), "JEVSORT_ENGINE": str(REPO / "engine")}
    base = [str(app), "--headless", "--demo", str(root), "--descriptions", str(root / "descriptions.json"),
            "--threshold", str(threshold)]
    if learn:
        t = subprocess.run(base + ["--train"], env=env, capture_output=True, text=True, check=True)
        report = json.loads(t.stdout).get("train", {})
        print(f"    learned: {report.get('examples')} examples, activated={report.get('activated')}, "
              f"held-out {report.get('new_accuracy')} vs {report.get('current_accuracy')} ({report.get('reason', '')})")
    r = subprocess.run(base + ["--sort"], env=env, capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def score(spec: dict, result: dict) -> dict:
    expect = {f: set(e) for f, _, _, e in spec["files"]}
    rows = {m["file"]: m for m in result.get("moves", [])}
    s = {"files": len(expect), "moved_ok": 0, "moved_wrong": 0, "stayed_ok": 0, "review": 0, "review_top_ok": 0,
         "not_seen": 0, "wrong": [], "review_miss": []}
    for f, ok in expect.items():
        m = rows.get(f)
        if m is None:
            s["not_seen"] += 1
            continue
        folder = m["folder"] or "NONE"
        if m["status"] == "moved":
            if folder in ok:
                s["moved_ok"] += 1
            else:
                s["moved_wrong"] += 1
                s["wrong"].append(f"{f} -> {folder} (want {sorted(ok)})")
        elif ok == {"NONE"}:
            s["stayed_ok"] += 1
        else:
            s["review"] += 1
            if folder in ok:
                s["review_top_ok"] += 1
            else:
                s["review_miss"].append(f"{f}: top {folder} {m['confidence']:.2f} (want {sorted(ok)})")
    return s


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", type=Path, default=REPO / "build/JevFolderSort.app/Contents/MacOS/JevFolderSort")
    ap.add_argument("--threshold", type=float, default=0.9)
    ap.add_argument("--only", default="")
    ap.add_argument("--learn", action="store_true", help="run 'learn' (bootstrap from Sorted) before sorting")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()
    names = [n for n in SCENARIOS if not args.only or n in args.only.split(",")]
    totals = {"files": 0, "moved_ok": 0, "moved_wrong": 0, "stayed_ok": 0, "review": 0, "review_top_ok": 0}
    print(f"{'scenario':20} {'files':>5} {'moved ok':>9} {'WRONG':>6} {'left ok':>8} {'review':>7} {'top-1 in review':>16}")
    for name in names:
        spec = SCENARIOS[name]
        root = build(name, spec)
        res = run(args.app, root, args.threshold, args.learn)
        if res.get("scope_issues"):
            print(name, "scope issues:", res["scope_issues"]); continue
        s = score(spec, res)
        for k in totals:
            totals[k] += s[k]
        print(f"{name:20} {s['files']:5} {s['moved_ok']:9} {s['moved_wrong']:6} {s['stayed_ok']:8} {s['review']:7} "
              f"{s['review_top_ok']:>9}/{s['review']:<6}")
        if args.verbose or s["wrong"]:
            for w in s["wrong"]:
                print("    WRONG:", w)
        if args.verbose:
            for w in s["review_miss"]:
                print("    review miss:", w)
    t = totals
    auto = t["moved_ok"] + t["moved_wrong"]
    print(f"{'TOTAL':20} {t['files']:5} {t['moved_ok']:9} {t['moved_wrong']:6} {t['stayed_ok']:8} {t['review']:7} "
          f"{t['review_top_ok']:>9}/{t['review']:<6}")
    right = t["moved_ok"] + t["stayed_ok"] + t["review_top_ok"]
    print(f"\nauto-moved {auto}/{t['files']} ({auto / t['files']:.0%}), precision {t['moved_ok'] / max(auto, 1):.0%}; "
          f"model's first choice right on {right}/{t['files']} ({right / t['files']:.0%})")


if __name__ == "__main__":
    main()
