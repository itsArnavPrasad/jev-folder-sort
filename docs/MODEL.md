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

Per file (`engine/jevsort_engine/state.py` and `model.py`):
```python
state = {"name": "2025 W2 acme", "ext": "pdf", "kind": "PDF document",
         "source": "payroll.acme.com", "title": ..., "text": "<first N KB, max 1,500 chars>"}
Choice("Which folder does this file belong in?",
       options=[f"{path}: {description}" for folder in allowed_folders] + ["none of these folders fit this file"])
```

- Each option is the folder path (as `Finance / Taxes`) plus its description, so the model can match meaning ("W-2" → *Finance / Taxes: tax documents*).
- The last option is always the reserved **`__none__`**. A file that doesn't belong anywhere can say so, instead of being forced into the nearest folder. It stays where it is.
- The engine gets folder **ids** from the app and only ever returns one of them. It never sees or returns a path.
- Filenames are humanised (`2025_W2-acmeCorp.pdf` → `2025 W2 acme Corp`), and "Where from" URLs are reduced to domains.
- Files are batched 16 at a time per forward pass against one Choice.
- Trees with more than 254 folders (open-jev's 255-option cap, minus `__none__`) are handled in two stages: pick a top-level folder, then choose within it.

### 3.2 Confidence

`confidence` is the top-1 probability of the Choice softmax. The app auto-moves only when it's ≥ the user's threshold (default 0.9, from the M1 eval below) and the answer isn't `__none__`. RLCD's calibration terms are what make this safe: a threshold of 0.9 should *mean* about 90% right. We measure calibration (ECE) on every checkpoint. open-jev's separate evidential `head_confidence` isn't used for gating yet.

## 4. Changes around open-jev

open-jev is vendored **unmodified** in `engine/third_party/open_jev/` (commit `93843ef`, Apache-2.0). Everything below is done from the outside:

1. **Pretrained tokenizer.** `PretrainedTokenizer` implements open-jev's tokenizer interface (`encode`, `encode_batch`, `PAD`) using the all-MiniLM-L6-v2 WordPiece vocabulary (30,522 tokens, bundled as `assets/minilm-tokenizer.json`), and is passed in as `Jev(cfg, tokenizer=...)`.
2. **Pretrained, tied, frozen word embeddings.** The state encoder's and text encoder's token tables become **one shared table**, initialised from MiniLM's word embeddings and **frozen**. That removes 23M trainable parameters, which was the difference between 0.3 and ~2.3 training steps per second on an 8 GB Mac. Words the synthetic corpus never uses (brand names, German) also keep their pretrained meaning.
3. **Rescaled structural embeddings.** open-jev initialises every embedding at N(0, 1), which would drown MiniLM's vectors (std ≈ 0.056). Depth, sibling, path and position embeddings start at std 0.02 instead.
4. **Size.** `d_model` 384, 6 heads, `d_ff` 1024, 4 state layers, 2 question layers, 4 read-out layers, 8 slots, `max_state_len` 512. That's 30.4M parameters in total, of which 18.7M are trainable. The checkpoint is 58 MB in fp16, including the embedding table.
5. **CPU by default.** At this size the CPU beats MPS: kernel-launch overhead dominates, and the CPU avoids a ~1 s Metal warm-up. Set `JEVSORT_DEVICE=mps` to override.

The tokenizer swap is a candidate to offer upstream as a PR to open-jev.

## 5. Training

### Stage A: base model (M1, done)

Goal: a general-purpose "file → folder" chooser that works reasonably on a folder tree it has never seen, before any personalisation.

- **Data** (`engine/datasets/`), generated on the fly, so the stream is effectively unlimited:
  - `ontology.py`: 40 file concepts across 12 groups (tax forms, bank statements, receipts, invoices, payslips, contracts, lecture notes, assignments, papers, ebooks, photos, screenshots, installers, code, datasets, bookings, medical, …). Each concept has filename templates, extensions, source domains, text-snippet templates, and 3–6 **folder-name synonyms** per concept and group.
  - `generate.py`: random trees (flat, grouped, 3-level "Personal/Work" and mixed layouts, about 3–30 folders) with optional descriptions. Each batch holds 16 files from one tree. 20% of files come from concepts that aren't in the tree.
  - **Soft targets:** 0.9 on the right leaf and 0.05 on its parent; if the leaf is missing, 0.85 on the parent group folder; 0.65–1.0 on `__none__` when nothing fits; a little mass on closely related folders (receipts ↔ invoices).
  - Hard cases: 30% of files with text have a bland name (`document`, `scan0001`), so only the content tells you what they are.
- **Augmentation:** drop metadata fields and truncate text, used for the RLCD consistency term. Option order is shuffled by tree construction.
- **Objective:** open-jev's `RLCDLoss` (soft NLL + Brier + consistency + evidential + ECE), AdamW at lr 3e-4 with warmup and cosine decay, and gradient clipping.
- **Model selection:** on a *synthetic* validation set only. The held-out set below is reported, never selected on.
- **Held-out eval** (`engine/datasets/eval/messy.py`): 150 hand-written files over three fixed trees (student, freelancer, minimal-with-descriptions). It uses brands, languages (German invoices and tax notices) and phrasing the generator never uses. Several answers may be acceptable, and "should stay put" is a valid answer.

#### Results

6,000 steps (batches of 16 files), about 45 minutes on the CPU of an 8 GB M-series Mac. Checkpoint `base-0.1.0`, selected at step 6,000 on synthetic validation (92.5% top-1).

Held-out messy set (150 files; `uv run python -m jevsort_engine.eval --model checkpoints/base`):

| | top-1 | ECE | auto-moved @0.75 | precision @0.75 | wrong moves @0.75 | auto-moved @0.9 | precision @0.9 | wrong moves @0.9 | ms/file |
|---|---|---|---|---|---|---|---|---|---|
| Keyword baseline | 33.3% | 0.237 | 22.7% | 79.4% | 4.7% | 22.7% | 79.4% | 4.7% | <0.1 |
| base-0.1.0, step 2,000 | 58.0% | 0.069 | 36.7% | 83.6% | 6.0% | 24.7% | 89.2% | 2.7% | 8.8 |
| **base-0.1.0, step 6,000** | **61.3%** | 0.194 | 51.3% | 81.8% | 9.3% | **33.3%** | **92.0%** | **2.7%** | 2–7 |

"Wrong moves" is the share of *all* files that would be auto-moved to an unacceptable folder.

**What this means:**
- The exit bar is met: the model is almost twice as accurate as the baseline, at a few ms per file.
- It **overfits the synthetic distribution**. Synthetic val kept climbing (67% → 92.5%) while held-out top-1 barely moved (58% → 61%) and calibration got worse (ECE 0.07 → 0.19).
- At 0.75 it would wrongly move 9% of files, which misses the PRD's under-5% target. **The app's default threshold is therefore 0.9**: 92% precision, 2.7% wrong moves, a third of files sorted automatically, and the rest left for review.

**Typical mistakes** (from the error analysis):
- Generic folders like "Documents" and "Media" (the generator's group names don't include them).
- Ignoring folder descriptions (`banner_final.psd` → Apps at 0.98 when Images says "photos, screenshots, graphics").
- Opaque binaries (`Unknown.bin` → Dev instead of none).
- Parent-vs-leaf confusion (IMG files → `Pictures` instead of `Pictures/Camera Roll`). Most of these fall below 0.75, so they stay put.

**Next data iteration** (before M6):
1. Add generic groups (Documents, Media, Stuff, Misc) and trees where folder names are uninformative and only the description tells you what goes there, so the model has to read descriptions.
2. Add more `__none__` examples for opaque binaries and off-topic files.
3. Add photo and screenshot leaves under generic parents.
4. Early-stop on a small hand-labelled *dev* set that stays separate from the eval set, instead of on synthetic val.
5. Personalisation (Stage B) on the user's own files is expected to give the biggest gain.


### Stage B: bootstrap on the user's tree (on-device, first run)

Files already sitting inside the user's destination folders are labelled examples for free. On first setup (and when the tree changes) the engine fine-tunes on a sample of them.
- Freeze the state encoder; train read-out + heads (fast: minutes on MPS, runs in background).
- Keep a small replay buffer of base-model examples to avoid forgetting.
- If there are too few examples, the base model is used as-is.

### Stage C: learning from corrections (on-device, ongoing)

Correction signals (see PRD 5.8): Review choices, undo + re-file, and implicit moves detected by the scanner.
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
