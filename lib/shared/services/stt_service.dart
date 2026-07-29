import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as speech_to_text;

/// Global Speech-to-Text service for the AudioApp platform.
///
/// Wraps the `speech_to_text` package behind a small callback-based API so
/// every call-site stays decoupled from the engine's details.
///
/// Typical usage:
///   1. Await [initialize] once (e.g. inside a Riverpod FutureProvider).
///   2. Call [startListening] to open a listening window.
///   3. Call [stopListening] when done, or let it end on silence/timeout.
class SttService {
  final speech_to_text.SpeechToText _speech = speech_to_text.SpeechToText();

  bool _isListening = false;
  bool _isInitialized = false;
  bool _isAvailable = false;
  void Function()? _activeOnDone;
  void Function(String message)? _activeOnError;

  /// Whether the service is currently in a listening session.
  bool get isListening => _isListening;

  /// Whether the speech engine initialized successfully.
  bool get isAvailable => _isAvailable;

  /// Initialises the STT back-end. Returns `true` when recognition is available.
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
          // Surface the reason so callers can tell an ENGINE failure (busy,
          // client error, no network) from genuine silence. On low-end phones
          // these errors are common and need a different response: wait a beat
          // and retry the microphone, rather than immediately re-speaking the
          // whole prompt — which is what made the name prompt loop endlessly.
          _finishListeningSession(error: error.errorMsg);
        },
      );
    } catch (_) {
      _isAvailable = false;
    }

    _isInitialized = true;
    return _isAvailable;
  }

  /// Starts a listening session.
  ///
  /// [onResult]  - called ONCE with the complete, FINAL recognised phrase.
  /// [onPartial] - optional; called with each in-flight partial fragment.
  /// [onDone]    - called once when the session ends with nothing recognised.
  /// [onError]   - optional; called instead of [onDone] when the ENGINE failed
  ///               (busy, client error, no network), with the engine's message.
  ///               Omit it to keep the old behaviour of treating errors as
  ///               "nothing heard".
  /// [onDevice]  - prefer an installed on-device model (offline). Default false.
  ///
  /// Returns `false` when the session could not be started (engine unavailable,
  /// or one is already running) so a caller can fall back instead of waiting
  /// for callbacks that will never arrive.
  bool startListening({
    required void Function(String words) onResult,
    void Function(String words)? onPartial,
    void Function()? onDone,
    void Function(String message)? onError,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 8),
    bool onDevice = false,
  }) {
    if (_isListening || !_isAvailable) return false;

    _isListening = true;
    _activeOnDone = onDone;
    _activeOnError = onError;
    var deliveredFinal = false;

    _speech.listen(
      onResult: (result) {
        final words = result.recognizedWords.trim();

        if (result.finalResult) {
          if (words.isNotEmpty && !deliveredFinal) {
            deliveredFinal = true;
            // Final result delivered -> this session ends successfully, so
            // neither the "nothing heard" nor the error callback may fire
            // afterwards (some engines emit a trailing error after a result).
            _activeOnDone = null;
            _activeOnError = null;
            onResult(words);
          }
          _finishListeningSession();
          return;
        }

        if (words.isNotEmpty && onPartial != null) {
          onPartial(words);
        }
      },
      listenOptions: speech_to_text.SpeechListenOptions(
        listenFor: listenFor,
        pauseFor: pauseFor,
        partialResults: true,
        cancelOnError: true,
        listenMode: speech_to_text.ListenMode.confirmation,
        // When true, restricts recognition to an installed on-device model so
        // voice input keeps working with no internet. Defaults to false because
        // forcing on-device on a phone WITHOUT an offline pack makes listening
        // fail outright; callers opt in only where an offline pack is expected.
        // Offline-without-a-pack is covered by the gesture fallback regardless.
        onDevice: onDevice,
      ),
    );
    return true;
  }

  /// Ends the current listening session. Safe to call even when not listening.
  Future<void> stopListening() async {
    _isListening = false;
    _activeOnDone = null;
    _activeOnError = null;
    if (_isAvailable) {
      await _speech.stop();
    }
  }

  /// Stops any active session and releases the engine.
  Future<void> dispose() async {
    _isListening = false;
    _activeOnDone = null;
    _activeOnError = null;
    if (_isAvailable) {
      await _speech.stop();
    }
  }

  /// Ends the active session exactly once, routing to [_activeOnError] when the
  /// engine failed and a caller asked for errors, otherwise to [_activeOnDone].
  ///
  /// Callers that don't pass an `onError` keep the previous behaviour — an
  /// engine error still arrives as "done" — so existing screens are unaffected.
  void _finishListeningSession({String? error}) {
    if (!_isListening) return;

    _isListening = false;

    final onDone = _activeOnDone;
    final onError = _activeOnError;
    _activeOnDone = null;
    _activeOnError = null;

    if (error != null && onError != null) {
      onError(error);
    } else {
      onDone?.call();
    }
  }
}
