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

from .decision import RLCDLoss
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


def _predictions(sorter: FileSorter, folders: list[Folder], items: list[dict]) -> list[tuple[str, float, str]]:
    """(predicted id, confidence, target id) per item."""
    if not items:
        return []
    dists = sorter.distributions(folders, [e["state"] for e in items])
    return [(max(d, key=d.get), max(d.values()), e["target"]) for d, e in zip(dists, items)]


def _accuracy(preds: list[tuple[str, float, str]]) -> float:
    return sum(p == t for p, _, t in preds) / len(preds) if preds else 0.0


def suggest_threshold(preds: list[tuple[str, float, str]], target_precision: float = 0.95) -> float | None:
    """Lowest confidence threshold whose auto-moves are >= target_precision on held-out examples.

    None when there are too few held-out examples (< 10) for the estimate to mean anything.
    """
    if len(preds) < 10:
        return None
    for t in (0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95):
        moved = [(p, t_) for p, c, t_ in preds if c >= t and p != NONE_ID]
        if len(moved) >= max(3, len(preds) // 5) and sum(p == t_ for p, t_ in moved) / len(moved) >= target_precision:
            return t
    return None


def _split(items: list[dict], rng: random.Random) -> tuple[list[dict], list[dict]]:
    """Hold out ~20% per folder (folders with a single example stay in training)."""
    by: dict[str, list[dict]] = {}
    for e in items:
        by.setdefault(e["target"], []).append(e)
    hold, train = [], []
    for group in by.values():
        rng.shuffle(group)
        k = max(1, len(group) // 5) if len(group) >= 2 else 0
        hold += group[:k]
        train += group[k:]
    if len(hold) < 2:  # tiny sets: fall back to a plain split
        rng.shuffle(items)
        n = max(2, len(items) // 5)
        return items[n:], items[:n]
    return train, hold


def personalize(
    base: Path,
    out: Path,
    tree: list[dict],
    examples: list[dict],
    current: Path | None = None,
    steps: int | None = None,
    seed: int = 0,
    replay: bool = True,
    unfreeze_top: int | None = None,
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
    train, holdout = _split(list(usable), rng)

    model, meta = load_checkpoint(base, torch.device("cpu"))
    for module in (model.state_encoder, model.text_encoder):
        for p in module.parameters():
            p.requires_grad_(False)
    # With enough examples, also adapt the top MiniLM layers to the user's
    # vocabulary (e.g. their clients' names), gently.
    if unfreeze_top is None:
        unfreeze_top = 2 if len(train) >= 40 else 0
    encoder_params: list[torch.nn.Parameter] = []
    bert = getattr(model, "bert", None)
    if bert is not None and unfreeze_top > 0:
        for layer in bert.layers[-unfreeze_top:]:
            for p in layer.parameters():
                p.requires_grad_(True)
                encoder_params.append(p)
    enc_ids = {id(p) for p in encoder_params}
    head_params = [p for p in model.parameters() if p.requires_grad and id(p) not in enc_ids]
    trainable = head_params + encoder_params
    opt = torch.optim.AdamW([{"params": head_params, "lr": 1e-4},
                             {"params": encoder_params, "lr": 1e-5}], weight_decay=0.01)
    loss_fn = RLCDLoss(w_consistency=0.0)
    question, option_ids = build_choice(folders)
    steps = steps or min(600, max(100, 20 * len(train)))

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

    new_preds = _predictions(FileSorter(model), folders, holdout)
    reference = current if current and (current / "model.safetensors").exists() else base
    ref_model, _ = load_checkpoint(reference, torch.device("cpu"))
    cur_preds = _predictions(FileSorter(ref_model), folders, holdout)
    new_acc, cur_acc = _accuracy(new_preds), _accuracy(cur_preds)
    names = {f.id: f.path for f in folders}
    per_folder = {}
    for fid in sorted({t for _, _, t in new_preds}):
        rows = [(p, t) for p, _, t in new_preds if t == fid]
        per_folder[names.get(fid, fid)] = {"held_out": len(rows), "correct": sum(p == t for p, t in rows)}
    counts: dict[str, int] = {}
    for e in usable:
        counts[names.get(e["target"], e["target"])] = counts.get(names.get(e["target"], e["target"]), 0) + 1
    report.update(
        holdout=len(holdout), new_accuracy=round(new_acc, 4), current_accuracy=round(cur_acc, 4),
        steps=steps, seconds=round(time.perf_counter() - start, 1), unfrozen_layers=unfreeze_top,
        suggested_threshold=suggest_threshold(new_preds), per_folder=per_folder, examples_per_folder=counts,
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
