import 'dart:math' as math;

/// Answers a student's spoken question using ONLY the current lesson's text.
///
/// This is a small, offline, deterministic retrieval engine (a TF-IDF-style
/// ranking over the lesson's own sentences). It never invents facts - it just
/// reads back the lesson sentence(s) most relevant to the question. This is the
/// content-bound, no-hallucination approach the project requires, and it works
/// with no internet (the only online dependency is speech-to-text, which has
/// the gesture fallback like everything else).
class QuestionAnswerService {
  static final RegExp _tokenizer = RegExp(r'[a-z0-9]+');
  static final RegExp _sentenceSplit = RegExp(r'(?<=[.!?])\s+');

  static const Set<String> _stopwords = {
    'the', 'a', 'an', 'and', 'or', 'but', 'of', 'to', 'in', 'on', 'at', 'for',
    'with', 'as', 'by', 'from', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'it', 'its', 'this', 'that', 'these', 'those', 'they', 'them',
    'there', 'here', 'what', 'which', 'who', 'whom', 'whose', 'when', 'where',
    'why', 'how', 'do', 'does', 'did', 'can', 'could', 'would', 'should',
    'will', 'shall', 'may', 'might', 'must', 'have', 'has', 'had', 'i', 'you',
    'he', 'she', 'we', 'me', 'my', 'your', 'about', 'tell', 'explain', 'mean',
    'means', 'meaning', 'please', 'question', 'again',
  };

  /// Returns the best 1-2 lesson sentences for [question], or null when nothing
  /// in the lesson is relevant.
  String? answer(String question, String lessonText) {
    final sentences = lessonText
        .split(_sentenceSplit)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (sentences.isEmpty) return null;

    final qTokens = _content(question);
    if (qTokens.isEmpty) return null;

    // Per-sentence token sets + document frequency for IDF weighting.
    final sentTokens = sentences.map(_content).map((l) => l.toSet()).toList();
    final df = <String, int>{};
    for (final toks in sentTokens) {
      for (final t in toks) {
        df[t] = (df[t] ?? 0) + 1;
      }
    }
    final n = sentences.length;

    final scores = List<double>.filled(sentences.length, 0);
    for (var i = 0; i < sentences.length; i++) {
      double score = 0;
      for (final qt in qTokens.toSet()) {
        if (sentTokens[i].contains(qt)) {
          // Rare words (low df) are more informative -> higher weight.
          final idf = math.log(1 + n / (df[qt] ?? 1));
          score += idf;
        }
      }
      if (score > 0) {
        // Mild length normalisation so a long sentence doesn't win just by
        // containing more words.
        score = score / (1 + math.log(1 + sentTokens[i].length));
      }
      scores[i] = score;
    }

    // Best sentence.
    var bestIdx = -1;
    var best = 0.0;
    for (var i = 0; i < scores.length; i++) {
      if (scores[i] > best) {
        best = scores[i];
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return null;

    // Optionally append the next-best *adjacent* sentence for context, when it
    // is also clearly relevant - one extra sentence is still listenable.
    final parts = <String>[sentences[bestIdx]];
    var secondIdx = -1;
    var second = 0.0;
    for (var i = 0; i < scores.length; i++) {
      if (i == bestIdx) continue;
      if (scores[i] > second) {
        second = scores[i];
        secondIdx = i;
      }
    }
    if (secondIdx >= 0 && second >= best * 0.6) {
      // Keep reading order.
      if (secondIdx < bestIdx) {
        parts.insert(0, sentences[secondIdx]);
      } else {
        parts.add(sentences[secondIdx]);
      }
    }

    return parts.join(' ');
  }

  List<String> _content(String text) {
    return _tokenizer
        .allMatches(text.toLowerCase())
        .map((m) => m.group(0)!)
        .where((t) => t.length >= 2 && !_stopwords.contains(t))
        .toList();
  }
}
