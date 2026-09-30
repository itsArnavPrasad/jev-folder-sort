# The model

One question per file: **"Which of these folders does this file belong in?"** It's answered in one forward pass, on this Mac, as a probability over *your* allowed folders plus **"none of these folders fit"**. The model can't name a folder that isn't in your list, and it never sees a path.

Current checkpoint: **`minilm-0.4.0`**, 32.8M parameters, ~60 MB, 4–7 ms per file on CPU. How we got here: [MODEL_HISTORY.md](MODEL_HISTORY.md).

## What it sees

`engine/jevsort_engine/state.py` turns what the app extracted into a fixed schema:

```python
{"name": "2025 W2 acme",          # file name, humanised (separators split, extension removed)
 "ext": "pdf",
 "kind": "PDF document",           # Spotlight kind
 "source": "payroll.acme.com",     # download site(s), domains only
 "title": "...",                   # document title, if any
 "text": "Form W-2 Wage and ..."}  # first N KB of text (N set in Settings), max 1,500 chars
```

Folder options are `"Finance / Taxes: tax forms like W-2 and 1099"`: the folder path, plus your plain-English description when there is one.

## Architecture (`minilm.py`, `decision.py`)

```
file state ──► MiniLM (6 layers, 384-d, pretrained) + structural embeddings ──► token states ─┐
                         │ mean-pool                                                          │
                         ▼                                                                    ▼
               file embedding ──cos──► description prior      8 query slots ─► 4 read-out layers ─► Choice head
                                           │                     (question-conditioned)           │
folder options ─► same MiniLM ─► option embeddings ─────────────────────────────────────────────┤
                                           ▼                                                      ▼
                         softmax( learned Choice score  +  prior_scale · cos(file, option) )  ──► P(folder)
```

- **Encoder:** all-MiniLM-L6-v2, a sentence-similarity model pretrained on over a billion sentence pairs, shared by the file and the folder options. Our own BERT implementation loads its weights exactly. Word vectors are frozen; the transformer layers fine-tune.
- **Structural embeddings:** which field each token came from (`name`, `text`, …), independent of key order. They start at zero, so the model starts out as exactly MiniLM.
- **Decision head** (`decision.py`, adapted from open-jev):
  - question-conditioned query slots cross-attend into the file;
  - a typed Choice head scores each option;
  - an evidential confidence head;
  - trained with the RLCD loss (soft NLL + Brier + consistency + evidential + ECE) for calibrated probabilities.
- **Description prior:** a learned-scale cosine similarity between the file and each option. It's why plain-English descriptions work immediately and can't be "trained away".
- **Keyword prior (v0.4):** learned-scale log(1 + content words shared by the file and the option). It catches client names, people and brands ("Brightwave", "Ella"), which a sentence model is weakest on.
- **"None of these" (v0.4):** a learned constant score. MiniLM rates the sentence "none of these folders fit this file" as similar to almost any file, so giving it a cosine made "none" win close calls.
- **File kinds:** when macOS only says "Document", the extension becomes a readable kind ("SQL database script", "OpenType font file", "macOS installer package"). The macOS screenshot flag and camera make/model are appended too ("PNG image, screenshot").
- **Confidence:** `confidence` is the top probability. The app moves a file only if it's at or above your threshold (default 90%) *and* the answer isn't `none`; otherwise the file waits in Review.

## Training (`train.py`, `datasets/`)

- **Data:** generated on the fly (`datasets/generate.py`).
  - 40 file concepts: tax forms, statements, receipts, invoices, payslips, contracts, lecture notes, papers, photos, screenshots, installers, code, bookings, medical, …
  - Each concept has filename and text templates.
  - Placed into random folder trees: grouped, flat, 3-level, generic catch-alls ("Documents", "Media"), and **opaque names described only in plain English** ("Box A: bills, taxes, anything with prices").
  - Folder descriptions come in many phrasings. Junk files target "none".
  - Targets are soft (the right folder ~0.9, the parent or a related folder a little).
- **Optimisation:** AdamW, head learning rate 3e-4, MiniLM 2e-5, warmup plus cosine schedule, batches of 16 files that share one tree (exactly the shape of an app scan), on CPU.
- **Selection:** the hand-written **dev set** (`datasets/eval/dev.py`, 60 files), scored as top-1 − ½·ECE. The untrained step-0 model is a candidate. The held-out sets below are *never* used for selection.

```bash
cd engine
uv run python -m jevsort_engine.train --out checkpoints/base      # ~30–40 min on an M-series CPU
uv run python -m jevsort_engine.eval --model checkpoints/base --zero-shot
```

## Results

Two hand-written held-out sets, using brands, languages (German) and phrasing the generator never uses. Several answers may be acceptable, and "leave it" is a valid answer.
- **messy** (150 files): three realistic trees (student, freelancer, minimal with descriptions).
- **plain_english** (53 files): folder names that mean nothing ("Box 5", "Maya", "P-17"). Only the description says what goes there.

**minilm-0.4.0** (warm-started from 0.3.0; selected on dev + scenarios):

| | top-1 | ECE | Auto-moved @0.75 | Precision @0.75 | Auto-moved @0.9 | Precision @0.9 | Wrong moves @0.9 |
|---|---|---|---|---|---|---|---|
| messy (held-out) | **82.7%** | 0.057 | 64% | 94.8% | 52% | 97.4% | 1.3% |
| plain_english (held-out) | **94.3%** | 0.047 | 74% | 97.4% | 60% | 96.9% | 1.9% |
| dev (selection) | 85.0% | 0.058 | — | — | 50% | 100% | 0% |

For comparison, minilm-0.3.0 scored 77.3% and 84.9% on the two held-out sets.

"Wrong moves" is the share of *all* files the app would move to an unacceptable folder at that threshold. Everything else is either moved correctly or left in Review.

Comparison, including the earlier open-jev models and Laya zero-shot: [MODEL_HISTORY.md](MODEL_HISTORY.md#summary-of-results-hand-written-held-out-sets).

**What this means in practice:**
- At the default 90% threshold, a third to a half of files move automatically, and almost none go to the wrong place.
- The rest wait in Review with the model's top suggestions.
- Good folder descriptions and "Learn from my folders" raise the automatic share.

### End-to-end, through the real app

`scripts/e2e_scenarios.py` covers four realistic setups (student, freelance designer, family admin, developer; 69 files). For each one it:
1. builds real PDFs, DOCX files, images and code files inside the repo;
2. gives each folder a plain-English description;
3. runs the app headless at the default 90% threshold.

The scenarios were also used for checkpoint selection, so treat these as development numbers.

| | Auto-moved | Wrong moves | Left correctly ("none") | To Review | First choice right |
|---|---|---|---|---|---|
| minilm-0.3.0 | 36/69 (52%) | **0** | 4 | 29 | 61/69 (88%) |
| **minilm-0.4.0** | **44/69 (64%)** | **0** | 4 | 21 | **65/69 (94%)** |
| + Learn from my folders (2 scenarios, 10–14 pre-sorted files each) | 21/34 (62%) vs 19/34 without | 0 | 2 | 11 | 32/34 |

## Personalisation (`personalize.py`)

See [TRAIN_ON_YOUR_FOLDERS.md](TRAIN_ON_YOUR_FOLDERS.md). In short:
1. Examples come from files already in your folders (read-only), your Review choices, re-files after an undo, and files you move between folders yourself.
2. It fine-tunes from the base model:
   - the read-out and heads, plus the top 2 MiniLM layers once there are 40+ examples;
   - with synthetic replay so general knowledge isn't lost;
   - holding out 20% per folder.
3. The new model is activated only if it isn't worse there.
4. The report includes per-folder accuracy and a suggested threshold (≥95% held-out precision).

## Known limits

- **Images, video and audio** get only their name and metadata (no OCR or vision yet), so a camera photo named `IMG_1234.jpg` relies on the file type.
- **English-first:** MiniLM's vocabulary covers other Latin-script languages only partly.
- **Very large trees:** trees over 254 folders use a two-stage choice (top-level folder first, then the folder within it).
- **Descriptions are the strongest signal.** A folder with no description, no files and a generic name ("Stuff") is hard for any model.
