"""On-device personalisation (M6).

Fine-tunes the base checkpoint on the user's own examples: files already in
their folders (bootstrap), Review choices, re-files after undo, and files they
moved between folders themselves. Always starts from the *base* model with all
examples so far (no drift from repeated fine-tunes).

Only the read-out stack and heads train; the state and text encoders stay
frozen. A slice of the user's examples is held out, and the new model is only
activated if it does at least as well there as the model currently in use.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import time
from pathlib import Path

import torch
from open_jev import RLCDLoss

from .model import FileSorter, build_choice, load_checkpoint, save_checkpoint
from .state import NONE_ID, Folder, model_state, parse_tree

MIN_EXAMPLES = 8
BATCH = 16


def _soft_target(ids: list[str], target: str) -> list[float]:
    others = [i for i in ids if i not in (target, NONE_ID)]
    spread = 0.1 / len(others) if others else 0.0
    t = [0.9 if i == target else (spread if i in others else 0.0) for i in ids]
    total = sum(t)
    return [v / total for v in t]


def _accuracy(sorter: FileSorter, folders: list[Folder], items: list[dict]) -> float:
    if not items:
        return 0.0
    dists = sorter.distributions(folders, [e["state"] for e in items])
    return sum(max(d, key=d.get) == e["target"] for d, e in zip(dists, items)) / len(items)


def personalize(
    base: Path,
    out: Path,
    tree: list[dict],
    examples: list[dict],
    current: Path | None = None,
    steps: int | None = None,
    seed: int = 0,
    replay: bool = True,
) -> dict:
    start = time.perf_counter()
    folders = parse_tree(tree)
    ids = {f.id for f in folders}
    usable = [e for e in examples if e.get("target") in ids and isinstance(e.get("state"), dict)]
    report = {"examples": len(usable), "dropped": len(examples) - len(usable), "activated": False}
    if len(usable) < MIN_EXAMPLES:
        report["reason"] = f"need at least {MIN_EXAMPLES} examples for folders in the current scope"
        return report

    rng = random.Random(seed)
    torch.manual_seed(seed)
    rng.shuffle(usable)
    n_hold = max(2, len(usable) // 5)
    holdout, train = usable[:n_hold], usable[n_hold:]

    model, meta = load_checkpoint(base, torch.device("cpu"))
    for module in (model.state_encoder, model.text_encoder):
        for p in module.parameters():
            p.requires_grad_(False)
    trainable = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.AdamW(trainable, lr=1e-4, weight_decay=0.01)
    loss_fn = RLCDLoss(w_consistency=0.0)
    question, option_ids = build_choice(folders)
    steps = steps or min(400, max(100, 20 * len(train)))

    if replay:
        from datasets.generate import make_group

    model.train()
    for step in range(steps):
        if replay and step % 3 == 2:  # keep general knowledge: a synthetic batch
            g = make_group(rng, BATCH)
            gf = parse_tree(g["tree"])
            gq, gids = build_choice(gf)
            states = [model_state(f["state"]) for f in g["files"]]
            target = torch.tensor([[f["target"].get(i, 0.0) for i in gids] for f in g["files"]])
            loss = 0.5 * loss_fn(model, states, [gq], [target])
        else:
            batch = [rng.choice(train) for _ in range(BATCH)]
            states = [model_state(e["state"]) for e in batch]
            target = torch.tensor([_soft_target(option_ids, e["target"]) for e in batch])
            loss = loss_fn(model, states, [question], [target])
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(trainable, 1.0)
        opt.step()
    model.eval()

    new_acc = _accuracy(FileSorter(model), folders, holdout)
    reference = current if current and (current / "model.safetensors").exists() else base
    ref_model, _ = load_checkpoint(reference, torch.device("cpu"))
    cur_acc = _accuracy(FileSorter(ref_model), folders, holdout)
    report.update(
        holdout=len(holdout), new_accuracy=round(new_acc, 4), current_accuracy=round(cur_acc, 4),
        steps=steps, seconds=round(time.perf_counter() - start, 1),
    )
    if new_acc < cur_acc:
        report["reason"] = "new model was worse on your held-out examples; kept the current one"
        return report

    version = f"{meta.get('version', 'base')}+user.{int(time.time())}"
    tmp = out.with_name(out.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    save_checkpoint(model, tmp, {**meta, "version": version, "personalized_from": meta.get("version"),
                                 "user_examples": len(usable), "holdout_accuracy": new_acc})
    old = out.with_name(out.name + ".old")
    shutil.rmtree(old, ignore_errors=True)
    if out.exists():
        os.replace(out, old)
    os.replace(tmp, out)
    shutil.rmtree(old, ignore_errors=True)
    report.update(activated=True, version=version, path=str(out))
    return report


def main() -> None:  # manual use: python -m jevsort_engine.personalize examples.json
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("payload", type=Path, help="JSON with tree, examples")
    p.add_argument("--base", type=Path, default=Path("checkpoints/base"))
    p.add_argument("--out", type=Path, default=Path("checkpoints/user"))
    args = p.parse_args()
    payload = json.loads(args.payload.read_text())
    print(json.dumps(personalize(args.base, args.out, payload["tree"], payload["examples"]), indent=2))


if __name__ == "__main__":
    main()
