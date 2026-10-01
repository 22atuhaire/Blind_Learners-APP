import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Character offset, within the text passed to the current [speak] call, of
  /// the word currently being spoken. Updated by the engine's progress
  /// callback; read right after a [stop] to learn where playback was paused.
  int _spokenWordStart = 0;

  /// Where, within the most recently spoken text, the engine had reached when
  /// it last produced audio. 0 when the engine never reported progress (so
  /// callers resume from the start of what they last asked to speak).
  int get spokenWordStart => _spokenWordStart;

  /// Set by [stop] to break out of [speakAndWait]'s chunk loop — without
  /// this, stopping a long lesson mid-playback only silences the current
  /// chunk; the loop would otherwise move on and start speaking the next
  /// one, making "stop"/pause feel like it doesn't work.
  bool _cancelled = false;

  /// Monotonic token identifying the CURRENT speech request. Every [speak],
  /// [speakAndWait], and [stop] bumps it; an in-flight call whose token is no
  /// longer current yields the engine to the newer request instead of fighting
  /// it.
  ///
  /// This serialises ALL access to the single native TTS engine. The hub has
  /// many independent async "speak flows" (state announcements, lesson
  /// playback, speed-change, ask-a-question) that share this one engine; when
  /// two overlapped, they interleaved stop()/speak() on it in rapid
  /// succession, which the student hears as chopped, garbled noise. With this
  /// guard the latest request always wins cleanly and every utterance either
  /// plays to the end or is superseded exactly once — no thrash, no matter how
  /// callers race. Keeping this here (not in the callers) is what stops the
  /// bug from returning each time a new spoken feature is added.
  int _generation = 0;

  /// Current speech rate (0.0-1.0). Adjustable at runtime via
  /// [increaseRate]/[decreaseRate] so a student can ask for slower/faster
  /// playback, and persisted so the chosen speed survives app restarts —
  /// before persistence, every launch silently reset students back to the
  /// default they had just struggled with.
  ///
  /// The step used to be 0.05, which is barely audible — students reported
  /// that "slower" changed almost nothing. 0.10 per step is a clearly
  /// noticeable change, and the floor of 0.20 is genuinely slow enough for
  /// comprehension of dense lesson notes.
  double _speechRate = 0.40;
  double get speechRate => _speechRate;
  static const double _minRate = 0.20;
  static const double _maxRate = 0.70;
  static const double _rateStep = 0.10;
  static const String _kRateKey = 'tts_speech_rate';

  /// Human-friendly speed position, e.g. "speed 3 of 6" — students can't
  /// interpret "rate 0.40", but levels give them a sense of where they are
  /// in the range and how far they can still go.
  int get speedLevel => ((_speechRate - _minRate) / _rateStep).round() + 1;
  int get speedLevelCount => ((_maxRate - _minRate) / _rateStep).round() + 1;
  bool get isAtSlowest => _speechRate <= _minRate + 0.001;
  bool get isAtFastest => _speechRate >= _maxRate - 0.001;

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
    // Restore the student's saved reading speed (default 0.40 — slow and
    // clear). Snap to the step grid so saved values from older builds
    // still line up with the level announcements.
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_kRateKey);
      if (saved != null) {
        final clamped = saved.clamp(_minRate, _maxRate);
        final steps = ((clamped - _minRate) / _rateStep).round();
        _speechRate = _minRate + steps * _rateStep;
      }
    } catch (_) {
      // Preferences unavailable — keep the default rate.
    }
    await _tts.setSpeechRate(_speechRate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    // CRUCIAL on Android: make `_tts.speak()` resolve only when the WHOLE
    // utterance has actually been spoken, instead of the instant it is queued.
    // Without this, speakAndWait returned immediately for each lesson segment,
    // the loop raced to the next segment, and that segment's stop() cut the
    // previous one off after a single word — so the lesson came out as
    // truncated fragments ("reproduction" → "reprod", "pollination" → "poll").
    // This one setting is what makes segment-by-segment playback speak each
    // segment to the end.
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {
      // Unsupported on this platform — the completion-handler path below still
      // signals completion.
    }

    // ── Lifecycle handlers ───────────────────────────────────────
    _tts.setStartHandler(() {
      _speaking = true;
    });

    // Track the character offset of the word currently being spoken within
    // the active utterance. This is what makes pause/resume land on the word
    // the student stopped at instead of restarting the whole passage. Engines
    // that don't report progress simply leave the offset at 0, so resume
    // falls back to the start of the current segment (old behaviour) — no
    // regression, just a better experience where supported (Android API 26+).
    _tts.setProgressHandler((text, start, end, word) {
      _spokenWordStart = start;
    });

    _tts.setCompletionHandler(() {
      // Only track speaking state here. Deliberately does NOT complete the
      // completer: normal end-of-utterance is signalled by `_tts.speak()`
      // resolving (which awaitSpeakCompletion(true) ties to the REAL end).
      // On some Android engines this onDone callback fires almost immediately
      // (at utterance start), so completing the completer here would win the
      // Future.any race in speakAndWait and advance the lesson after a single
      // word — the truncated-fragment bug. The completer is reserved for
      // stop/cancel/error interruptions only.
      _speaking = false;
    });

    _tts.setCancelHandler(() {
      _speaking = false;
      if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
        _completionCompleter!.complete();
      }
    });

    _tts.setErrorHandler((message) {
      _speaking = false;
      // Complete normally (not completeError): a TTS engine error just means
      // this utterance ended early, which speakAndWait already handles as an
      // interruption. Using completeError here produced an UNHANDLED async
      // exception, because the awaiter below never wrapped the future in a
      // try/catch — a plausible cause of the app being torn down and
      // relaunched when the engine hiccuped mid-lesson.
      if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
        _completionCompleter!.complete();
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

  /// Cancels any in-flight utterance and releases whoever is awaiting it, so a
  /// new utterance can start from a clean, idle engine. Only calls the native
  /// `stop()` when something is actually speaking — calling it on an idle
  /// engine between back-to-back lesson segments added clicks/latency.
  Future<void> _stopAndSettle() async {
    _cancelled = true;
    final pending = _completionCompleter;
    if (pending != null && !pending.isCompleted) pending.complete();
    if (_speaking) {
      await _tts.stop();
      _speaking = false;
    }
  }

  /// Stops any current speech, then speaks [text].
  ///
  /// NOTE: because [initialize] enables `awaitSpeakCompletion(true)` (required
  /// for gapless segment playback), the returned future now resolves when the
  /// utterance has FINISHED, not when it starts. Callers that must not block
  /// should not await it. [speakAndWait] remains the API to use when you need
  /// the completion result (`true` = spoken to the end, `false` = interrupted).
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final myGeneration = ++_generation;
    await _stopAndSettle();
    if (myGeneration != _generation) return; // a newer request took over
    _cancelled = false;
    await _tts.speak(text);
  }

  /// Stops any current speech immediately.
  ///
  /// Also breaks [speakAndWait] out of its chunk loop (see [_cancelled]) and
  /// unblocks anything currently awaiting [_completionCompleter], so a
  /// "pause"/"stop" action can't be followed a moment later by the next
  /// chunk of a long lesson starting to play anyway.
  Future<void> stop() async {
    _generation++; // supersede any in-flight speak flow
    await _stopAndSettle();
  }

  /// Slows down playback by one step (clamped to [_minRate]).
  Future<double> decreaseRate() => _adjustRate(-_rateStep);

  /// Speeds up playback by one step (clamped to [_maxRate]).
  Future<double> increaseRate() => _adjustRate(_rateStep);

  Future<double> _adjustRate(double delta) async {
    _speechRate = (_speechRate + delta).clamp(_minRate, _maxRate);
    await _tts.setSpeechRate(_speechRate);
    // Persist so the chosen speed survives app restarts.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kRateKey, _speechRate);
    } catch (_) {
      // Best-effort — an unsaved rate still applies for this session.
    }
    return _speechRate;
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
  /// Long text (e.g. a full lesson) is split into chunks and spoken
  /// sequentially — Android's TextToSpeech silently drops anything past
  /// `getMaxSpeechInputLength()` (~4000 chars), which otherwise made
  /// uploaded lesson notes go completely silent.
  ///
  /// Useful for sequencing multiple announcements:
  /// ```audioapp/lib/shared/services/tts_service.dart#L1-1
  /// await tts.speakAndWait('Question one.');
  /// await tts.speakAndWait('Press any key to answer.');
  /// ```
  /// Returns `true` when the whole [text] was spoken to the end, or `false`
  /// when playback was interrupted by [stop] partway through. Callers use this
  /// to tell "the student listened to the entire lesson" (→ mark progress
  /// complete) apart from "the student paused or navigated away".
  Future<bool> speakAndWait(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final myGeneration = ++_generation;
    await _stopAndSettle();
    if (myGeneration != _generation) return false; // superseded while settling

    _cancelled = false;
    // The hub speaks one lesson segment per call, so the offset is reset per
    // call; resume granularity below the 3500-char chunk size isn't needed.
    _spokenWordStart = 0;
    for (final chunk in _splitIntoChunks(trimmed)) {
      if (chunk.isEmpty) continue;
      // A newer request (or a stop) supersedes us — yield the engine to it
      // rather than interleaving another utterance on top.
      if (_cancelled || myGeneration != _generation) return false;
      _completionCompleter = Completer<void>();
      try {
        // With awaitSpeakCompletion(true), `speak` resolves only when the
        // chunk has finished speaking — that is the real "segment done"
        // signal. Race it against the completer so a stop()/supersede (which
        // completes the completer) also unblocks us promptly, and so we can
        // never hang if a device fails to resolve the speak future.
        await Future.any<void>([
          _tts.speak(chunk).then((_) {}),
          _completionCompleter!.future,
        ]);
      } catch (_) {
        // Any engine-level failure (or a legacy completeError) ends this
        // utterance without bringing down the caller — treat it as an
        // interruption, exactly like a stop().
        return false;
      }
      if (_cancelled || myGeneration != _generation) return false;
    }
    return true;
  }

  /// Splits [text] into chunks no longer than [_maxChunkLength], breaking on
  /// sentence boundaries (then word boundaries) so each chunk stays under
  /// the Android TTS engine's input length limit.
  static const int _maxChunkLength = 3500;

  static List<String> _splitIntoChunks(String text) {
    if (text.length <= _maxChunkLength) return [text];

    final chunks = <String>[];
    var remaining = text;
    while (remaining.length > _maxChunkLength) {
      var splitAt = remaining.lastIndexOf('. ', _maxChunkLength);
      if (splitAt <= 0) {
        splitAt = remaining.lastIndexOf(' ', _maxChunkLength);
      }
      if (splitAt <= 0) {
        splitAt = _maxChunkLength;
      } else {
        splitAt += 1;
      }
      chunks.add(remaining.substring(0, splitAt).trim());
      remaining = remaining.substring(splitAt).trim();
    }
    if (remaining.isNotEmpty) chunks.add(remaining);
    return chunks;
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
