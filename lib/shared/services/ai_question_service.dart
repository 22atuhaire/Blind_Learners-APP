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

/// One sentence kept from a note, tagged with the section it came from.
class _ScannedSentence {
  const _ScannedSentence(this.text, this.section);
  final String text;
  final int section;
}

/// A question the generator could ask, before selection decides whether it
/// earns one of the quiz's limited slots.
class _Candidate {
  const _Candidate(this.index, this.section, this.question, this.head);
  final int index;
  final int section;
  final AiGeneratedQuestion question;
  final String head;
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
  // Quiz length scales with how much the note actually covers. A fixed cap of
  // five spent every slot on a note's opening section: the evaluation harness
  // (eval/) measured five questions about nouns in a Parts of Speech note that
  // never reached verbs, adjectives or adverbs. A longer chapter earns a
  // longer quiz, exactly as a teacher would set one.
  static const int _minQuestions = 5;
  static const int _maxQuestionsCap = 8;

  static int _questionBudget(int sentenceCount) {
    final scaled = _minQuestions + ((sentenceCount - 20) ~/ 6);
    if (scaled < _minQuestions) return _minQuestions;
    if (scaled > _maxQuestionsCap) return _maxQuestionsCap;
    return scaled;
  }

  static final RegExp _sentenceSplitter = RegExp(r'(?<=[.!?])\s+|\n+');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _bulletPrefix = RegExp(r'^\s*(?:[-*•]|\d+[.)])\s+');

  /// "X is Y if/when Z" — a curriculum RULE. Not a definition, but very much
  /// worth testing ("A number is divisible by 2 if its last digit is even").
  static final RegExp _rulePattern = RegExp(
      r'^(.{3,60}?)\s(is|are)\s(.{3,80}?)\s(?:if|when)\s(.{5,90})$',
      caseSensitive: false);

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

  /// Generates MCQs from [lessonText] — between [_minQuestions] and
  /// [_maxQuestionsCap], scaled to how much the note covers. Empty when the
  /// text is blank or has too few usable sentences.
  List<AiGeneratedQuestion> generateQuestions(String lessonText) {
    if (lessonText.trim().isEmpty) return [];

    final scanned = _scanSentences(lessonText);
    if (scanned.length < 2) return [];

    final sentences = scanned.map((e) => e.text).toList();
    final rng = Random(lessonText.hashCode);
    final keyTerms = _keyTerms(sentences);
    final budget = _questionBudget(scanned.length);

    // Build every candidate first, then CHOOSE across the note. Selecting the
    // first N in reading order clustered the whole quiz in section one.
    final candidates = <_Candidate>[];
    for (var i = 0; i < scanned.length; i++) {
      final s = scanned[i].text;
      final q = _definitionMcq(s, sentences, rng) ?? _ruleMcq(s, sentences, rng);
      if (q != null) {
        candidates.add(_Candidate(i, scanned[i].section, q, _subjectHead(q)));
      }
    }

    final chosen = <int, AiGeneratedQuestion>{};
    final usedSections = <int>{};
    final usedHeads = <String>{};

    // Pass 1 — at most one question per section, and never two questions about
    // the same head noun ("common noun", "proper noun", "collective noun"…).
    for (final c in candidates) {
      if (chosen.length >= budget) break;
      if (usedSections.contains(c.section)) continue;
      if (c.head.isNotEmpty && usedHeads.contains(c.head)) continue;
      usedSections.add(c.section);
      if (c.head.isNotEmpty) usedHeads.add(c.head);
      chosen[c.index] = c.question;
    }
    // Pass 2 — slots left: allow a second question per section, new heads only.
    for (final c in candidates) {
      if (chosen.length >= budget) break;
      if (chosen.containsKey(c.index)) continue;
      if (c.head.isNotEmpty && usedHeads.contains(c.head)) continue;
      if (c.head.isNotEmpty) usedHeads.add(c.head);
      chosen[c.index] = c.question;
    }

    // Fill any remainder with clozes, but only over sentences that actually
    // state something. Without this guard a list-heavy note produced
    // "Cows, goats, ____, dogs" — content-bound, and pedagogically worthless.
    if (chosen.length < budget) {
      for (var i = 0; i < scanned.length; i++) {
        if (chosen.length >= budget) break;
        if (chosen.containsKey(i)) continue;
        if (!_isStatement(scanned[i].text)) continue;
        final q = _clozeMcq(scanned[i].text, keyTerms, rng);
        if (q != null) chosen[i] = q;
      }
    }

    final orderedIndices = chosen.keys.toList()..sort();
    return [for (final i in orderedIndices) chosen[i]!];
  }

  /// The head noun of a generated question's subject, used to stop a quiz
  /// asking five variations of the same thing.
  String _subjectHead(AiGeneratedQuestion q) {
    final m = RegExp(r'^(?:What|When) (?:is|are) (.+?)\??$', caseSensitive: false)
        .firstMatch(q.questionText);
    if (m == null) return '';
    final words = m
        .group(1)!
        .split(_whitespace)
        .map((w) => w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''))
        .where((w) => w.isNotEmpty && !_stopwords.contains(w))
        .toList();
    return words.isEmpty ? '' : words.last;
  }

  /// A sentence worth blanking: it asserts something, rather than listing
  /// examples separated by commas.
  bool _isStatement(String s) {
    final hasVerb = _linkingVerbs.any(s.contains) ||
        s.contains(' means ') ||
        s.contains(' called ') ||
        s.contains(' used ') ||
        s.contains(' has ') ||
        s.contains(' have ');
    if (!hasVerb) return false;
    if (','.allMatches(s).length >= 2 && !_linkingVerbs.any(s.contains)) {
      return false;
    }
    return true;
  }

  /// Structure-aware sentence extraction. Notes are not prose: they carry
  /// heading/label lines, worked arithmetic, and activity instructions. Those
  /// must be removed BEFORE sentence splitting, or they fuse with real
  /// sentences ("Rules for divisibility: A number is divisible by 2…" made
  /// the question "What is Rules for divisibility: A number?").
  List<_ScannedSentence> _scanSentences(String lessonText) {
    // Pass 1 — clean lines, and record which SECTION each belongs to. The
    // heading lines we already discard are exactly the topic boundaries, so
    // tracking them lets the quiz spread one question per topic.
    final kept = <_ScannedSentence>[];
    var section = 0;
    for (var line in lessonText.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      // Decorative separators / vertical arithmetic ("---------", "+ 23,657").
      if (!RegExp(r'[A-Za-z]').hasMatch(line)) continue;
      // Table rows are data, not prose, and they start a new topic block.
      if ('|'.allMatches(line).length >= 2) {
        section++;
        continue;
      }
      // Label-only lines ("Key terms:", "Rules for rounding:") introduce what
      // follows; they are not statements, but they DO start a sub-topic.
      if (line.endsWith(':')) {
        section++;
        continue;
      }
      // Headings ("MATHEMATICS NOTES FOR PRIMARY SIX") are titles, not
      // teachable sentences — and they mark a new topic.
      final upper = RegExp(r'[A-Z]').allMatches(line).length;
      final lower = RegExp(r'[a-z]').allMatches(line).length;
      if (upper + lower >= 3 && upper > 2 * lower) {
        section++;
        continue;
      }
      // A numbered section start ("3. ROUNDING OFF NUMBERS").
      if (RegExp(r'^\d+\.\s+[A-Z]').hasMatch(line)) section++;
      // Strip a list bullet so the sentence isn't read as "- They provide…".
      line = line.replaceFirst(_bulletPrefix, '');
      // Strip short leading labels ("Example: …", "Answer: …", "Activity 3: …")
      // so the sentence itself survives without the label fused on.
      final labelMatch = RegExp(r'^([^.!?:]{1,32}):\s+').firstMatch(line);
      if (labelMatch != null) {
        line = line.substring(labelMatch.end).trim();
        if (line.isEmpty) continue;
      }
      if (line.isEmpty) continue;

      // Pass 2 — split the surviving line into sentences and filter.
      for (final raw in line.split(_sentenceSplitter)) {
        final s = raw.trim();
        final words = s.split(_whitespace).where((w) => w.isNotEmpty).toList();
        if (words.length < 5 || words.length > 40) continue;
        // Worked arithmetic / table remnants are practice, not teachable prose.
        if (s.contains('=') || s.contains('|')) continue;
        // Mostly digits → a calculation or data row, not a statement.
        final digits = RegExp(r'[0-9]').allMatches(s).length;
        final letters = RegExp(r'[A-Za-z]').allMatches(s).length;
        if (digits > 0 && digits * 2 >= letters) continue;
        // Instructions to the reader ("Round 89,365 to the nearest 100.").
        final first =
            words.first.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
        if (_imperativeStarts.contains(first)) continue;
        kept.add(_ScannedSentence(s, section));
      }
    }
    return kept;
  }

  /// Turns a curriculum rule into a question: "A number is divisible by 2 if
  /// its last digit is even" → "When is a number divisible by 2?".
  /// Rules are explicitly rejected by [_definitionMcq] (they do not define
  /// their subject), but they carry much of what a syllabus actually tests,
  /// so they get their own pattern rather than being thrown away.
  AiGeneratedQuestion? _ruleMcq(String sentence, List<String> all, Random rng) {
    final m = _rulePattern.firstMatch(_stripTrailingDot(sentence));
    if (m == null) return null;

    final subject = m.group(1)!.trim();
    final verb = m.group(2)!.toLowerCase();
    final predicate = m.group(3)!.trim();
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

    final correct = _shortPhrase(m.group(4)!, 12);
    if (!_isSpeakableOption(correct)) return null;

    // Distractors are the CONDITIONS of the note's other rules — same register,
    // same length, and genuinely wrong for this rule.
    final pool = <String>[];
    for (final other in all) {
      if (other == sentence) continue;
      final om = _rulePattern.firstMatch(_stripTrailingDot(other));
      if (om == null) continue;
      final cond = _shortPhrase(om.group(4)!, 12);
      if (_isSpeakableOption(cond) &&
          cond.toLowerCase() != correct.toLowerCase()) {
        pool.add(cond);
      }
    }
    final distractors = _pickLengthMatched(correct, _dedupe(pool), 3, rng);
    if (distractors.length < 3) return null;

    return _assemble(
      questionText:
          'When $verb ${_shortPhrase(subject, 8)} ${_shortPhrase(predicate, 8)}?',
      correct: correct,
      wrongs: distractors,
      explanation: 'From your lesson: ${_truncate(sentence, 200)}',
      rng: rng,
    );
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
