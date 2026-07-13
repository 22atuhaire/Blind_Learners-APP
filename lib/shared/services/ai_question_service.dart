import 'dart:math';

/// A single AI-generated multiple-choice question produced by [AiQuestionService].
///
/// All four option fields are always populated. [correctOption] is one of
/// 'A'..'D' after shuffling, so callers must not assume it is always 'A'.
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
  final String optionD;
  final String correctOption;
  final String explanation;

  @override
  String toString() =>
      'AiGeneratedQuestion(q: "$questionText", correct: $correctOption)';
}

/// Offline fallback quiz generator, used only when a lesson has no
/// server-authored (teacher-reviewed) questions — e.g. notes created while
/// offline. Mirrors the backend generator: short, audio-friendly definition and
/// fill-in-the-blank questions with length-matched distractors. Deterministic:
/// the same lesson text always yields the same questions.
///
/// Field-tested against real P.6 notes (structured with "Label:" lines,
/// worked examples, and rule lists), which produced questions like
/// "What is Since 6?" and "What are Key terms: Addends?". The pipeline now
/// understands note STRUCTURE before extracting anything:
///  - label lines ("Key terms:", "Rules for divisibility:") never merge into
///    the sentence that follows them;
///  - worked examples / arithmetic / imperative activity lines are excluded;
///  - subjects led by subordinators or participles ("Since…", "Following…")
///    and conditional rules ("X is Y IF Z") are never treated as definitions;
///  - options are cut on phrase boundaries with balanced parentheses.
class AiQuestionService {
  static const int _maxQuestions = 5;

  static final RegExp _sentenceSplitter = RegExp(r'(?<=[.!?])\s+|\n+');
  static final RegExp _whitespace = RegExp(r'\s+');

  static const List<String> _linkingVerbs = [' is ', ' are ', ' was ', ' were '];

  static const Set<String> _pronounSubjects = {
    'it', 'this', 'that', 'these', 'those', 'they', 'there',
    'he', 'she', 'we', 'you', 'i', 'here', 'its', 'their',
    'his', 'her', 'such', 'one', 'some', 'many', 'most',
  };

  // Question words / conjunctions that must never be a definition subject --
  // otherwise a question or heading like "Why is food important?" becomes the
  // nonsense question "What is Why?".
  static const Set<String> _interrogatives = {
    'why', 'what', 'how', 'when', 'where', 'who', 'whom', 'whose',
    'which', 'whether', 'if', 'because', 'although', 'though',
  };

  // Subordinators / participles / discourse words that begin a clause, not a
  // thing being defined. "Since 6 is 5 or more, round up" must never become
  // "What is Since 6?".
  static const Set<String> _clauseLeadIns = {
    'since', 'while', 'after', 'before', 'unless', 'until', 'during',
    'once', 'following', 'using', 'according', 'considering', 'given',
    'then', 'also', 'therefore', 'thus', 'hence', 'so', 'first', 'second',
    'next', 'finally', 'note', 'remember', 'example', 'answer',
  };

  // Imperative openers of worked examples and activities ("Write 35,000 in
  // words.", "Round 89,365 to the nearest 100."). Instructions to the reader
  // are not teachable statements — they make nonsense questions and clozes.
  static const Set<String> _imperativeStarts = {
    'write', 'work', 'round', 'find', 'use', 'complete', 'test', 'check',
    'add', 'subtract', 'multiply', 'divide', 'arrange', 'look', 'break',
    'read', 'solve', 'calculate', 'draw', 'list', 'name', 'state', 'fill',
    'copy', 'answer', 'practice', 'practise', 'keep',
  };

  static const Set<String> _stopwords = {
    'the', 'a', 'an', 'and', 'or', 'but', 'of', 'to', 'in', 'on', 'at',
    'for', 'with', 'as', 'by', 'from', 'is', 'are', 'was', 'were', 'be',
    'been', 'being', 'it', 'its', 'this', 'that', 'these', 'those', 'they',
    'them', 'their', 'there', 'here', 'about', 'into', 'over', 'between',
    'which', 'who', 'what', 'when', 'where', 'why', 'how', 'than', 'then',
    'have', 'has', 'had', 'does', 'will', 'would', 'should', 'could',
    'you', 'your', 'we', 'our', 'he', 'she', 'must', 'may', 'can',
  };

  // Quantity words that make poor cloze answers/distractors on their own.
  static const Set<String> _numberWords = {
    'hundred', 'thousand', 'million', 'billion', 'dozen', 'twenty',
    'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety',
  };

  /// Generates up to [_maxQuestions] MCQs from [lessonText]. Empty when the
  /// text is blank or has too few usable sentences.
  List<AiGeneratedQuestion> generateQuestions(String lessonText) {
    if (lessonText.trim().isEmpty) return [];

    final sentences = _usableSentences(lessonText);
    if (sentences.length < 2) return [];

    final rng = Random(lessonText.hashCode);
    final keyTerms = _keyTerms(sentences);

    final questions = <AiGeneratedQuestion>[];
    final used = <String>{};

    for (final s in sentences) {
      if (questions.length >= _maxQuestions) break;
      if (used.contains(s)) continue;
      final q = _definitionMcq(s, sentences, rng);
      if (q != null) {
        used.add(s);
        questions.add(q);
      }
    }

    for (final s in sentences) {
      if (questions.length >= _maxQuestions) break;
      if (used.contains(s)) continue;
      final q = _clozeMcq(s, keyTerms, rng);
      if (q != null) {
        used.add(s);
        questions.add(q);
      }
    }

    return questions;
  }

  /// Structure-aware sentence extraction. Notes are not prose: they carry
  /// heading/label lines, worked arithmetic, and activity instructions. Those
  /// must be removed BEFORE sentence splitting, or they fuse with real
  /// sentences ("Rules for divisibility: A number is divisible by 2…" made
  /// the question "What is Rules for divisibility: A number?").
  List<String> _usableSentences(String lessonText) {
    final cleanedLines = <String>[];
    for (var line in lessonText.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      // Decorative separators / vertical arithmetic ("---------", "+ 23,657").
      if (!RegExp(r'[A-Za-z]').hasMatch(line)) continue;
      // Label-only lines ("Key terms:", "Rules for rounding:", "BODMAS stands
      // for:") introduce what follows; they are not statements.
      if (line.endsWith(':')) continue;
      // Strip short leading labels ("Example: …", "Answer: …", "Activity 3: …")
      // so the sentence itself survives without the label fused on.
      final labelMatch = RegExp(r'^([^.!?:]{1,32}):\s+').firstMatch(line);
      if (labelMatch != null) {
        line = line.substring(labelMatch.end).trim();
        if (line.isEmpty) continue;
      }
      // Headings ("MATHEMATICS NOTES FOR PRIMARY SIX") are titles, not
      // teachable sentences — mostly-uppercase lines are dropped so they can
      // never become fill-in-the-blank questions.
      final upper = RegExp(r'[A-Z]').allMatches(line).length;
      final lower = RegExp(r'[a-z]').allMatches(line).length;
      if (upper + lower >= 3 && upper > 2 * lower) continue;
      cleanedLines.add(line);
    }

    return cleanedLines
        .join('\n')
        .split(_sentenceSplitter)
        .map((s) => s.trim())
        .where((s) {
      final words = s.split(_whitespace).where((w) => w.isNotEmpty).toList();
      if (words.length < 5 || words.length > 40) return false;
      // Worked arithmetic is practice, not teachable prose.
      if (s.contains('=')) return false;
      // Mostly digits → a calculation or data row, not a statement.
      final digits = RegExp(r'[0-9]').allMatches(s).length;
      final letters = RegExp(r'[A-Za-z]').allMatches(s).length;
      if (digits > 0 && digits * 2 >= letters) return false;
      // Instructions to the reader ("Round 89,365 to the nearest 100.").
      final first = words.first.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (_imperativeStarts.contains(first)) return false;
      return true;
    }).toList();
  }

  AiGeneratedQuestion? _definitionMcq(
      String sentence, List<String> all, Random rng) {
    String? verb;
    for (final v in _linkingVerbs) {
      if (sentence.contains(v)) {
        verb = v;
        break;
      }
    }
    if (verb == null) return null;

    final idx = sentence.indexOf(verb);
    final subject = sentence.substring(0, idx).trim();
    final rawPredicate =
        _stripTrailingDot(sentence.substring(idx + verb.length));

    // A question ("Why is food important?") is not a definition.
    if (sentence.trim().endsWith('?')) return null;

    // "X is Y if/when/unless Z" is a RULE, not a definition — "A number is
    // divisible by 2 if its last digit is even" does not define "a number".
    final predLow = ' ${rawPredicate.toLowerCase()} ';
    if (predLow.contains(' if ') ||
        predLow.contains(' when ') ||
        predLow.contains(' unless ')) {
      return null;
    }

    // A subject with a comma or colon is a clause or a fused label, never a
    // clean term ("Following BODMAS, addition and subtraction…").
    if (subject.contains(',') || subject.contains(':')) return null;

    final subjWords =
        subject.split(_whitespace).where((w) => w.isNotEmpty).toList();
    if (subjWords.isEmpty || subjWords.length > 6) return null;
    final firstWord =
        subjWords.first.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (_pronounSubjects.contains(firstWord) ||
        _interrogatives.contains(firstWord) ||
        _clauseLeadIns.contains(firstWord)) {
      return null;
    }
    // The subject must contain a real content word, not be made only of
    // stopwords / question words / numbers.
    final hasContentWord = subjWords.any((w) {
      final t = w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      return t.length >= 3 &&
          !_stopwords.contains(t) &&
          !_interrogatives.contains(t);
    });
    if (!hasContentWord) return null;

    final correct = _shortPhrase(rawPredicate, 12);
    if (!_isSpeakableOption(correct)) return null;

    final distractors =
        _pickLengthMatched(correct, _predicatePool(sentence, all), 3, rng);
    if (distractors.length < 3) return null;

    return _assemble(
      questionText: 'What ${verb.trim()} ${_shortPhrase(subject, 8)}?',
      correct: correct,
      wrongs: distractors,
      explanation: 'From your lesson: ${_truncate(sentence, 200)}',
      rng: rng,
    );
  }

  /// Distractor candidates: cleaned predicates of the OTHER sentences.
  /// Conditional rules are welcome here — clause-cutting turns "divisible by
  /// 2 if its last digit is even" into the short phrase "divisible by 2",
  /// which is a plausible, honest same-note distractor.
  List<String> _predicatePool(String exclude, List<String> all) {
    final candidates = <String>[];
    for (final other in all) {
      if (other == exclude) continue;
      // A question sentence ("How many litres were left?") has no predicate
      // worth borrowing — its tail is not a statement.
      if (other.trim().endsWith('?')) continue;
      String? ov;
      for (final v in _linkingVerbs) {
        if (other.contains(v)) {
          ov = v;
          break;
        }
      }
      if (ov == null) continue;
      final op = _shortPhrase(
          _stripTrailingDot(other.substring(other.indexOf(ov) + ov.length)),
          12);
      if (_isSpeakableOption(op)) candidates.add(op);
    }
    return _dedupe(candidates);
  }

  AiGeneratedQuestion? _clozeMcq(
      String sentence, List<String> keyTerms, Random rng) {
    if (sentence.trim().endsWith('?')) return null;
    final present = keyTerms
        .where((t) => RegExp('\\b${RegExp.escape(t)}\\b', caseSensitive: false)
            .hasMatch(sentence))
        .toList();
    if (present.isEmpty) return null;

    present.sort((a, b) => b.length.compareTo(a.length));
    final answer = present.first;

    final blanked = sentence.replaceFirst(
        RegExp('\\b${RegExp.escape(answer)}\\b', caseSensitive: false), 'blank');
    if (!blanked.toLowerCase().contains('blank')) return null;

    final others =
        keyTerms.where((t) => t.toLowerCase() != answer.toLowerCase()).toList();
    final distractors = _pickLengthMatched(answer, _dedupe(others), 3, rng);
    if (distractors.length < 3) return null;

    return _assemble(
      questionText: 'Fill in the blank. ${_truncate(blanked, 180)}',
      correct: answer,
      wrongs: distractors,
      explanation: 'From your lesson: ${_truncate(sentence, 200)}',
      rng: rng,
    );
  }

  /// Heuristic key terms (no NLP on device): capitalised words/sequences plus
  /// longer content words, used as cloze answers and distractors.
  List<String> _keyTerms(List<String> sentences) {
    final terms = <String>[];
    final seen = <String>{};
    final capSeq =
        RegExp(r'\b([A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+){0,2})\b');

    bool usable(String lowerKey) =>
        !_stopwords.contains(lowerKey) &&
        !_numberWords.contains(lowerKey) &&
        !_clauseLeadIns.contains(lowerKey);

    for (final s in sentences) {
      for (final m in capSeq.allMatches(s)) {
        var t = m.group(1)!.trim();
        // "In Primary Six" is one capitalised run, but "In" is not part of
        // the term — drop leading stopwords so the real term ("Primary Six")
        // survives instead of the whole run being used or discarded.
        var words = t.split(' ');
        while (words.isNotEmpty &&
            (_stopwords.contains(words.first.toLowerCase()) ||
                _clauseLeadIns.contains(words.first.toLowerCase()))) {
          words = words.sublist(1);
        }
        if (words.isEmpty) continue;
        t = words.join(' ');
        final key = t.toLowerCase();
        if (t.length >= 3 && usable(key) && seen.add(key)) {
          terms.add(t);
        }
      }
    }
    for (final s in sentences) {
      for (final w in s.split(RegExp(r'[^A-Za-z]+'))) {
        final key = w.toLowerCase();
        if (w.length >= 6 && usable(key) && seen.add(key)) {
          terms.add(w);
        }
      }
    }
    return terms;
  }

  static const List<String> _clauseBreaks = [
    '; ', ' which ', ' that ', ' where ',
    ' because ', ' so that ', ' in order ', ' such as ',
    ' if ', ' when ', ' unless ',
  ];

  String _shortPhrase(String text, int maxWords) {
    var t = _stripTrailingDot(text).trim();
    final low = t.toLowerCase();
    var cut = t.length;
    for (final sep in _clauseBreaks) {
      final i = low.indexOf(sep);
      // Only cut if at least 4 words precede the break, so we never reduce
      // "the process by which plants make food" to "the process by".
      if (i > 0 &&
          i < cut &&
          t.substring(0, i).split(_whitespace).length >= 4) {
        cut = i;
      }
    }
    // Commas cut earlier (2 words is enough): "the minuend, the number
    // subtracted is…" must stop at "the minuend".
    final commaIdx = t.indexOf(', ');
    if (commaIdx > 0 &&
        commaIdx < cut &&
        t.substring(0, commaIdx).split(_whitespace).length >= 2) {
      cut = commaIdx;
    }
    t = t.substring(0, cut).trim();
    final words = t.split(_whitespace);
    if (words.length > maxWords) t = words.take(maxWords).join(' ');
    return _balanceParens(t);
  }

  /// Never let a phrase end with a dangling parenthesis: an option read as
  /// "divisible by 2 if its last digit is even (0" is broken on screen and
  /// worse by ear. An unmatched "(" cuts the phrase before it; an unmatched
  /// ")" is dropped.
  String _balanceParens(String t) {
    final open = t.indexOf('(');
    if (open >= 0 && !t.substring(open).contains(')')) {
      t = t.substring(0, open);
    }
    if (t.contains(')') && !t.contains('(')) {
      t = t.replaceAll(')', ' ');
    }
    return t
        .replaceAll(_whitespace, ' ')
        .replaceAll(RegExp(r'[\s,;:\-]+$'), '')
        .trim();
  }

  /// True when the phrase contains at least one alphabetic word of 3+
  /// letters — "12 and 14" is not a speakable answer.
  bool _hasRealWord(String t) =>
      RegExp(r'[A-Za-z]{3,}').hasMatch(t.replaceAll(RegExp(r'\band\b'), ''));

  /// A quiz option must read as one clean phrase by ear. Rejects fragments
  /// the clause-cutter could not repair: leftover commas ("2, so yes" from a
  /// worked example), digit-led answers, and phrases ending on a dangling
  /// stopword ("…and its total value is").
  bool _isSpeakableOption(String t) {
    if (t.length < 3 || !_hasRealWord(t)) return false;
    if (t.contains(',')) return false;
    if (RegExp(r'^[0-9]').hasMatch(t)) return false;
    final words = t.split(_whitespace);
    final last = words.last.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (_stopwords.contains(last)) return false;
    return true;
  }

  List<String> _pickLengthMatched(
      String correct, List<String> candidates, int n, Random rng) {
    final target = correct.split(_whitespace).length;
    final pool = candidates
        .where((c) => c.toLowerCase().trim() != correct.toLowerCase().trim())
        .toList();
    pool.shuffle(rng);
    pool.sort((a, b) => (a.split(_whitespace).length - target)
        .abs()
        .compareTo((b.split(_whitespace).length - target).abs()));
    return pool.take(n).toList();
  }

  List<String> _dedupe(List<String> items) {
    final seen = <String>{};
    final out = <String>[];
    for (final it in items) {
      final key = it.toLowerCase().trim();
      if (key.isNotEmpty && seen.add(key)) out.add(it.trim());
    }
    return out;
  }

  AiGeneratedQuestion _assemble({
    required String questionText,
    required String correct,
    required List<String> wrongs,
    required String explanation,
    required Random rng,
  }) {
    final options = [correct, wrongs[0], wrongs[1], wrongs[2]];
    options.shuffle(rng);
    final correctIndex = options.indexOf(correct);
    final correctLetter = const ['A', 'B', 'C', 'D'][correctIndex];
    return AiGeneratedQuestion(
      questionText: questionText,
      optionA: options[0],
      optionB: options[1],
      optionC: options[2],
      optionD: options[3],
      correctOption: correctLetter,
      explanation: explanation,
    );
  }

  String _stripTrailingDot(String text) {
    var t = text.trim();
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1).trim();
    }
    return t;
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return text.substring(0, maxLength);
  }
}
