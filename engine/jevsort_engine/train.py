"""Base training: FolderModel + RLCD on synthetic (tree, file, soft target) groups.

    uv run python -m jevsort_engine.train --steps 6000 --out checkpoints/base

Each step is one freshly generated folder tree with a batch of files, i.e. the
exact shape of an app scan. Checkpoints are selected on the small hand-written
dev set (datasets/eval/dev.py) minus half its calibration error; the held-out
messy set is only reported, never selected on.
"""

from __future__ import annotations

import argparse
import math
import random
import time
from pathlib import Path

import torch

from datasets.eval import dev as dev_set
from datasets.generate import augment, make_group

from .eval import eval_cases, evaluate, format_report
from .decision import RLCDLoss
from .model import FileSorter, build_choice, build_model, pick_device, save_checkpoint
from .state import model_state, parse_tree


def targets_tensor(ids: list[str], target: dict[str, float]) -> list[float]:
    return [target.get(i, 0.0) for i in ids]


def step_batch(group: dict, rng: random.Random):
    folders = parse_tree(group["tree"])
    question, ids = build_choice(folders)
    raws = [f["state"] for f in group["files"]]
    states = [model_state(r) for r in raws]
    aug = [model_state(augment(r, rng)) for r in raws]
    target = torch.tensor([targets_tensor(ids, f["target"]) for f in group["files"]])
    return states, aug, question, target


@torch.no_grad()
def val_score(model, val_groups) -> float:
    """Mean probability mass on the target distribution's argmax (synthetic val)."""
    model.eval()
    sorter = FileSorter(model)
    total, n = 0.0, 0
    for g in val_groups:
        folders = parse_tree(g["tree"])
        for dist, f in zip(sorter.distributions(folders, [f["state"] for f in g["files"]]), g["files"]):
            best = max(f["target"], key=f["target"].get)
            total += float(max(dist, key=dist.get) == best)
            n += 1
    model.train()
    return total / n


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--steps", type=int, default=3000)
    p.add_argument("--files", type=int, default=16, help="files per tree (batch size)")
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--encoder-lr", type=float, default=2e-5)
    p.add_argument("--warmup", type=int, default=300)
    p.add_argument("--eval-every", type=int, default=250)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--out", type=Path, default=Path("checkpoints/base"))
    p.add_argument("--version", default="minilm-0.3.0")
    args = p.parse_args()

    torch.manual_seed(args.seed)
    rng = random.Random(args.seed)
    val_rng = random.Random(10_000 + args.seed)
    val_groups = [make_group(val_rng, args.files) for _ in range(40)]
    dev_cases = eval_cases(dev_set)

    device = pick_device()
    model = build_model().to(device).train()
    n_params = sum(p.numel() for p in model.parameters())
    print(f"model: {n_params / 1e6:.1f}M params on {device}", flush=True)

    trainable = [p for p in model.parameters() if p.requires_grad]
    print(f"trainable: {sum(p.numel() for p in trainable) / 1e6:.1f}M", flush=True)
    # Pretrained MiniLM layers fine-tune gently; the fresh read-out learns fast.
    enc_ids = {id(p) for p in getattr(model, "encoder_parameters", lambda: [])()}
    groups = [{"params": [p for p in trainable if id(p) not in enc_ids], "lr": args.lr}]
    if enc_ids:
        groups.append({"params": [p for p in trainable if id(p) in enc_ids], "lr": args.encoder_lr})
    opt = torch.optim.AdamW(groups, weight_decay=0.05)
    base_lrs = [g["lr"] for g in opt.param_groups]
    loss_fn = RLCDLoss()

    best = -1.0
    # Step 0 is a real candidate: the untrained MiniLM model already matches
    # descriptions. Training only wins if it beats that on the dev set.
    model.eval()
    dev0 = evaluate(FileSorter(model), dev_cases)
    model.train()
    best = dev0["top1"] - 0.5 * dev0["ece"]
    print(f"  step 0 (zero-shot) | dev top-1 {dev0['top1']:.1%} ECE {dev0['ece']:.3f} score {best:.3f}", flush=True)
    save_checkpoint(model, args.out, {"version": args.version, "step": 0, "dev_top1": dev0["top1"],
                                      "dev_ece": dev0["ece"], "params": n_params})
    start = time.time()
    running = 0.0
    for step in range(1, args.steps + 1):
        warm = min(1.0, step / args.warmup)
        decay = 0.5 * (1 + math.cos(math.pi * step / args.steps))
        for g, lr in zip(opt.param_groups, base_lrs):
            g["lr"] = lr * warm * max(decay, 0.05)

        states, aug, question, target = step_batch(make_group(rng, args.files), rng)
        loss = loss_fn(model, states, [question], [target], augmented_states=aug)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        running = 0.98 * running + 0.02 * loss.item() if step > 1 else loss.item()

        if step % 50 == 0:
            rate = step / (time.time() - start)
            print(f"step {step}/{args.steps} loss {running:.4f} ({rate:.1f} it/s)", flush=True)
        if step % args.eval_every == 0 or step == args.steps:
            acc = val_score(model, val_groups)
            model.eval()
            dev = evaluate(FileSorter(model), dev_cases)
            model.train()
            score = dev["top1"] - 0.5 * dev["ece"]
            print(f"  val top-1 {acc:.1%} | dev top-1 {dev['top1']:.1%} ECE {dev['ece']:.3f} score {score:.3f}", flush=True)
            meta = {"version": args.version, "step": step, "val_top1": acc, "dev_top1": dev["top1"],
                    "dev_ece": dev["ece"], "params": n_params}
            if score > best:
                best = score
                save_checkpoint(model, args.out, meta)
                print(f"  saved {args.out} (best so far)", flush=True)

    from .model import load_checkpoint

    final, meta = load_checkpoint(args.out, device)
    print(format_report(f"{meta['version']} @ step {meta['step']}", evaluate(FileSorter(final, meta))))


if __name__ == "__main__":
    main()
