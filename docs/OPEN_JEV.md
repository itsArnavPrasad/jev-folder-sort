# How jev-folder-sort uses open-jev (and where it moves away from it)

[open-jev](https://github.com/kyegomez/open-jev) is an unofficial PyTorch reconstruction of TypeSafe AI's Jev, a "System One" model: state goes in, typed and calibrated decisions come out, in one pass. We vendor it **unmodified** at `engine/third_party/open_jev/` (commit `93843ef`, Apache-2.0). Everything below is built *around* it in `engine/jevsort_engine/`.

## What we kept from open-jev, and why

| open-jev piece | What it does for us |
|---|---|
| **`Choice` primitive** | "Which folder?" is a Choice over *your* folders plus "none of these". The answer can only be one of those options: a made-up folder is structurally impossible |
| **Query-slot read-out stack** (`ReadoutBlock`, 8 slots, 4 layers) | Reads the encoded file once and answers the question in one pass |
| **Typed heads** (`ChoiceHead`, `ConfidenceHead`, …) | A probability for every folder, plus an evidential confidence |
| **Structural path embeddings** (depth / sibling / path hash) | The model knows which field a token came from (`name` vs `text` vs `source`), and key order doesn't matter |
| **`RLCDLoss`** (soft NLL + Brier + consistency + evidential + ECE) | Trains for *calibrated* probabilities, which is what makes a "move only if ≥ 90% sure" threshold meaningful |

## Where we moved away, step by step

### v0.1: open-jev as designed, plus a real tokenizer (`arch = "jev"`)

- **Tokenizer:** open-jev ships a placeholder `HashTokenizer` that hashes whitespace-split words, so `invoice` and `invoices` are unrelated and nothing is known about language. We passed in a real WordPiece tokenizer, MiniLM's 30,522-token vocabulary, through open-jev's `Jev(cfg, tokenizer=...)` hook.
- **Word vectors:** open-jev's token tables start random. We loaded MiniLM's pretrained word vectors into them, tied the two tables into one, and **froze** it.
- **Encoders:** everything else, including open-jev's own encoder layers, was trained from scratch on synthetic data.
- **Result:** 61% top-1 on real-looking held-out files. But only 51–53% when folders are described in plain English with meaningless names, because the model learned to lean on folder *names* and mostly ignore descriptions.

### v0.2: better data only

Generic folders, description-only folders and junk files were added to the synthetic data. Held-out accuracy stayed flat (57%). **The limit was the model's language understanding, not the data.**

### v0.3: a pretrained MiniLM brain (`arch = "minilm"`, `engine/jevsort_engine/minilm.py`)

This is the real departure. Your goal is to *describe in plain English what goes in each folder, and have the sorter follow it*. That needs a model that already understands sentences, and open-jev's encoders trained from scratch can't provide it.

| | open-jev | jev-folder-sort v0.3 |
|---|---|---|
| State encoder (the file) | `StateEncoder`: pre-norm transformer, trained from scratch | **all-MiniLM-L6-v2**: 6 pretrained BERT layers (post-norm, 384-d, 12 heads), plus open-jev's structural embeddings added to its input |
| Text encoder (questions, folder options) | `TextEncoder`: separate small transformer, trained from scratch | **The same MiniLM**, shared: file and folder descriptions land in the same pretrained sentence space |
| Choice score | `ChoiceHead` dot product only | `ChoiceHead` **plus a description-matching prior**: `prior_scale × cos(file embedding, "path: description" embedding)` |
| Word vectors | Random | MiniLM's, frozen |
| Starting point | Random: answers are noise until trained | **Exactly MiniLM at step 0.** The structural embeddings and the learned Choice score start at zero, so an untrained model is already a working description matcher |
| Read-out, heads, loss | open-jev | Unchanged open-jev |

**Why not just load MiniLM's weights into open-jev's layers?** open-jev uses pre-norm blocks and BERT uses post-norm blocks with a different parameter layout, so the weights don't transfer. `minilm.py` implements the BERT layers itself (~100 lines, no `transformers` dependency) and loads MiniLM's weights exactly. We verified this: our embeddings match the official `sentence-transformers` library, with cosine similarity 1.0 and a maximum difference of 1.6e-7.

**How it plugs in without editing open-jev:** `JevMiniLM` subclasses open-jev's `Jev`. It swaps `state_encoder` and `text_encoder` for MiniLM-backed modules with the *same interfaces*, and overrides `logits()` to add the prior. `encode_state`, `_readout`, the heads and `RLCDLoss` are all open-jev's own code.

**Why a prior instead of trusting the learned head?** Fine-tuning on synthetic data can pull the model away from what MiniLM knows. With the prior, the plain-English similarity signal is always present. Training only has to learn the *corrections*: that "none of these" exists, parent-versus-child folders, file-type cues like `.dmg` → installers. The prior's scale is itself learned.

**Training:**
- MiniLM layers fine-tune gently (learning rate 2e-5); the open-jev read-out learns fast (3e-4).
- The step-0 model is a candidate checkpoint, so fine-tuning is kept only if it beats pure description matching on the dev set.

**Cost:** 32.8M parameters (21M trainable), a few ms per file on CPU. That's about the same size as v0.1, because MiniLM *replaced* open-jev's encoders rather than being added on top.

**Results:** see [MODEL.md](MODEL.md#results).

## What stays true to Jev's idea

- **One forward pass**, typed answers only, a probability for every allowed folder, and calibrated confidence for gating.
- **No generation:** the model can't invent a path or a folder.

What changed is only *where the language understanding comes from*: pretrained MiniLM instead of from-scratch encoders.

## Upstream

Candidates to offer back to open-jev as PRs:
- the tokenizer hook usage;
- a pretrained-encoder backbone option;
- the similarity prior for `Choice`.
