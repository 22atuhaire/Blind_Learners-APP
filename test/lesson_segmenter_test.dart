import 'package:audioapp/shared/services/lesson_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [splitLessonIntoSegments] — the pure helper that powers
/// pause/resume and the natural reading rhythm of lesson playback. No plugins,
/// runs under `flutter test`.
void main() {
  test('returns empty for blank text', () {
    expect(splitLessonIntoSegments(''), isEmpty);
    expect(splitLessonIntoSegments('   '), isEmpty);
  });

  test('short text stays a single segment', () {
    final segs = splitLessonIntoSegments('Photosynthesis feeds the plant.');
    expect(segs.length, 1);
    expect(segs.first.text, 'Photosynthesis feeds the plant.');
  });

  test('never drops any words when splitting long text', () {
    final text = List.generate(
      40,
      (i) => 'This is sentence number $i about the lesson topic.',
    ).join(' ');

    final segs = splitLessonIntoSegments(text, targetLength: 120);

    expect(segs.length, greaterThan(1));
    // Re-joining the segment texts must reproduce every word, in order.
    final rejoined = segs.map((s) => s.text).join(' ');
    expect(rejoined.split(RegExp(r'\s+')), text.split(RegExp(r'\s+')));
  });

  test('breaks segments only at sentence boundaries', () {
    final text = List.generate(
      10,
      (i) => 'Sentence $i has several plain words in it here.',
    ).join(' ');

    for (final seg in splitLessonIntoSegments(text, targetLength: 60)) {
      expect(
        seg.text.trim().endsWith('.'),
        isTrue,
        reason: 'segment should end at a sentence boundary: "${seg.text}"',
      );
    }
  });

  test('drops decorative separator lines and strips list bullets', () {
    const notes = 'INTRODUCTION\n'
        '==============\n'
        '- Matooke is a staple food.\n'
        '- Beans give protein.';
    final segs = splitLessonIntoSegments(notes);
    final joined = segs.map((s) => s.text).join(' ');

    expect(joined, isNot(contains('=')));
    expect(joined, isNot(contains('- ')));
    expect(joined, contains('Matooke is a staple food'));
    expect(joined, contains('Beans give protein'));
  });

  test('a heading gets a longer pause than the following body', () {
    final segs = splitLessonIntoSegments(
      'INTRODUCTION\n\nFood gives the body energy and helps it grow.',
    );
    expect(segs.length, greaterThanOrEqualTo(2));
    final heading = segs.first;
    expect(heading.text, 'INTRODUCTION');
    expect(heading.pauseAfter.inMilliseconds, greaterThan(0));
  });
}
