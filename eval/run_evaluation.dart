// AudioLearner — question-generation evaluation harness
//
// Fulfils Proposal section 3.5.1: measures the accuracy, precision and recall
// of the on-device question generator against a hand-authored ground truth,
// over 10 lesson notes.
//
// Run from the app root:
//     dart run eval/run_evaluation.dart
//
// Outputs (into eval/results/):
//     results.md          - the table for the report / a slide
//     results.csv         - per-note numbers for further analysis
//     scoring_sheet.md    - every generated question, for human marking
//     generated_questions.json - raw output, so any run can be re-checked
//
// The two-pass design matters. Pass 1 applies OBJECTIVE checks a machine can
// make without opinion (is the answer key valid? does the answer actually
// appear in the teacher's note? can the options be told apart by ear?).
// Pass 2 is a human verdict, because whether a question is *pedagogically*
// sound is a judgement a rule cannot honestly make. If a marked
// results/human_scores.csv exists, its verdicts override the automatic ones
// and the report says so. Without that file the report is clearly labelled
// PROVISIONAL — a generator graded only by its own assumptions proves nothing.

import 'dart:convert';
import 'dart:io';

import 'package:audioapp/shared/services/ai_question_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Objective (machine-checkable) validity checks
// ─────────────────────────────────────────────────────────────────────────────

class CheckResult {
  CheckResult(this.id, this.passed, this.detail);
  final String id;
  final bool passed;
  final String detail;
}

/// Normalises text for comparison: lowercase, punctuation to spaces, collapsed
/// whitespace. Used when testing whether an answer really came from the note.
String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

int _wordCount(String s) =>
    s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

List<String> _optionsOf(AiGeneratedQuestion q) =>
    [q.optionA, q.optionB, q.optionC, q.optionD];

String? _correctText(AiGeneratedQuestion q) {
  switch (q.correctOption.toUpperCase()) {
    case 'A':
      return q.optionA;
    case 'B':
      return q.optionB;
    case 'C':
      return q.optionC;
    case 'D':
      return q.optionD;
  }
  return null;
}

/// Runs every objective check against one question.
List<CheckResult> runChecks(AiGeneratedQuestion q, String noteText) {
  final results = <CheckResult>[];
  final options = _optionsOf(q);
  final correct = _correctText(q);
  final normNote = _norm(noteText);

  // A1 — the answer key points at a real, non-empty option.
  results.add(CheckResult(
    'A1_answer_key',
    correct != null && correct.trim().isNotEmpty,
    correct == null
        ? 'correctOption "${q.correctOption}" is not A-D'
        : (correct.trim().isEmpty ? 'correct option is empty' : 'ok'),
  ));

  // A2 — the four options are distinguishable (a duplicate makes two answers
  // correct, or makes the question unanswerable).
  final distinct = options.map((o) => _norm(o)).toSet();
  results.add(CheckResult(
    'A2_distinct_options',
    distinct.length == 4 && !distinct.contains(''),
    distinct.length == 4 ? 'ok' : 'only ${distinct.length} distinct options',
  ));

  // A3 — CONTENT-BOUND: the correct answer must appear in the teacher's own
  // note. This is the check that substantiates the proposal's central claim
  // that the AI cannot hallucinate, so it is the most important one here.
  final grounded = correct != null && _norm(correct).isNotEmpty
      ? normNote.contains(_norm(correct))
      : false;
  results.add(CheckResult(
    'A3_content_bound',
    grounded,
    grounded ? 'answer found in note' : 'answer NOT found in note',
  ));

  // A4 — the question reads as a question, not a fragment or a fused label.
  final qt = q.questionText.trim();
  final wellFormed = qt.length >= 8 &&
      _wordCount(qt) >= 3 &&
      (qt.endsWith('?') || qt.toLowerCase().startsWith('fill in the blank')) &&
      !qt.contains(':');
  results.add(CheckResult(
    'A4_well_formed',
    wellFormed,
    wellFormed ? 'ok' : 'malformed question text',
  ));

  // A5 — audio-friendly: a blind student holds the options in memory from
  // speech alone, so each must be short and cleanly terminated.
  final badOption = options.firstWhere(
    (o) =>
        _wordCount(o) > 12 ||
        o.trim().endsWith(',') ||
        ('('.allMatches(o).length != ')'.allMatches(o).length),
    orElse: () => '',
  );
  results.add(CheckResult(
    'A5_audio_friendly',
    badOption.isEmpty,
    badOption.isEmpty ? 'ok' : 'unspeakable option: "$badOption"',
  ));

  // A6 — no length cue: if the correct answer is far longer than every
  // distractor, a student can guess it without understanding anything.
  var lengthLeak = false;
  if (correct != null) {
    final correctLen = _wordCount(correct);
    final others = options
        .where((o) => _norm(o) != _norm(correct))
        .map(_wordCount)
        .toList();
    if (others.isNotEmpty) {
      final longestOther = others.reduce((a, b) => a > b ? a : b);
      lengthLeak = correctLen >= 3 && correctLen > longestOther * 2;
    }
  }
  results.add(CheckResult(
    'A6_no_length_cue',
    !lengthLeak,
    lengthLeak ? 'correct answer much longer than all distractors' : 'ok',
  ));

  return results;
}

// ─────────────────────────────────────────────────────────────────────────────
// Evaluation
// ─────────────────────────────────────────────────────────────────────────────

class QuestionRecord {
  QuestionRecord({
    required this.noteId,
    required this.index,
    required this.question,
    required this.checks,
    required this.conceptsHit,
  });

  final String noteId;
  final int index;
  final AiGeneratedQuestion question;
  final List<CheckResult> checks;
  final List<String> conceptsHit;

  bool get autoValid => checks.every((c) => c.passed);
  List<String> get failedChecks =>
      checks.where((c) => !c.passed).map((c) => c.id).toList();

  /// Set from results/human_scores.csv when that file is present.
  bool? humanValid;

  bool get isValid => humanValid ?? autoValid;
  String get key => '$noteId#$index';
}

class NoteResult {
  NoteResult(this.noteId, this.title, this.subject, this.grade, this.source);
  final String noteId;
  final String title;
  final String subject;
  final String grade;
  final String source;

  final List<QuestionRecord> questions = [];
  final List<String> allConceptIds = [];
  final Set<String> coveredConceptIds = {};

  int get generated => questions.length;
  int get valid => questions.where((q) => q.isValid).length;
  int get invalid => generated - valid;
  int get expected => allConceptIds.length;
  int get covered => coveredConceptIds.length;
  int get missed => expected - covered;

  double get precision => generated == 0 ? 0 : valid / generated;
  double get recall => expected == 0 ? 0 : covered / expected;
  double get accuracy => expected == 0 ? 0 : covered / expected;
}

void main(List<String> args) async {
  final root = Directory.current.path;
  final evalDir = Directory('$root/eval');
  if (!evalDir.existsSync()) {
    stderr.writeln('Run this from the app root (Blind_Learners-APP), '
        'e.g. `dart run eval/run_evaluation.dart`');
    exit(1);
  }

  final gtFile = File('$root/eval/ground_truth.json');
  final gt = jsonDecode(gtFile.readAsStringSync()) as Map<String, dynamic>;
  final noteSpecs = (gt['notes'] as List).cast<Map<String, dynamic>>();

  // Optional human verdicts.
  final humanFile = File('$root/eval/results/human_scores.csv');
  final humanVerdicts = <String, bool>{};
  if (humanFile.existsSync()) {
    for (final line in humanFile.readAsLinesSync().skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;
      final key = '${parts[0].trim()}#${parts[1].trim()}';
      final verdict = parts[2].trim().toLowerCase();
      if (verdict == 'valid' || verdict == 'y' || verdict == 'yes') {
        humanVerdicts[key] = true;
      } else if (verdict == 'invalid' || verdict == 'n' || verdict == 'no') {
        humanVerdicts[key] = false;
      }
    }
  }
  final humanScored = humanVerdicts.isNotEmpty;

  final service = AiQuestionService();
  final noteResults = <NoteResult>[];

  for (final spec in noteSpecs) {
    final noteId = spec['noteId'] as String;
    final file = File('$root/eval/notes/$noteId.txt');
    if (!file.existsSync()) {
      stderr.writeln('MISSING NOTE: ${file.path}');
      continue;
    }
    final noteText = file.readAsStringSync();
    final concepts = (spec['coreConcepts'] as List).cast<Map<String, dynamic>>();

    final result = NoteResult(
      noteId,
      spec['title'] as String,
      spec['subject'] as String,
      spec['grade'] as String,
      spec['source'] as String,
    );
    for (final c in concepts) {
      result.allConceptIds.add(c['id'] as String);
    }

    final questions = service.generateQuestions(noteText);

    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final checks = runChecks(q, noteText);

      // Which core concepts does this question touch? Anchors are matched
      // against the question text AND its correct answer together, because a
      // concept can be named in either half.
      final haystack = _norm('${q.questionText} ${_correctText(q) ?? ''}');
      final hits = <String>[];
      for (final c in concepts) {
        final anchors = (c['anchors'] as List).cast<String>();
        if (anchors.any((a) => haystack.contains(_norm(a)))) {
          hits.add(c['id'] as String);
        }
      }

      final record = QuestionRecord(
        noteId: noteId,
        index: i + 1,
        question: q,
        checks: checks,
        conceptsHit: hits,
      );
      record.humanValid = humanVerdicts[record.key];
      result.questions.add(record);

      // A concept only counts as covered by a question that is actually VALID.
      // Covering a concept with a broken question is not teaching it.
      if (record.isValid) {
        result.coveredConceptIds.addAll(hits);
      }
    }

    noteResults.add(result);
  }

  _writeReports(root, noteResults, humanScored);
  _printSummary(noteResults, humanScored);
}

// ─────────────────────────────────────────────────────────────────────────────
// Reporting
// ─────────────────────────────────────────────────────────────────────────────

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

void _printSummary(List<NoteResult> results, bool humanScored) {
  final generated = results.fold<int>(0, (s, r) => s + r.generated);
  final valid = results.fold<int>(0, (s, r) => s + r.valid);
  final expected = results.fold<int>(0, (s, r) => s + r.expected);
  final covered = results.fold<int>(0, (s, r) => s + r.covered);

  final precision = generated == 0 ? 0.0 : valid / generated;
  final recall = expected == 0 ? 0.0 : covered / expected;
  final f1 = (precision + recall) == 0
      ? 0.0
      : 2 * precision * recall / (precision + recall);

  stdout.writeln('');
  stdout.writeln('AudioLearner — question generation evaluation');
  stdout.writeln('─' * 52);
  stdout.writeln('Notes evaluated        : ${results.length}');
  stdout.writeln('Questions generated    : $generated');
  stdout.writeln('Valid questions        : $valid');
  stdout.writeln('Expected concepts      : $expected');
  stdout.writeln('Concepts covered       : $covered');
  stdout.writeln('');
  stdout.writeln('Precision              : ${_pct(precision)}');
  stdout.writeln('Recall                 : ${_pct(recall)}');
  stdout.writeln('F1 score               : ${_pct(f1)}');
  stdout.writeln('Accuracy (3.5.1)       : ${_pct(recall)}');
  stdout.writeln('Proposal target        : 85.0%');
  stdout.writeln('');
  stdout.writeln(humanScored
      ? 'Scoring: automatic checks + human verdicts (FINAL)'
      : 'Scoring: automatic checks only (PROVISIONAL — mark '
          'eval/results/scoring_sheet.md and save human_scores.csv)');
  stdout.writeln('Reports written to eval/results/');
  stdout.writeln('');
}

void _writeReports(String root, List<NoteResult> results, bool humanScored) {
  Directory('$root/eval/results').createSync(recursive: true);

  final generated = results.fold<int>(0, (s, r) => s + r.generated);
  final valid = results.fold<int>(0, (s, r) => s + r.valid);
  final expected = results.fold<int>(0, (s, r) => s + r.expected);
  final covered = results.fold<int>(0, (s, r) => s + r.covered);
  final precision = generated == 0 ? 0.0 : valid / generated;
  final recall = expected == 0 ? 0.0 : covered / expected;
  final f1 = (precision + recall) == 0
      ? 0.0
      : 2 * precision * recall / (precision + recall);

  // ── results.md ───────────────────────────────────────────────────────────
  final md = StringBuffer()
    ..writeln('# Question Generation — Evaluation Results')
    ..writeln()
    ..writeln('*Generated by `dart run eval/run_evaluation.dart` on '
        '${DateTime.now().toIso8601String().split('T').first}. '
        'Fulfils Proposal section 3.5.1.*')
    ..writeln()
    ..writeln(humanScored
        ? '**Scoring: automatic checks + human verdicts (final).**'
        : '**Scoring: automatic checks only — PROVISIONAL.** '
            'Mark `scoring_sheet.md`, save the verdicts as '
            '`human_scores.csv`, and re-run for final figures.')
    ..writeln()
    ..writeln('## Headline figures')
    ..writeln()
    ..writeln('| Metric | Value | Target |')
    ..writeln('|---|---|---|')
    ..writeln('| Notes evaluated | ${results.length} | 10 |')
    ..writeln('| Questions generated | $generated | — |')
    ..writeln('| Valid questions | $valid | — |')
    ..writeln('| Expected concepts | $expected | — |')
    ..writeln('| Concepts covered | $covered | — |')
    ..writeln('| **Precision** | **${_pct(precision)}** | — |')
    ..writeln('| **Recall** | **${_pct(recall)}** | — |')
    ..writeln('| **F1 score** | **${_pct(f1)}** | — |')
    ..writeln('| **Accuracy (3.5.1)** | **${_pct(recall)}** | 85.0% |')
    ..writeln()
    ..writeln('## Per-note results')
    ..writeln()
    ..writeln('| # | Note | Subject | Grade | Src | Gen | Valid | Prec | '
        'Concepts | Covered | Recall |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|---|');

  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    md.writeln('| ${i + 1} | ${r.title} | ${r.subject} | ${r.grade} | '
        '${r.source} | ${r.generated} | ${r.valid} | ${_pct(r.precision)} | '
        '${r.expected} | ${r.covered} | ${_pct(r.recall)} |');
  }

  // Failure analysis — what actually went wrong, by check.
  final failureCounts = <String, int>{};
  for (final r in results) {
    for (final q in r.questions) {
      for (final f in q.failedChecks) {
        failureCounts[f] = (failureCounts[f] ?? 0) + 1;
      }
    }
  }
  md
    ..writeln()
    ..writeln('## Failure analysis (automatic checks)')
    ..writeln();
  if (failureCounts.isEmpty) {
    md.writeln('No question failed an automatic check.');
  } else {
    md
      ..writeln('| Check | Failures |')
      ..writeln('|---|---|');
    final sorted = failureCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      md.writeln('| ${e.key} | ${e.value} |');
    }
  }

  // Missed concepts — the honest half of the story.
  md
    ..writeln()
    ..writeln('## Concepts not covered (false negatives)')
    ..writeln();
  var anyMissed = false;
  for (final r in results) {
    final missed =
        r.allConceptIds.where((c) => !r.coveredConceptIds.contains(c)).toList();
    if (missed.isEmpty) continue;
    anyMissed = true;
    md.writeln('- **${r.title}** (${r.grade}): ${missed.join(', ')}');
  }
  if (!anyMissed) md.writeln('All expected concepts were covered.');

  File('$root/eval/results/results.md').writeAsStringSync(md.toString());

  // ── results.csv ──────────────────────────────────────────────────────────
  final csv = StringBuffer()
    ..writeln('note_id,title,subject,grade,source,generated,valid,invalid,'
        'precision,expected_concepts,covered,missed,recall');
  for (final r in results) {
    csv.writeln('${r.noteId},"${r.title}",${r.subject},${r.grade},${r.source},'
        '${r.generated},${r.valid},${r.invalid},'
        '${r.precision.toStringAsFixed(4)},${r.expected},${r.covered},'
        '${r.missed},${r.recall.toStringAsFixed(4)}');
  }
  File('$root/eval/results/results.csv').writeAsStringSync(csv.toString());

  // ── scoring_sheet.md ─────────────────────────────────────────────────────
  final sheet = StringBuffer()
    ..writeln('# Human scoring sheet')
    ..writeln()
    ..writeln('Mark every question **valid** or **invalid**, then record your')
    ..writeln('verdicts in `eval/results/human_scores.csv` with the header:')
    ..writeln()
    ..writeln('```')
    ..writeln('note_id,index,verdict')
    ..writeln('01_number_operations_p6_math,1,valid')
    ..writeln('01_number_operations_p6_math,2,invalid')
    ..writeln('```')
    ..writeln()
    ..writeln('Re-run the harness afterwards; your verdicts override the')
    ..writeln('automatic ones and the report is relabelled FINAL.')
    ..writeln()
    ..writeln('A question is **valid** when all of these hold:')
    ..writeln('1. The marked answer is genuinely correct according to the note.')
    ..writeln('2. The question is about something worth teaching '
        '(not trivia or a fragment).')
    ..writeln('3. A blind student could answer it from listening alone.')
    ..writeln('4. The three distractors are clearly wrong but plausible.')
    ..writeln();

  for (final r in results) {
    sheet
      ..writeln('---')
      ..writeln()
      ..writeln('## ${r.title} (${r.subject}, ${r.grade})')
      ..writeln();
    if (r.questions.isEmpty) {
      sheet.writeln('_No questions generated._\n');
      continue;
    }
    for (final rec in r.questions) {
      final q = rec.question;
      sheet
        ..writeln('**${rec.index}. ${q.questionText}**')
        ..writeln();
      const letters = ['A', 'B', 'C', 'D'];
      final opts = _optionsOf(q);
      for (var i = 0; i < opts.length; i++) {
        final marker = letters[i] == q.correctOption.toUpperCase() ? ' ←' : '';
        sheet.writeln('- ${letters[i]}. ${opts[i]}$marker');
      }
      sheet
        ..writeln()
        ..writeln('- Auto: ${rec.autoValid ? "PASS" : "FAIL "
            "(${rec.failedChecks.join(", ")})"}')
        ..writeln('- Concepts hit: '
            '${rec.conceptsHit.isEmpty ? "none" : rec.conceptsHit.join(", ")}')
        ..writeln('- Explanation: ${q.explanation}')
        ..writeln('- **Verdict (`${rec.noteId},${rec.index}`): ______**')
        ..writeln();
    }
  }
  File('$root/eval/results/scoring_sheet.md').writeAsStringSync(sheet.toString());

  // ── generated_questions.json ─────────────────────────────────────────────
  final dump = results
      .map((r) => {
            'noteId': r.noteId,
            'title': r.title,
            'questions': r.questions
                .map((rec) => {
                      'index': rec.index,
                      'questionText': rec.question.questionText,
                      'options': _optionsOf(rec.question),
                      'correctOption': rec.question.correctOption,
                      'explanation': rec.question.explanation,
                      'autoValid': rec.autoValid,
                      'failedChecks': rec.failedChecks,
                      'conceptsHit': rec.conceptsHit,
                    })
                .toList(),
          })
      .toList();
  File('$root/eval/results/generated_questions.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(dump));
}
