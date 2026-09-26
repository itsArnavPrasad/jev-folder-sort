# Teach it your own folders

jev-folder-sort starts out knowing general file types. It gets much better once it learns **your** folder structure. There are three ways to teach it, from least to most effort. Everything runs on your Mac.

## 1. Describe each folder in plain English (2 minutes, no training)

The model compares each file with `folder path: description`, using a pretrained sentence model. A good description is the single most useful thing you can give it.

**Main window → Structure →** select a folder → **"What goes here?"**

| Folder | Weak | Good |
|---|---|---|
| `Money` | *(empty)* | bills, receipts, bank and credit card statements, anything with prices |
| `P-17` | *(empty)* | client Brightwave: contracts, invoices and briefs for them |
| `Maya` | kids | everything for my daughter Maya: school letters, report cards, her doctor visits |
| `Box 5` | misc | screenshots and screen recordings |

Tips:
- Say what *kinds of files* go there, and name the people, clients or brands involved.
- Folder names can be anything ("Box 5", "P-17"). The description does the work.
- For fixed patterns, add a **rule** too: *Name matches* `Screenshot*`, *Downloaded from* `chase.com`. Rules always win.

## 2. "Learn from my folders" (1–3 minutes, recommended for new users)

If your folders already contain files you sorted by hand, those files are perfect training examples.

**In the app:** Welcome window step 4, or **Settings → Model → Learn from my folders**. It then:
1. **Reads** up to 100 recent files from each allowed folder: name, metadata and the first few KB of text. **Nothing is moved.**
2. Holds out ~20% of them per folder as a test.
3. Fine-tunes the model on the rest, including the top MiniLM layers once there are 40+ examples.
4. Only switches to the new model if it scores at least as well as the current one on the held-out files.
5. Shows per-folder results and a **suggested confidence threshold**: the lowest one that stays ≥95% precise on your held-out files. Click **Use suggested threshold** to apply it.

**From the terminal** (same thing, with a readable report):

```bash
scripts/learn_my_folders.sh ~/Documents/Sorted            # dry run: report only, model in ./.jevsort-learn
scripts/learn_my_folders.sh ~/Documents/Sorted --install  # quit the app first; installs the model into the app
```

```
Examples: 412  (held out for testing: 79)
Held-out accuracy: 91% personalised vs 74% base model
Suggested confidence threshold: 0.8
Per folder (held-out correct / total · examples):
  Finance/Taxes          9/9 · 44
  Clients/Brightwave     7/8 · 38
  ...
Few examples (add descriptions for these in Structure): Health
```
*(Illustrative output.)*

Folders with fewer than about 5 files don't have enough examples. Describe them well (step 1) and the model relies on the description instead.

## 3. Keep correcting (ongoing, automatic)

Every correction becomes a training example:

| You do | It learns |
|---|---|
| Pick a folder for a file in **Review** | That file belongs there |
| **Undo** a move, then file the file from Review | The right folder, and that the first guess was wrong |
| Drag a sorted file into a different folder yourself, in Finder | The folder you chose (detected by the file's inode) |

After **20 new examples**, it retrains automatically, but only on mains power. You can also click **Retrain now**. As with step 2, a new model is only used if it isn't worse on held-out examples. **Forget personalisation** returns to the base model.

## Privacy

- Examples are stored in the app's local database.
- The personalised model is stored under `~/Library/Application Support/jev-folder-sort/models/user`.
- The trainer runs in the same sandbox as the sorter: no network, and it can only write to that models folder.
- Nothing is uploaded.

## For developers: the pipeline

```
allowed folders (read-only) ──► LearningCollector.bootstrap ──► training_example (SQLite)
Review / refile / Finder moves ──────────────────────────────►        │
                                                                       ▼
Learner.train ─► sandboxed engine `train_user` ─► personalize.py:
   start from the base model · per-folder 20% hold-out · fine-tune the read-out
   (+ top MiniLM layers if ≥ 40 examples) · synthetic replay so general knowledge
   isn't forgotten · compare with the current model · write models/user atomically
   · report per-folder accuracy + suggested threshold
```

Headless (used by the script and for testing with a separate data folder):

```bash
JEVSORT_DATA_DIR=./.jevsort-learn build/JevFolderSort.app/Contents/MacOS/JevFolderSort \
  --headless --learn-from <root> --per-folder 100 --apply-threshold
```
