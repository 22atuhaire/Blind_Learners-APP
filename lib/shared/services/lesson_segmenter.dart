/// One playback unit of a lesson: the [text] to speak and how long to pause
/// *after* it before the next unit. The pauses are what make synthesized
/// reading feel human — a short breath between sentences, a longer one after a
/// paragraph, and a clear beat after a heading before its body begins.
class LessonSegment {
  const LessonSegment({required this.text, required this.pauseAfter});

  final String text;
  final Duration pauseAfter;
}

// Pause lengths — short enough to stay engaging, long enough to feel human.
const Duration _sentencePause = Duration(milliseconds: 220);
const Duration _paragraphPause = Duration(milliseconds: 450);
const Duration _headingPause = Duration(milliseconds: 600);

/// Splits a lesson's raw text into natural playback segments with pauses.
///
/// Goals:
///  1. **Resume granularity** — break at sentence boundaries, grouped to a
///     comfortable length, so a paused lesson resumes near where it stopped.
///  2. **Natural rhythm** — a clear beat after a heading, a breath after a
///     paragraph, instead of one breathless block.
///  3. **Clean audio** — decorative separators (`====`, `----`) are dropped and
///     list bullets (`-`, `*`, `•`, `1.`) are stripped, so the engine never
///     reads "equals equals equals" or "dash" aloud.
///
/// Never returns an empty list for text that contains any spoken words.
List<LessonSegment> splitLessonIntoSegments(String text, {int targetLength = 300}) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return const [];

  final blocks = normalized
      .split(RegExp(r'\n[ \t]*\n+'))
      .map((b) => b.trim())
      .where((b) => b.isNotEmpty)
      .toList();

  final segments = <LessonSegment>[];

  for (final block in blocks) {
    final lines = block.split('\n');
    final paragraphBuffer = StringBuffer();

    void flushParagraph() {
      final para = paragraphBuffer.toString().trim();
      paragraphBuffer.clear();
      if (para.isEmpty) return;
      final parts = _groupSentences(para, targetLength);
      for (var i = 0; i < parts.length; i++) {
        final isLast = i == parts.length - 1;
        segments.add(LessonSegment(
          text: parts[i],
          pauseAfter: isLast ? _paragraphPause : _sentencePause,
        ));
      }
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (_isSeparator(line)) continue; // drop "====" / "----" decoration

      if (_isHeading(line)) {
        flushParagraph(); // close any body collected before this heading
        segments.add(LessonSegment(
          text: _clean(line),
          pauseAfter: _headingPause,
        ));
      } else {
        // Strip a leading list bullet so it isn't read as "dash"/"star", then
        // fold the line into the current paragraph so consecutive list items
        // read as a flowing list rather than choppy one-pause-each fragments.
        final cleaned = _clean(line);
        if (cleaned.isEmpty) continue;
        if (paragraphBuffer.isNotEmpty) paragraphBuffer.write(' ');
        paragraphBuffer.write(cleaned);
      }
    }
    flushParagraph();
  }

  if (segments.isEmpty) {
    // Everything was decoration/markers but there ARE words — speak them
    // plainly rather than returning nothing (which would skip the lesson).
    final fallback = _clean(normalized.replaceAll('\n', ' ')).trim();
    if (fallback.isEmpty) return const [];
    return _groupSentences(fallback, targetLength)
        .map((t) => LessonSegment(text: t, pauseAfter: _sentencePause))
        .toList();
  }

  // The very last segment shouldn't leave a trailing silence.
  final last = segments.removeLast();
  segments.add(LessonSegment(text: last.text, pauseAfter: Duration.zero));
  return segments;
}

/// Groups the sentences of one paragraph into chunks no longer than
/// [targetLength], breaking only at sentence boundaries so resume points and
/// pauses land naturally. Word-based so no spoken text is ever dropped.
List<String> _groupSentences(String paragraph, int targetLength) {
  final words = paragraph.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final chunks = <String>[];
  final buffer = StringBuffer();

  for (final word in words) {
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(word);
    final endsSentence =
        word.endsWith('.') || word.endsWith('!') || word.endsWith('?');
    if (buffer.length >= targetLength && endsSentence) {
      chunks.add(buffer.toString());
      buffer.clear();
    }
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString());
  return chunks.isEmpty ? [paragraph] : chunks;
}

/// A line made only of decoration (e.g. `==========`, `----`, `____`, `****`)
/// with no letters or digits — never spoken.
bool _isSeparator(String line) {
  return !RegExp(r'[A-Za-z0-9]').hasMatch(line);
}

/// True if the line begins with a list bullet (`-`, `*`, `•`) or an enumerator
/// (`1.`, `2)`), which means it is body/list content, not a heading.
bool _isListItem(String line) {
  return RegExp(r'^\s*([-*•]|\d+[.)])\s+').hasMatch(line);
}

/// Heuristic: a heading is a short, title-like line — a markdown heading, an
/// ALL-CAPS title, or a brief Title-style label — that is NOT a list item and
/// does not end like a sentence.
bool _isHeading(String line) {
  if (line.startsWith('#')) return true;
  if (_isListItem(line)) return false;

  final words = line.split(RegExp(r'\s+'));
  final endsLikeSentence = RegExp(r'[.!?,;]$').hasMatch(line);

  // ALL-CAPS title, e.g. "FOOD AND NUTRITION", "1. WHAT IS FOOD?".
  final letters = line.replaceAll(RegExp(r'[^A-Za-z]'), '');
  if (letters.length >= 3 &&
      letters == letters.toUpperCase() &&
      words.length <= 12) {
    return true;
  }

  // Short label with no sentence punctuation, e.g. "Introduction",
  // "Causes of Soil Erosion". Require at least a couple of letters so a bare
  // number or symbol isn't treated as a heading.
  if (line.length <= 50 &&
      words.length <= 7 &&
      !endsLikeSentence &&
      letters.length >= 3) {
    return true;
  }
  return false;
}

/// Strips markdown/heading decoration and leading list bullets so they aren't
/// spoken aloud.
String _clean(String line) {
  var t = line.replaceAll(RegExp(r'^#+\s*'), ''); // leading # markers
  t = t.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)])\s+'), ''); // list bullet
  t = t.replaceAll(RegExp(r'[*_`]'), ''); // emphasis markers
  return t.trim();
}
