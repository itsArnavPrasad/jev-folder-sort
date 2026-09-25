"""Newline-delimited JSON over stdin/stdout.

The engine never receives file paths and never touches the file system beyond
reading its own checkpoint. It answers "which of these folder ids?" and nothing
else; mapping an id back to a real folder, and deciding whether a move is
allowed, is the app's job (ScopeGuard).
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

PROTOCOL_VERSION = 1


def log(msg: str) -> None:
    print(f"[engine] {msg}", file=sys.stderr, flush=True)


class Server:
    def __init__(self, sorter) -> None:
        self.sorter = sorter

    def handle(self, req: dict) -> dict:
        from .state import parse_tree

        op = req.get("op")
        if op == "health":
            return {
                "ok": True,
                "protocol": PROTOCOL_VERSION,
                "model": self.sorter.meta.get("version", "unknown"),
                "kind": self.sorter.meta.get("kind", "model"),
                "device": str(self.sorter.device),
            }
        if op == "load_model":
            self.sorter = load_sorter(Path(req["path"]))
            return {"ok": True, "model": self.sorter.meta.get("version", "unknown")}
        if op == "classify":
            folders = parse_tree(req["tree"])
            files = req.get("files") or []
            for f in files:
                if "id" not in f or not isinstance(f.get("state"), dict):
                    raise ValueError("each file needs an id and a state object")
            raw = [{**f["state"], "id": f["id"]} for f in files]
            return {"ok": True, "results": self.sorter.classify(folders, raw) if raw else []}
        if op == "shutdown":
            return {"ok": True, "bye": True}
        raise ValueError(f"unknown op: {op!r}")

    def serve(self, stdin=sys.stdin, stdout=sys.stdout) -> None:
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            rid = None
            try:
                req = json.loads(line)
                rid = req.get("id")
                resp = self.handle(req)
            except Exception as exc:  # report, never crash the loop
                log(traceback.format_exc())
                resp = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
            resp["id"] = rid
            stdout.write(json.dumps(resp) + "\n")
            stdout.flush()
            if resp.get("bye"):
                return


def load_sorter(path: Path):
    from .model import FileSorter, load_checkpoint

    model, meta = load_checkpoint(path)
    log(f"loaded {meta.get('version')} from {path} on {next(model.parameters()).device}")
    return FileSorter(model, meta)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="jevsort-engine")
    parser.add_argument("--model", type=Path, help="checkpoint directory")
    parser.add_argument("--stub", action="store_true", help="keyword baseline, no model")
    args = parser.parse_args(argv)

    if args.stub or not args.model:
        from .baseline import KeywordSorter

        if not args.stub:
            log("no --model given; using keyword stub")
        sorter = KeywordSorter()
    else:
        sorter = load_sorter(args.model)
    Server(sorter).serve()


if __name__ == "__main__":
    main()
