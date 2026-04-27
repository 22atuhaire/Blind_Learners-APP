import 'dart:math';

/// A single AI-generated multiple-choice question produced by [AiQuestionService].
///
/// All four option fields are always populated — [optionD] is never null because
/// this service always generates exactly four choices per question.
///
/// [correctOption] is one of `'A'`, `'B'`, `'C'`, or `'D'` after option
/// shuffling, so callers must not assume it is always `'A'`.
class AiGeneratedQuestion {
  const AiGeneratedQuestion({
    required this.questionText,
    required this.optionA,
    required this.optionB,
    required this.optionC,
    required this.optionD,
    required this.correctOption,
    required this.explanation,
  });

  final String questionText;
  final String optionA;
  final String optionB;
  final String optionC;

  /// Always populated — this service always produces four distinct options.
  final String optionD;

  /// The letter (`'A'`–`'D'`) of the correct option after shuffling.
  final String correctOption;

  /// A short explanation referencing the lesson text.
  final String explanation;

  @override
  String toString() =>
      'AiGeneratedQuestion(q: "$questionText", correct: $correctOption)';
}

/// Generates multiple-choice quiz questions from lesson text without any
/// internet connection or ML model.
///
/// Uses a two-pass rule-based approach:
///
/// **Pattern A** — structural extraction
/// When a sentence contains a linking verb (`is / are / was / were`), the
/// subject and predicate are split out to form a well-structured question such
/// as *"What is photosynthesis?"*.
///
/// **Pattern B** — comprehension fallback
/// For sentences that do not match Pattern A, a "which statement is correct?"
/// question is generated using the sentence itself as the correct option and
/// three other lesson sentences as distractors.
///
/// Results are reproducible: the same lesson text always produces the same
/// questions in the same order (the internal [Random] is seeded from
/// [String.hashCode] of the input text).
///
/// Usage:
/// ```
/// final service = AiQuestionService();
/// final questions = service.generateQuestions(lessonText);
/// for (final q in questions) {
///   print(q.questionText);
/// }
/// ```
class AiQuestionService {
  // ──────────────────────────────────────────────────────────────
  // Constants
  // ──────────────────────────────────────────────────────────────

  /// Minimum word count a sentence must have to be considered for a question.
  static const int _minWords = 8;

  /// Maximum number of questions to generate per lesson.
  static const int _maxQuestions = 10;

  /// Sentence-boundary patterns used to split the lesson text.
  static final RegExp _sentenceSplitter = RegExp(r'\. |\.\n|\? |! ');

  /// Linking verbs that trigger Pattern A question generation.
  static const List<String> _linkingVerbs = [
    ' is ',
    ' are ',
    ' was ',
    ' were ',
  ];

  // ──────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────

  /// Generates up to [_maxQuestions] MCQ questions from [lessonText].
  ///
  /// Returns an empty list when [lessonText] is blank or when fewer than four
  /// distinct sentences can be extracted (which makes it impossible to produce
  /// three unique wrong answers for any question).
  List<AiGeneratedQuestion> generateQuestions(String lessonText) {
    if (lessonText.trim().isEmpty) return [];

    // ── 1. Tokenise into sentences ────────────────────────────────────────
    final sentences = lessonText
        .split(_sentenceSplitter)
        .map((s) => s.trim())
        .where(_hasEnoughWords)
        .toList();

    // Need at least 4 sentences: 1 correct + 3 wrong-answer candidates.
    if (sentences.length < 4) return [];

    // ── 2. Shuffle deterministically based on the lesson content ──────────
    // Using lessonText.hashCode as the seed guarantees that the same text
    // always yields the same question order, making results reproducible
    // without persisting any extra state.
    final rng = Random(lessonText.hashCode);
    final shuffled = List<String>.from(sentences)..shuffle(rng);

    // ── 3. Generate questions (try up to _maxQuestions sentences) ─────────
    final questions = <AiGeneratedQuestion>[];

    for (final sentence in shuffled) {
      if (questions.length >= _maxQuestions) break;

      // Prefer the richer Pattern A; fall back to Pattern B if it doesn't
      // apply or if not enough wrong-answer candidates can be found.
      final question = _tryPatternA(sentence, sentences, rng) ??
          _patternB(sentence, sentences, rng);

      if (question != null) questions.add(question);
    }

    return questions;
  }

  // ──────────────────────────────────────────────────────────────
  // Pattern A — linking-verb extraction
  // ──────────────────────────────────────────────────────────────

  /// Attempts to build a Pattern A question from [sentence].
  ///
  /// Returns `null` when:
  ///   - no linking verb is found in [sentence]
  ///   - the split yields an empty subject or predicate
  ///   - fewer than three distinct wrong-answer candidates can be collected
  AiGeneratedQuestion? _tryPatternA(
    String sentence,
    List<String> allSentences,
    Random rng,
  ) {
    // Find the first linking verb present in the sentence.
    String? foundVerb;
    for (final verb in _linkingVerbs) {
      if (sentence.contains(verb)) {
        foundVerb = verb;
        break;
      }
    }
    if (foundVerb == null) return null;

    final splitIdx = sentence.indexOf(foundVerb);
    final subject = _truncate(sentence.substring(0, splitIdx).trim(), 60);
    final predicate =
        _truncate(sentence.substring(splitIdx + foundVerb.length).trim(), 100);

    if (subject.isEmpty || predicate.isEmpty) return null;

    // ── Collect wrong-answer candidates ────────────────────────────────────
    // Priority 1: predicates extracted from other Pattern A sentences.
    final wrongCandidates = <String>[];

    for (final other in allSentences) {
      if (other == sentence) continue;
      for (final verb in _linkingVerbs) {
        if (other.contains(verb)) {
          final otherIdx = other.indexOf(verb);
          final otherPredicate = _truncate(
            other.substring(otherIdx + verb.length).trim(),
            80,
          );
          if (otherPredicate.isNotEmpty &&
              otherPredicate != predicate &&
              !wrongCandidates.contains(otherPredicate)) {
            wrongCandidates.add(otherPredicate);
          }
          break; // Only process the first linking verb per sentence.
        }
      }
    }

    // Priority 2: fill any remaining slots with whole other sentences
    // (truncated), which still sound plausible as distractors.
    for (final other in allSentences) {
      if (wrongCandidates.length >= 3) break;
      if (other == sentence) continue;
      final truncated = _truncate(other, 80);
      if (truncated != predicate && !wrongCandidates.contains(truncated)) {
        wrongCandidates.add(truncated);
      }
    }

    if (wrongCandidates.length < 3) return null;

    wrongCandidates.shuffle(rng);

    final questionText = 'What ${foundVerb.trim()} $subject?';
    return _shuffleOptions(
      questionText: questionText,
      correct: predicate,
      wrongs: wrongCandidates.sublist(0, 3),
      rng: rng,
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Pattern B — comprehension fallback
  // ──────────────────────────────────────────────────────────────

  /// Builds a "which statement is correct?" question using [sentence] as the
  /// correct option and three other lesson sentences as distractors.
  ///
  /// Returns `null` when fewer than three other sentences are available.
  AiGeneratedQuestion? _patternB(
    String sentence,
    List<String> allSentences,
    Random rng,
  ) {
    final correct = _truncate(sentence, 120);

    final others = allSentences
        .where((s) => s != sentence && s.trim().isNotEmpty)
        .map((s) => _truncate(s, 120))
        .toList()
      ..shuffle(rng);

    if (others.length < 3) return null;

    return _shuffleOptions(
      questionText: 'According to the lesson, which statement is correct?',
      correct: correct,
      wrongs: [others[0], others[1], others[2]],
      rng: rng,
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Option shuffling
  // ──────────────────────────────────────────────────────────────

  /// Randomly distributes [correct] and [wrongs] across options A–D so that
  /// the correct answer is not always option A.
  ///
  /// Updates [correctOption] accordingly and populates [explanation] with a
  /// brief reference to the lesson text.
  AiGeneratedQuestion _shuffleOptions({
    required String questionText,
    required String correct,
    required List<String> wrongs,
    required Random rng,
  }) {
    assert(
        wrongs.length == 3, '_shuffleOptions requires exactly 3 wrong answers');

    // Build a mutable list: [correct, wrong0, wrong1, wrong2]
    final options = [correct, wrongs[0], wrongs[1], wrongs[2]];

    // Shuffle so the correct answer lands on a random position each time.
    options.shuffle(rng);

    // Locate where the correct answer ended up.
    final correctIndex = options.indexOf(correct);
    final correctLetter = const ['A', 'B', 'C', 'D'][correctIndex];

    return AiGeneratedQuestion(
      questionText: questionText,
      optionA: options[0],
      optionB: options[1],
      optionC: options[2],
      optionD: options[3],
      correctOption: correctLetter,
      explanation: 'According to the lesson: $correct',
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Utility helpers
  // ──────────────────────────────────────────────────────────────

  /// Returns [text] unchanged when it is within [maxLength] characters, or
  /// the first [maxLength] characters otherwise.
  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return text.substring(0, maxLength);
  }

  /// Returns `true` when [sentence] contains at least [_minWords] words.
  ///
  /// Splitting on any whitespace run avoids false negatives caused by
  /// multiple consecutive spaces or tabs in the source document.
  bool _hasEnoughWords(String sentence) {
    if (sentence.isEmpty) return false;
    final wordCount =
        sentence.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    return wordCount >= _minWords;
  }
}
