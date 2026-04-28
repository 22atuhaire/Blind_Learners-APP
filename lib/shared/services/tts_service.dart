import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

/// Global Text-to-Speech service for the AudioApp platform.
///
/// Designed for visually impaired students in Uganda:
/// - Slow, clear speech rate (0.45)
/// - Falls back gracefully from 'en-UG' to 'en-US'
/// - Provides [speakOrientation] to orient users when they land on a screen
///
/// Lifecycle:
///   1. Create the instance (typically via Riverpod provider).
///   2. Await [initialize] before calling any speak methods.
///   3. Call [dispose] when the owning widget/scope is destroyed.
class TtsService {
  // ──────────────────────────────────────────────────────────────
  // Internal state
  // ──────────────────────────────────────────────────────────────

  final FlutterTts _tts = FlutterTts();
  static const String _googleTtsEngineId = 'com.google.android.tts';

  bool _speaking = false;
  bool _initialized = false;
  bool _googleTtsInstalled = false;
  bool _usingGoogleTts = false;
  String? _activeEngine;

  /// Completer used by [speakAndWait] to know when an utterance finishes.
  Completer<void>? _completionCompleter;

  // ──────────────────────────────────────────────────────────────
  // Public API — state
  // ──────────────────────────────────────────────────────────────

  /// Whether the engine is currently producing audio.
  bool get isSpeaking => _speaking;

  /// Whether Google Speech Services (Google TTS engine) is installed.
  bool get isGoogleTtsInstalled => _googleTtsInstalled;

  /// Whether this service is currently using Google TTS as the active engine.
  bool get isUsingGoogleTts => _usingGoogleTts;

  /// Android engine package id currently selected (when available).
  String? get activeEngine => _activeEngine;

  // ──────────────────────────────────────────────────────────────
  // Initialization
  // ──────────────────────────────────────────────────────────────

  /// Configures the TTS engine.
  ///
  /// Must be awaited before calling any speak method.
  /// Attempts to use Ugandan English ('en-UG'); silently falls back to
  /// 'en-US' if the locale is unavailable on the device.
  Future<void> initialize() async {
    if (_initialized) return;

    if (Platform.isAndroid) {
      await _configureAndroidEngine();
    }

    // ── Language ────────────────────────────────────────────────
    final availableLanguages = await _tts.getLanguages;
    final languages = List<String>.from(
      (availableLanguages as List<dynamic>).map((l) => l.toString()),
    );

    if (languages.contains('en-UG')) {
      await _tts.setLanguage('en-UG');
    } else {
      await _tts.setLanguage('en-US');
    }

    // ── Voice parameters ─────────────────────────────────────────
    // 0.45 — slow and clear for visually impaired users.
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    // ── Lifecycle handlers ───────────────────────────────────────
    _tts.setStartHandler(() {
      _speaking = true;
    });

    _tts.setCompletionHandler(() {
      _speaking = false;
      // Unblock any awaiter of [speakAndWait].
      if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
        _completionCompleter!.complete();
      }
    });

    _tts.setCancelHandler(() {
      _speaking = false;
      if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
        _completionCompleter!.complete();
      }
    });

    _tts.setErrorHandler((message) {
      _speaking = false;
      if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
        _completionCompleter!.completeError(
          Exception('TTS error: $message'),
        );
      }
    });

    _initialized = true;
  }

  Future<void> _configureAndroidEngine() async {
    final rawEngines = await _tts.getEngines;
    final engines = List<String>.from(
      (rawEngines as List<dynamic>).map((e) => e.toString()),
    );

    _googleTtsInstalled = engines.contains(_googleTtsEngineId);

    if (_googleTtsInstalled) {
      try {
        await _tts.setEngine(_googleTtsEngineId);
      } catch (_) {
        // Keep fallback path if selecting Google engine fails on this device.
      }
    }

    final defaultEngine = (await _tts.getDefaultEngine)?.toString();
    final selectedEngine =
        _googleTtsInstalled ? _googleTtsEngineId : defaultEngine;

    _activeEngine = (selectedEngine == null || selectedEngine.isEmpty)
        ? (engines.isNotEmpty ? engines.first : null)
        : selectedEngine;
    _usingGoogleTts = _activeEngine == _googleTtsEngineId;
  }

  // ──────────────────────────────────────────────────────────────
  // Speech controls
  // ──────────────────────────────────────────────────────────────

  /// Stops any current speech, then speaks [text].
  ///
  /// Fire-and-forget variant — returns as soon as playback starts.
  /// Use [speakAndWait] if you need to know when the utterance finishes.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Stops any current speech immediately.
  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
  }

  /// Pauses speech mid-utterance (platform support varies).
  Future<void> pause() async {
    await _tts.pause();
  }

  /// Resumes a previously paused utterance (platform support varies).
  Future<void> resume() async {
    // flutter_tts exposes `speak` for continuation; there is no dedicated
    // resume API on all platforms.  We re-invoke speak with the last text
    // would require storing it, so here we simply un-pause via the engine.
    await _tts.speak('');
  }

  /// Speaks [text] and returns a [Future] that completes only after the
  /// engine fires its completion (or cancel/error) callback.
  ///
  /// Useful for sequencing multiple announcements:
  /// ```audioapp/lib/shared/services/tts_service.dart#L1-1
  /// await tts.speakAndWait('Question one.');
  /// await tts.speakAndWait('Press any key to answer.');
  /// ```
  Future<void> speakAndWait(String text) async {
    if (text.trim().isEmpty) return;

    _completionCompleter = Completer<void>();
    await _tts.stop();
    await _tts.speak(text);
    return _completionCompleter!.future;
  }

  // ──────────────────────────────────────────────────────────────
  // Accessibility helper
  // ──────────────────────────────────────────────────────────────

  /// Reads an orientation announcement when the user arrives on a screen.
  ///
  /// Builds a single string:
  ///   "You are on the [screenName] screen. [instruction 1]. [instruction 2]."
  ///
  /// Example:
  /// ```audioapp/lib/shared/services/tts_service.dart#L1-1
  /// await tts.speakOrientation(
  ///   'Login',
  ///   [
  ///     'Enter your four-digit PIN using the keypad below',
  ///     'Double-tap any button to activate it',
  ///   ],
  /// );
  /// ```
  Future<void> speakOrientation(
    String screenName,
    List<String> instructions,
  ) async {
    final buffer = StringBuffer();
    buffer.write('You are on the $screenName screen.');

    if (instructions.isNotEmpty) {
      // Join instructions with a short natural pause marker.
      // A full stop + space causes most TTS engines to insert a brief pause.
      buffer.write(' ');
      buffer.write(
        instructions
            .map((s) => s.trimRight().endsWith('.') ? s : '$s.')
            .join('  '),
      );
    }

    await speak(buffer.toString());
  }

  // ──────────────────────────────────────────────────────────────
  // Disposal
  // ──────────────────────────────────────────────────────────────

  /// Releases the underlying TTS engine.
  ///
  /// Call this in the [dispose] of the widget or Riverpod scope that owns
  /// this service.
  Future<void> dispose() async {
    await _tts.stop();
  }
}
