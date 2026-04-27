import 'dart:async';

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

  /// Active subscription created by [startListening]; cancelled by
  /// [stopListening] or when the stream emits an empty string.
  StreamSubscription<String>? _subscription;

  // ──────────────────────────────────────────────────────────────
  // Internal state
  // ──────────────────────────────────────────────────────────────

  bool _isListening = false;

  // ──────────────────────────────────────────────────────────────
  // Public API — state
  // ──────────────────────────────────────────────────────────────

  /// Whether the service is currently in a listening session.
  bool get isListening => _isListening;

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
  /// Currently a stub that always returns `true` (ready).
  /// When the real `speech_to_text` package is wired up, this method will
  /// call `SpeechToText.initialize()` and return its result.
  Future<bool> initialize() async {
    // Stub — replace body with real initialisation in Phase 2.
    return true;
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
    if (_isListening) return;

    _isListening = true;

    _subscription = _wordsController.stream.listen(
      (words) {
        if (words.isEmpty) {
          // Empty string is the end-of-speech sentinel.
          _isListening = false;
          _subscription?.cancel();
          _subscription = null;
          onDone?.call();
        } else {
          onResult(words);
        }
      },
      onError: (_) {
        // Absorb stream errors so they never propagate uncaught to the UI.
        _isListening = false;
        _subscription?.cancel();
        _subscription = null;
      },
      onDone: () {
        // Stream was closed (e.g. dispose was called mid-session).
        _isListening = false;
        _subscription = null;
      },
      cancelOnError: true,
    );
  }

  /// Ends the current listening session.
  ///
  /// Safe to call even when not listening.
  Future<void> stopListening() async {
    _isListening = false;
    await _subscription?.cancel();
    _subscription = null;
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
    await _subscription?.cancel();
    _subscription = null;
    await _wordsController.close();
  }
}
