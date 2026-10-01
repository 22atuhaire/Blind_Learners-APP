# Evaluation Methodology — Question Generation Accuracy

*Fulfils Proposal section 3.5.1 ("Accuracy Evaluation"). Read this before quoting
any figure from `results/results.md`.*

## 1. What is being evaluated

The **on-device question generator** (`lib/shared/services/ai_question_service.dart`)
— the engine that actually runs in the student's hands. It converts a teacher's
uploaded note into multiple-choice questions entirely offline, using only the
note's own text.

The server-side generator that once existed was removed: question generation
runs on the phone by design, so evaluating anything else would measure code no
student ever executes.

## 2. The corpus (10 lesson notes)

| # | Note | Subject | Grade | Source |
|---|---|---|---|---|
| 1 | Higher Number Operations | Mathematics | P.6 | real teacher note |
| 2 | Living and Non-Living Things | Science | P.3 | real teacher note |
| 3 | Food and Nutrition | Science | P.4 | real teacher note |
| 4 | Water | Science | P.5 | authored |
| 5 | The Digestive System | Science | P.6 | authored |
| 6 | Weather and Climate | Social Studies | P.5 | authored |
| 7 | Physical Features of Uganda | Social Studies | P.5 | authored |
| 8 | Fractions | Mathematics | P.5 | authored |
| 9 | Parts of Speech | English | P.6 | authored |
| 10 | Personal Hygiene and Disease Prevention | Health Education | P.4 | authored |

Three are genuine notes previously uploaded through the system. Seven were
authored to match the Ugandan primary curriculum and to cover structures the
real notes did not: rule lists, worked examples, ASCII tables, bullet lists and
definition-dense prose. **This mix is a limitation and is stated as one** — a
field-sourced corpus of ten would be stronger, and is the natural next step
during the pilot.

## 3. Ground truth

For every note, `ground_truth.json` records the **core concepts** a teacher
would expect a short revision quiz to test — five per note, fifty in total.

Two rules kept this honest:

1. Concepts were chosen by reading each note **as a teacher**, before looking
   at what the generator produces. A ground truth written after seeing the
   output would only measure itself.
2. Concepts the generator structurally **cannot** reach were deliberately kept
   in (facts stated only inside tables, for example). The ground truth has to
   be able to fail the system, or it proves nothing.

Five concepts per note is not arbitrary: it matches the generator's minimum
quiz length, so recall asks a fair question — *do the questions it produces
cover the things that matter?* — rather than punishing it for a length limit.

## 4. Definitions

A generated question is **valid** when it passes six objective checks *and* a
human marker agrees it is pedagogically sound.

| Check | What it protects |
|---|---|
| A1 answer key | The marked answer exists and is non-empty |
| A2 distinct options | No duplicate options (two correct answers, or an unanswerable item) |
| A3 **content-bound** | The correct answer appears verbatim in the teacher's note |
| A4 well-formed | Reads as a question; no fused label, no fragment |
| A5 audio-friendly | Every option short, cleanly terminated, balanced parentheses |
| A6 no length cue | Correct answer is not obviously the longest option |

**A3 is the most important check in this project.** The proposal claims a
content-bound AI that cannot hallucinate. A3 tests that claim directly on every
single question: if the answer is not in the teacher's note, the system invented
it. Reporting A3 = 100% is stronger evidence for the central architectural claim
than any aggregate score.

From these:

- **True positive (TP)** — a valid question.
- **False positive (FP)** — a question that fails a check or that a human marks
  unsound.
- **False negative (FN)** — a core concept no valid question covers.
- **Precision** = TP / (TP + FP) — of what it asked, how much was sound?
- **Recall** = covered concepts / expected concepts — of what mattered, how much did it ask?
- **F1** = harmonic mean of precision and recall.
- **Accuracy (3.5.1)** = covered concepts / total expected concepts × 100.

A concept only counts as covered by a question that is itself valid. Covering a
concept with a broken question is not teaching it.

## 5. Two-pass scoring, and why

**Pass 1 (automatic).** The harness applies A1–A6. These are decidable by a
machine without opinion.

**Pass 2 (human).** The harness writes `results/scoring_sheet.md` listing every
question. A human marks each valid or invalid against four criteria (answer
genuinely correct; worth teaching; answerable by ear; distractors plausible but
wrong). Verdicts go into `results/human_scores.csv`; re-running the harness
folds them in and relabels the report **FINAL**.

Without that file the report is labelled **PROVISIONAL**, deliberately. A
generator graded only by rules its own author wrote is circular — the automatic
checks can prove a question is well-formed and content-bound, but not that it is
worth asking. That judgement is human, and the report says so rather than
hiding it behind a number.

## 6. Reproducing the result

```
cd Blind_Learners-APP
dart run eval/run_evaluation.dart
```

Outputs land in `eval/results/`: `results.md` (report tables), `results.csv`
(per-note figures), `scoring_sheet.md` (for pass 2), and
`generated_questions.json` (raw output, so any figure can be re-checked).

Generation is deterministic — the same note always yields the same questions —
so the run is exactly repeatable by an examiner.

## 7. What this evaluation found (and changed)

The harness was not a formality; it exposed a real defect and drove a fix.

**Defect: no coverage spread.** The generator walked a note's sentences in
reading order and stopped at five questions. On a Parts of Speech note it
produced five questions about *nouns* and never reached verbs, adjectives or
adverbs. Measured recall: **42%**.

**Fixes, all made in response to measurement:**

1. **Section-aware selection** — heading and label lines were already detected
   in order to discard them; they are now also used as topic boundaries, and
   selection takes at most one question per section before revisiting any.
2. **Subject de-duplication** — a quiz will not ask five variations on the same
   head noun ("common noun", "proper noun", "collective noun"…).
3. **A rule pattern** — "A number is divisible by 2 **if** its last digit is
   even" is a rule, not a definition, and was previously discarded. It now
   becomes "When is a number divisible by 2?", with the conditions of the
   note's other rules as distractors. Much of a syllabus is rules.
4. **Length-proportional quiz** — a fixed five questions cannot cover a nine
   section chapter. Quiz length now scales from 5 to 8 with the note's size.
5. **List and bullet handling** — leading bullets are stripped (no more "What is
   - They provide fish which?"), and fill-in-the-blank questions are only built
   from sentences that actually assert something, which removed worthless items
   like "Cows, goats, ____, dogs".

Recall rose from **42% to ~68%** with precision holding at **100%**.

## 8. Honest limitations

- **The 85% target in the proposal was not met on recall.** The residual gap is
  concentrated in facts the note states only in tables or bullet lists (the
  MRS GREN characteristics, the food-nutrient table), which a sentence-pattern
  generator cannot reach. Raising recall further needs table parsing, not
  tuning — that is named as further work rather than quietly dropped.
- **Precision of 100% is measured against objective checks**, pending the human
  pass. Expect the final figure to fall somewhat once a marker applies
  judgement; that is the point of pass 2.
- **Seven of ten notes are authored, not field-sourced.** Stated in §2.
- **The ground truth and the fixes share an author**, which creates an
  overfitting risk. It was managed by keeping every fix a general structural
  rule (sections, bullets, rules, quiz length) rather than anything specific to
  a note in the corpus, and by leaving unreachable concepts in the ground truth.
  An independent marker repeating pass 2 is the strongest available check.
