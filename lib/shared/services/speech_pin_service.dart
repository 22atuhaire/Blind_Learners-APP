import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Helper that wraps `flutter_tts` and `speech_to_text` to listen for single
/// digit utterances and speak prompts. Designed for a per-digit conversational
/// flow used by blind users.
class SpeechPinService {
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _stt.initialize();
    _initialized = true;
  }

  Future<void> speak(String text) async {
    await _tts.speak(text);
    // Optionally wait until speaking finishes; FlutterTts may not provide a
    // reliable completion callback across all platforms, so add a short delay
    // after speak to avoid immediate listening in some edge cases.
    await Future.delayed(const Duration(milliseconds: 250));
  }

  /// Listens once and attempts to parse a single digit (0-9) from the first
  /// recognition result. Returns the digit as a string, or null if nothing
  /// recognised within [timeoutSeconds].
  Future<String?> listenOnceForDigit({int timeoutSeconds = 5}) async {
    final completer = Completer<String?>();

    if (!await _stt.initialize()) {
      completer.complete(null);
      return completer.future;
    }

    Timer? timeout;

    void resultHandler(dynamic result) {
      if ((result.finalResult ?? false) && !completer.isCompleted) {
        final text = result.recognizedWords as String? ?? '';
        final digit = _normalizeTranscriptToDigit(text);
        completer.complete(digit);
        timeout?.cancel();
        _stt.stop();
      }
    }

    await _stt.listen(
        onResult: resultHandler, listenFor: Duration(seconds: timeoutSeconds));

    timeout = Timer(Duration(seconds: timeoutSeconds + 1), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        _stt.stop();
      }
    });

    return completer.future;
  }

  /// Converts a recognized phrase into a single digit string, or returns null.
  /// Handles common homophones and numeric words.
  String? _normalizeTranscriptToDigit(String transcript) {
    final t = transcript.trim().toLowerCase();
    if (t.isEmpty) return null;

    // Direct numeric characters
    final numeric = RegExp(r'\d');
    final m = numeric.firstMatch(t);
    if (m != null) return m.group(0);

    // Word -> digit map for common forms
    const map = {
      'zero': '0',
      'oh': '0',
      'one': '1',
      'won': '1',
      'two': '2',
      'to': '2',
      'too': '2',
      'three': '3',
      'four': '4',
      'for': '4',
      'fore': '4',
      'five': '5',
      'six': '6',
      'seven': '7',
      'eight': '8',
      'ate': '8',
      'nine': '9',
    };

    // Some transcribers output multiple words; pick the last plausible token.
    final tokens = t
        .split(RegExp(r'\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (var i = tokens.length - 1; i >= 0; i--) {
      final tok = tokens[i];
      if (map.containsKey(tok)) return map[tok];
    }

    return null;
  }
}
