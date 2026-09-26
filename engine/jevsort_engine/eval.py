"""Evaluate a checkpoint (and the keyword baseline) on the hand-written messy set.

    uv run python -m jevsort_engine.eval --model checkpoints/base
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from datasets.eval import dev, messy
from datasets.generate import KINDS

from .baseline import KeywordSorter
from .state import NONE_ID, Folder

THRESHOLDS = (0.5, 0.75, 0.9)


def eval_cases(source=messy) -> list[tuple[list[Folder], list[dict], list[set[str]]]]:
    """Cases from a hand-written set: `messy` (held-out eval) or `dev` (selection)."""
    TREES, FILES = source.TREES, source.FILES
    cases = []
    for name, tree in TREES.items():
        folders = [Folder(f"f{i + 1}", path, desc) for i, (path, desc) in enumerate(tree)]
        by_path = {f.path: f.id for f in folders}
        raws, accepted = [], []
        for i, (fname, text, url, ok) in enumerate(FILES[name]):
            ext = fname.rsplit(".", 1)[1].lower() if "." in fname else ""
            raw = {"id": f"{name}-{i}", "name": fname, "ext": ext, "kind": KINDS.get(ext, "Document")}
            if text:
                raw["text"] = text
            if url:
                raw["where_from"] = [url]
            raws.append(raw)
            accepted.append({NONE_ID if p == "NONE" else by_path[p] for p in ok})
        cases.append((folders, raws, accepted))
    return cases


def evaluate(sorter, cases=None) -> dict:
    cases = cases or eval_cases()
    rows = []  # (choice, confidence, correct, should_stay)
    start = time.perf_counter()
    n_files = 0
    for folders, raws, accepted in cases:
        for dist, ok in zip(sorter.distributions(folders, raws), accepted):
            choice = max(dist, key=dist.get)
            rows.append((choice, dist[choice], choice in ok, ok == {NONE_ID}))
        n_files += len(raws)
    ms = (time.perf_counter() - start) * 1000 / n_files

    report = {"files": len(rows), "top1": sum(r[2] for r in rows) / len(rows), "ms_per_file": ms}
    for t in THRESHOLDS:
        moved = [r for r in rows if r[1] >= t and r[0] != NONE_ID]
        report[f"@{t}"] = {
            "auto_moved": len(moved) / len(rows),
            "precision": sum(r[2] for r in moved) / len(moved) if moved else 1.0,
            "wrong_moves": sum(not r[2] for r in moved) / len(rows),
        }
    bins = [[] for _ in range(10)]
    for r in rows:
        bins[min(int(r[1] * 10), 9)].append(r)
    report["ece"] = sum(
        len(b) / len(rows) * abs(sum(r[1] for r in b) / len(b) - sum(r[2] for r in b) / len(b)) for b in bins if b
    )
    return report


def format_report(name: str, r: dict) -> str:
    lines = [f"{name}: top-1 {r['top1']:.1%}  ECE {r['ece']:.3f}  {r['ms_per_file']:.1f} ms/file  (n={r['files']})"]
    for t in THRESHOLDS:
        x = r[f"@{t}"]
        lines.append(f"   threshold {t}: auto-moved {x['auto_moved']:.1%}, precision {x['precision']:.1%}, wrong moves {x['wrong_moves']:.1%} of all files")
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model", type=Path)
    p.add_argument("--json", type=Path, help="write the report here")
    args = p.parse_args()
    reports = {"baseline": evaluate(KeywordSorter())}
    if args.model:
        from .model import FileSorter, load_checkpoint

        model, meta = load_checkpoint(args.model)
        reports[meta.get("version", "model")] = evaluate(FileSorter(model, meta))
    for name, r in reports.items():
        print(format_report(name, r))
    if args.json:
        args.json.write_text(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
