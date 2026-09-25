# The Model — open-jev for file sorting

## 1. Background: Jev and System One models

[Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) (TypeSafe AI, Sept 2026) is a "System One" model. It doesn't generate text. It takes a **state** (JSON / unstructured data) and a set of **typed questions**, and returns typed, calibrated answers in a single forward pass:

- **Choice**: pick one of the options supplied at runtime; returns a probability per option plus a confidence
- **Score**: position on an ordered scale
- **Noul**: probability that a statement is true

Because a Choice answer can only be one of the declared options, the model can't invent a folder that doesn't exist. File sorting is exactly this shape: *"Which of these folders does this file belong in?"*

The hosted Jev is a paid cloud API. **We don't use it.** We use [open-jev](https://github.com/kyegomez/open-jev), an unofficial open-source PyTorch reconstruction of the architecture, and run it locally.

## 2. What open-jev gives us, and what it doesn't

**Gives us** (≈930 lines of PyTorch, Apache-2.0):
- A bidirectional state encoder with structural path embeddings (understands nested JSON; order of keys doesn't matter)
- Query slots that cross-attend into a cached state encoding, so many questions share one encode
- Typed heads: `Noul`, `Choice` (runtime options, up to 255), `Score`, plus a confidence head
- `RLCDLoss`: soft-target NLL + Brier + consistency + confidence + ECE (trains for *calibrated* probabilities)

**Does not give us:**
- **Trained weights.** The model is randomly initialised; out of the box its answers are noise.
- **A real tokenizer.** `HashTokenizer` hashes whitespace-separated words, so `invoice` and `invoices` are unrelated tokens, and it has no prior knowledge of language.
- A training pipeline or data.

So the main engineering work in this project is **making open-jev actually know things**.

## 3. How we use it

### 3.1 The question

Per file:
```python
state = {"name": ..., "ext": ..., "kind": ..., "where_from": [...], "text": "<first N KB>"}
Choice("Which folder does this file belong in?",
       options=[f"{path}: {description}" for folder in tree])
```

- Each option is the folder path plus its description, so the model can match meaning ("W-2" → *Finance/Taxes: tax documents*).
- One file is one state; a scan's batch of files runs as one batched forward pass.
- Trees with more than 255 folders (the Choice limit) are handled in two stages: first pick the top-level folder, then choose within it.
- Per-folder option embeddings are cached until the tree changes.

### 3.2 Confidence

We gate on the model's calibrated `confidence` (and the top-1 vs. top-2 margin). This is why RLCD's calibration terms matter: a threshold of 0.75 has to *mean* ~75% right, or auto-moving is unsafe. We measure calibration (ECE) on every checkpoint.

## 4. Changes to open-jev

We vendor open-jev into `engine/third_party/open_jev/` with attribution, and make the minimum changes needed:

1. **Pretrained tokenizer + embeddings.** Replace `HashTokenizer` with a small pretrained subword tokenizer and initialise the token embeddings (and optionally the text encoder) from a small pretrained English encoder (MiniLM-class, ~20–30M params). This gives the model language knowledge on day one instead of learning English from our small dataset.
2. **File-state field schema.** Stable keys (`name`, `ext`, `kind`, `where_from`, `text`) so path embeddings learn what each field means.
3. **Size tuned for a Mac.** Target ≤ 50M parameters, ≤ 100 MB on disk, < 50 ms per file on an M1 via MPS.
4. **Checkpoint save/load + versioning.**

Anything generally useful (e.g. the tokenizer swap) should be offered back upstream as a PR to open-jev.

## 5. Training plan

### Stage A: base model (done by us, shipped in the DMG)

Goal: a general-purpose "file → folder" chooser that works reasonably on an unseen folder tree before any personalisation.

- **Data:** a synthetic corpus of (file state, folder tree, correct folder) examples:
  - Realistic filenames, metadata and text snippets across common categories (finance, receipts, work docs, school, code, screenshots, installers, media, travel, health, legal, ...).
  - Many different random folder trees with varied naming ("Money/Bills" vs "Finance/Invoices") so the model learns to match *meaning*, not memorise folder names.
  - Hard negatives: sibling folders that are close in meaning.
  - Soft targets where the label is genuinely ambiguous (RLCD is built for this).
  - Built by scripts in `engine/datasets/`, generated once on the developer's machine. Nothing in the shipped app calls any service.
- **Augmentation:** shuffle keys, drop fields, truncate text, shuffle option order (consistency term in RLCD).
- **Eval:** a hand-labelled held-out set of real-world-style messy files. Track top-1 accuracy, accuracy at the default threshold, coverage (% auto-moved), and ECE.

### Stage B: bootstrap on the user's tree (on-device, first run)

Files already sitting inside the user's destination folders are labelled examples for free. On first setup (and when the tree changes) the engine fine-tunes on a sample of them.
- Freeze the state encoder; train read-out + heads (fast: minutes on MPS, runs in background).
- Keep a small replay buffer of base-model examples to avoid forgetting.
- If there are too few examples, the base model is used as-is.

### Stage C: learning from corrections (on-device, ongoing)

Correction signals (see PRD 4.8): Review choices, undo + re-file, and implicit moves detected by the scanner.
- Stored as training examples in SQLite.
- Fine-tune when ≥ 20 new examples have built up, the Mac is idle and on power (or *Retrain now* in Settings).
- **Safety check:** a new checkpoint is only activated if it doesn't do worse on a held-out slice of the user's examples than the current one; otherwise it's discarded. The previous checkpoint is always kept for rollback.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Base model accuracy too low without a big pretrained backbone | Pretrained embeddings; rules tier catches the easy cases; bootstrap on the user's files; conservative threshold + Review list |
| Poor calibration → wrong auto-moves | RLCD calibration terms; ECE tracked per checkpoint; threshold tuned on eval |
| Synthetic data doesn't match real files | Real-world held-out eval; personalisation stages B/C do most of the work |
| PyTorch bundle size | Accepted for v1; Core ML export planned |
| Fine-tuning on battery | Only when idle + on power |
