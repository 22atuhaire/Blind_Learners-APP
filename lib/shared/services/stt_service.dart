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
          _finishListeningSession();
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
  /// [onDevice]  - prefer an installed on-device model (offline). Default false.
  ///
  /// Calling [startListening] while already listening is a no-op.
  void startListening({
    required void Function(String words) onResult,
    void Function(String words)? onPartial,
    void Function()? onDone,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 8),
    bool onDevice = false,
  }) {
    if (_isListening || !_isAvailable) return;

    _isListening = true;
    _activeOnDone = onDone;
    var deliveredFinal = false;

    _speech.listen(
      onResult: (result) {
        final words = result.recognizedWords.trim();

        if (result.finalResult) {
          if (words.isNotEmpty && !deliveredFinal) {
            deliveredFinal = true;
            // Final result delivered -> this session ends successfully, so the
            // "nothing heard" callback must not fire afterwards.
            _activeOnDone = null;
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
  }

  /// Ends the current listening session. Safe to call even when not listening.
  Future<void> stopListening() async {
    _isListening = false;
    _activeOnDone = null;
    if (_isAvailable) {
      await _speech.stop();
    }
  }

  /// Stops any active session and releases the engine.
  Future<void> dispose() async {
    _isListening = false;
    _activeOnDone = null;
    if (_isAvailable) {
      await _speech.stop();
    }
  }

  void _finishListeningSession() {
    if (!_isListening) return;

    _isListening = false;

    final callback = _activeOnDone;
    _activeOnDone = null;
    callback?.call();
  }
}
