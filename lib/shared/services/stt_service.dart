import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as speech_to_text;

/// Global Speech-to-Text service for the AudioApp platform.
///
/// This is a clean abstraction layer that provides the full STT interface
/// without depending on any external STT package. Internally it uses a
/// [StreamController<String>] so the API is complete and testable today.
///
/// When the real `speech_to_text` package is added in a later phase, only
/// the internals of this file change — every call-site stays the same.
///
/// Typical usage:
///   1. Await [initialize] once (e.g. inside a Riverpod FutureProvider).
///   2. Call [startListening] when the microphone button is pressed.
///   3. Call [stopListening] when the button is released or a timeout fires.
///   4. During testing / UI development, call [injectWords] to simulate input.
///
/// Call [dispose] when the owning scope is destroyed to close the stream.
class SttService {
  // ──────────────────────────────────────────────────────────────
  // Internal stream infrastructure
  // ──────────────────────────────────────────────────────────────

  /// Broadcast so multiple listeners (e.g. UI + logging) can subscribe.
  final StreamController<String> _wordsController =
      StreamController<String>.broadcast();

  final speech_to_text.SpeechToText _speech = speech_to_text.SpeechToText();

  // ──────────────────────────────────────────────────────────────
  // Internal state
  // ──────────────────────────────────────────────────────────────

  bool _isListening = false;
  bool _isInitialized = false;
  bool _isAvailable = false;
  void Function()? _activeOnDone;

  // ──────────────────────────────────────────────────────────────
  // Public API — state
  // ──────────────────────────────────────────────────────────────

  /// Whether the service is currently in a listening session.
  bool get isListening => _isListening;

  /// Whether the speech engine initialized successfully.
  bool get isAvailable => _isAvailable;

  /// Raw word stream.
  ///
  /// Consumers can subscribe directly for reactive UI updates, or use
  /// [startListening] for a callback-based approach.
  ///
  /// Convention: an empty string emitted on this stream signals
  /// end-of-speech (equivalent to the STT engine's "done" event).
  Stream<String> get wordStream => _wordsController.stream;

  // ──────────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────────

  /// Initialises the STT back-end.
  ///
  /// Returns `true` when speech recognition is available on this device.
  Future<bool> initialize() async {
    if (_isInitialized) return _isAvailable;

    try {
      _isAvailable = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _finishListeningSession();
          }
        },
        onError: (error) {
            _finishListeningSession();
        },
      );
    } catch (_) {
      _isAvailable = false;
    }

    _isInitialized = true;
    return _isAvailable;
  }

  // ──────────────────────────────────────────────────────────────
  // Listening controls
  // ──────────────────────────────────────────────────────────────

  /// Starts a listening session.
  ///
  /// [onResult]  — called with each recognised word/phrase fragment.
  /// [onDone]    — called once when the session ends (stream emits `''`).
  ///
  /// Calling [startListening] while already listening is a no-op.
  void startListening({
    required void Function(String words) onResult,
    void Function()? onDone,
  }) {
    if (_isListening || !_isAvailable) return;

    _isListening = true;
    _activeOnDone = onDone;

    _speech.listen(
      onResult: (result) {
        final words = result.recognizedWords.trim();
        if (words.isNotEmpty) {
          onResult(words);
          if (!_wordsController.isClosed) {
            _wordsController.add(words);
          }
        }

        if (result.finalResult) {
          _finishListeningSession();
        }
      },
      listenFor: const Duration(seconds: 4),
      pauseFor: const Duration(seconds: 1),
      partialResults: true,
      cancelOnError: true,
      listenMode: speech_to_text.ListenMode.confirmation,
    );
  }

  /// Ends the current listening session.
  ///
  /// Safe to call even when not listening.
  Future<void> stopListening() async {
    _isListening = false;
    _activeOnDone = null;

    if (_isAvailable) {
      await _speech.stop();
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Testing / future STT hook-up
  // ──────────────────────────────────────────────────────────────

  /// Pushes [words] into the stream as if the STT engine recognised them.
  ///
  /// Two primary use cases:
  ///   1. **Unit / widget tests** — simulate voice input without a microphone.
  ///   2. **Phase 2 STT integration** — the real `speech_to_text` callback
  ///      simply calls `injectWords(result.recognizedWords)`, and everything
  ///      else in the app keeps working without changes.
  ///
  /// Pass an empty string to signal end-of-speech (triggers [onDone]).
  void injectWords(String words) {
    if (_wordsController.isClosed) return;
    _wordsController.add(words);
  }

  // ──────────────────────────────────────────────────────────────
  // Disposal
  // ──────────────────────────────────────────────────────────────

  /// Cancels any active subscription and closes the underlying stream.
  ///
  /// Must be called when the owning Riverpod scope or widget is destroyed.
  Future<void> dispose() async {
    _isListening = false;
    _activeOnDone = null;
    if (_isAvailable) {
      await _speech.stop();
    }
    await _wordsController.close();
  }

  void _finishListeningSession() {
    if (!_isListening) return;

    _isListening = false;
    if (!_wordsController.isClosed) {
      _wordsController.add('');
    }

    final callback = _activeOnDone;
    _activeOnDone = null;
    callback?.call();
  }
}
