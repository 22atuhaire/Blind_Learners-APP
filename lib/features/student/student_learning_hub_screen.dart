import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:audioapp/shared/services/backend_api_service.dart';
import 'package:audioapp/shared/services/backend_link_service.dart';
import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/lesson_segmenter.dart';
import 'package:audioapp/shared/services/question_answer_service.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/stt_service.dart';
import 'package:audioapp/shared/services/tts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

enum LearningStage { subjects, topics, lesson, quizConfirm, quiz }

class StudentLearningHubScreen extends ConsumerStatefulWidget {
  const StudentLearningHubScreen({super.key});

  @override
  ConsumerState<StudentLearningHubScreen> createState() =>
      _StudentLearningHubScreenState();
}

class _StudentLearningHubScreenState
    extends ConsumerState<StudentLearningHubScreen> {
  LearningStage _stage = LearningStage.subjects;
  int _subjectIndex = 0;
  int _topicIndex = 0;
  int _questionIndex = 0;
  int _answerIndex = 0;
  int _score = 0;
  bool _lessonPlaying = false;
  // Lesson playback is spoken segment-by-segment so a pause can resume from
  // the same place instead of restarting. These track the split text, the
  // next segment to speak, and which lesson the segments belong to.
  List<LessonSegment> _lessonSegments = const [];
  int _lessonSegmentIndex = 0;
  int? _segmentsLessonId;

  // Character offset WITHIN the segment at [_lessonSegmentIndex] where playback
  // was paused, so resume continues from the exact word the student stopped on
  // rather than replaying the whole segment. 0 means "from the segment start".
  int _pausedCharOffset = 0;
  bool _quizAnswered = false;
  bool _quizComplete = false;
  String? _announcementKey;

  // ── Voice-first interaction loop ────────────────────────────────────────
  // Every announcement is followed by a short listening window so spoken
  // commands ("next", "repeat", "open", "answer two", ...) are the primary
  // way to navigate — gestures keep working as a fallback. `_voiceLoopSession`
  // is bumped whenever the loop should restart from scratch, invalidating any
  // in-flight speak/listen so old callbacks become no-ops.
  int _voiceLoopSession = 0;
  bool _voiceLoopSuspended = false;

  // Consecutive listening windows that ended with nothing usable heard. Each
  // new window plays Android's recognizer chime, so we re-arm at most
  // [_maxSilentWindows] times then go quiet until the next gesture or
  // announcement (which resets this counter). No spoken reminders, no infinite
  // loop — continuous re-listening let the speaker's echo drive the app.
  int _silentWindows = 0;
  static const int _maxSilentWindows = 3;

  // ── Echo guard ──────────────────────────────────────────────────────────
  // On a hands-free phone the microphone hears the app's own spoken prompt
  // through the speaker. Because prompts contain command words ("...say next
  // for the next question"), the recogniser would transcribe "next" and the
  // quiz would advance on its own. We remember what we just said and when, and
  // ignore any recognised phrase that is part of that prompt and arrives while
  // the speaker's audio could still be echoing.
  String _lastSpokenLower = '';
  DateTime? _spokeEndedAt;
  DateTime? _listenStartedAt;
  // Content echo lasts a while (we keep ignoring prompt words for this long
  // after speaking); the short timing guard catches the acoustic tail even
  // when the recogniser mis-hears it as something not in the prompt.
  static const Duration _echoWindow = Duration(milliseconds: 4000);
  static const Duration _micWarmupIgnore = Duration(milliseconds: 700);

  /// True when [heard] looks like our own prompt echoing back, not the student.
  bool _isEcho(String heard) {
    // 1) The first instants after the mic opens are almost always the tail of
    //    our own speech bleeding through the speaker — ignore regardless of
    //    what it was transcribed as.
    final startedAt = _listenStartedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) < _micWarmupIgnore) {
      return true;
    }
    // 2) Within a longer window, ignore anything that is literally part of the
    //    prompt we just spoke (e.g. the word "next" in "...for the next
    //    question").
    final endedAt = _spokeEndedAt;
    if (endedAt == null) return false;
    // Judge the echo horizon by when the listening WINDOW OPENED, not by when
    // the transcript arrived. The recognizer often delivers the final result
    // of a window many seconds later (after its silence timeout) — field test
    // showed the echoed subject name in such a late final sailing past an
    // arrival-time check and opening the subject on its own. Audio captured
    // by a window that opened just after we spoke can contain our echo no
    // matter when its transcript shows up; a window opened later cannot.
    final windowStart = _listenStartedAt;
    final heardSince = (windowStart != null && windowStart.isAfter(endedAt))
        ? windowStart
        : DateTime.now();
    if (heardSince.difference(endedAt) > _echoWindow) return false;
    final h = _normalizeEcho(heard);
    if (h.isEmpty) return false;
    if (_lastSpokenLower.contains(h)) return true;
    // 3) Word-overlap fallback: the recogniser rarely returns our prompt
    //    verbatim — it drops words, hears "2" as "to", merges fragments — so
    //    the substring test above misses slightly-garbled echo. Field test
    //    showed exactly this: the subjects announcement ("You have 2 subjects.
    //    Science, ...") echoed back as "you have to subjects science", slipped
    //    past the substring check, and the word "science" auto-opened the
    //    subject. If nearly all of a multi-word phrase is words we just spoke,
    //    it is still our own voice, whatever order they arrived in.
    final heardWords = h.split(' ').where((w) => w.isNotEmpty).toList();
    if (heardWords.length >= 2) {
      final promptWords = _lastSpokenLower.split(' ').toSet();
      final matched = heardWords.where(promptWords.contains).length;
      if (matched / heardWords.length >= 0.7) return true;
    }
    return false;
  }

  /// Records what was just spoken (and when it finished) so [_isEcho] can
  /// filter it back out of the microphone.
  ///
  /// The stored copy also has digits expanded to words ("1" → "one"), because
  /// the TTS engine speaks "Question 1" as "Question one" and the recogniser
  /// hears "one" — without this, the echoed "one" slipped past the guard and
  /// was parsed as a quiz answer selection.
  void _noteSpoke(String text) {
    final lower = text.toLowerCase();
    _lastSpokenLower = _normalizeEcho('$lower ${_digitsToWords(lower)}');
    _spokeEndedAt = DateTime.now();
  }

  /// Strips punctuation and collapses whitespace so the echo comparison is not
  /// defeated by the recognizer dropping the commas/periods we spoke (stored
  /// "subject, food. double tap" vs heard "subject food double tap"). Without
  /// this, the app's own announcement — which names the subject — slipped past
  /// the guard and was matched as an "open subject" command, opening the lesson
  /// with no user action.
  String _normalizeEcho(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _digitsToWords(String s) {
    const map = {
      '0': 'zero',
      '1': 'one',
      '2': 'two',
      '3': 'three',
      '4': 'four',
      '5': 'five',
      '6': 'six',
      '7': 'seven',
      '8': 'eight',
      '9': 'nine',
    };
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      sb.write(map[ch] ?? ch);
      sb.write(' ');
    }
    return sb.toString();
  }

  // ── Voice session analytics (backend `/api/v1/voice/session/*`) ─────────
  String? _voiceSessionId;
  DateTime? _voiceSessionStartedAt;
  int _voiceQuestionsAnswered = 0;

  // Identity bridge to the cloud: the local student row is what links this
  // device to a class on the backend (BackendLinkService.getStudentLink) and
  // is the anchor cloud-synced content gets filed under locally.
  Student? _currentStudent;
  bool _cloudSyncing = false;
  bool _hasAutoPromptedJoin = false;

  // Captured while `ref` is valid. `dispose()` (and the async _endVoiceSession
  // it fires) must never touch `ref` — doing so throws "Cannot use ref after
  // the widget was disposed" and, during a screen-lock/navigation teardown,
  // corrupts widget-tree finalization badly enough to restart the whole app.
  late final SttService _stt;
  late final TtsService _tts;
  late final BackendLinkService _link;

  @override
  void initState() {
    super.initState();
    _stt = ref.read(sttServiceProvider);
    _tts = ref.read(ttsServiceProvider);
    _link = ref.read(backendLinkServiceProvider);
    Future<void>(() async {
      await ref.read(ttsInitProvider.future);
      if (!mounted) return;
      // Wait for the local subjects to load before the first announcement —
      // otherwise the FutureProvider is still resolving and we'd wrongly say
      // "No subjects available" even though subjects exist on the device.
      try {
        await ref.read(allSubjectsProvider.future);
      } catch (_) {
        // Fall through and announce whatever state we have.
      }
      if (!mounted) return;
      // Speak FIRST, sync in the background. The cloud bridge talks to a
      // free-tier backend that can take 30-60 seconds to cold-start; awaiting
      // it before the first announcement left students staring at a silent
      // screen. If the bridge later finds the student has no class, it
      // interrupts with the join prompt (speakAndWait stops current speech).
      _announceCurrentState(force: true);
      unawaited(_bootstrapCloudBridge());
    });
  }

  /// Loads the local student record and — if it is linked to a class on the
  /// backend — pulls the teacher's cloud notes into this device's local
  /// database so they show up as ordinary subjects/topics/lessons. This is
  /// the fix for "no subjects available": local SQLite is per-device, so a
  /// student only ever sees a teacher's uploads once they have been
  /// materialised here at least once. Runs quietly; failures never block
  /// the (fully working, local-first) learning flow.
  Future<void> _bootstrapCloudBridge() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final student = await _activeStudent();
      if (!mounted) return;
      setState(() => _currentStudent = student);
      if (student == null) return;

      final link = ref.read(backendLinkServiceProvider);
      final linkInfo = await link.getStudentLink(student.id);
      if (linkInfo == null) {
        // Not linked to a class yet. Stay in the local-first learning hub
        // instead of forcing the join flow — that flow re-asked the student's
        // name and felt like the login looping back. Give one gentle spoken
        // hint, then resume normal voice control. Joining a class stays
        // available on demand via the header icon (_openJoinClassFlow).
        if (!_hasAutoPromptedJoin) {
          _hasAutoPromptedJoin = true;
          await ref.read(sttServiceProvider).stopListening();
          const hint = 'To get lessons from your teacher, tap the top of the '
              'screen to join a class. Or keep learning with the lessons '
              'already on this phone.';
          await ref.read(ttsServiceProvider).speakAndWait(hint);
          _noteSpoke(hint);
          if (mounted) _announceCurrentState(force: true);
        }
        return;
      }

      if (mounted) setState(() => _cloudSyncing = true);
      // Hard cap: a cold-starting backend must never hold the UI's syncing
      // indicator (or anything awaiting this bridge) hostage for minutes.
      final added = await link
          .syncCloudContentForStudent(
            localStudentId: student.id,
            db: db,
          )
          .timeout(const Duration(seconds: 25), onTimeout: () => 0);
      if (!mounted) return;
      setState(() => _cloudSyncing = false);

      if (added > 0) {
        ref.invalidate(allSubjectsProvider);
        // Wait for the refreshed list, then re-announce so the student hears
        // the now-available subjects (and we never leave a stale "No subjects
        // available" spoken earlier).
        try {
          await ref.read(allSubjectsProvider.future);
        } catch (_) {}
        if (!mounted) return;
        await _speak(
          added == 1
              ? 'One new lesson from your class is ready.'
              : '$added new lessons from your class are ready.',
        );
        if (mounted && _stage == LearningStage.subjects) {
          _announceCurrentState(force: true);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _cloudSyncing = false);
      // Silent — this bridge is purely additive over the local-first flow.
    }
  }

  /// Entry point for the voice-guided "join your class" flow, surfaced as a
  /// header icon so a student is never stuck without a class code prompt.
  Future<void> _openJoinClassFlow() async {
    final student = _currentStudent ??
        await _activeStudent();
    if (!mounted || student == null) return;
    setState(() => _currentStudent = student);

    // Suspend our own listen loop — the join dialog uses the same shared STT
    // engine and must have exclusive access to the microphone while it runs.
    _voiceLoopSuspended = true;
    _voiceLoopSession++;
    await ref.read(sttServiceProvider).stopListening();
    await ref.read(ttsServiceProvider).stop();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _JoinClassDialog(student: student),
    );

    if (!mounted) return;
    _voiceLoopSuspended = false;
    _announceCurrentState(force: true);
    unawaited(_bootstrapCloudBridge());
  }

  /// Opens the voice-first "My Progress" screen. Suspends our listen loop and
  /// frees the shared TTS/STT engine first (the progress screen speaks the
  /// summary itself), then resumes the loop and re-announces on return.
  Future<void> _openProgress() async {
    _voiceLoopSuspended = true;
    _voiceLoopSession++;
    await ref.read(sttServiceProvider).stopListening();
    await ref.read(ttsServiceProvider).stop();
    if (!mounted) return;

    await context.pushNamed('studentProgress');

    if (!mounted) return;
    _voiceLoopSuspended = false;
    _announceCurrentState(force: true);
  }

  @override
  void dispose() {
    _voiceLoopSession++;
    _stt.stopListening();
    _tts.stop();
    unawaited(_endVoiceSession());
    super.dispose();
  }

  Future<void> _speak(String text) async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(text);
  }

  // ── Voice-first interaction loop ────────────────────────────────────────

  /// Speaks [text], then opens a short listening window for a spoken command.
  /// Use for one-off announcements (errors, boundary messages) that aren't
  /// covered by [_announceCurrentState].
  Future<void> _announceAndListen(String text) async {
    if (!mounted) return;
    final session = ++_voiceLoopSession;
    // Free the microphone before speaking: a still-open engine session from
    // the previous window would make the next startListening a silent no-op
    // (and would let the recogniser transcribe our own announcement).
    await ref.read(sttServiceProvider).stopListening();
    if (!mounted || session != _voiceLoopSession) return;
    await ref.read(ttsServiceProvider).speakAndWait(text);
    _noteSpoke(text);
    if (!mounted || session != _voiceLoopSession) return;
    await _listenForVoiceCommand(session);
  }

  /// Speaks each message in [texts] in order, then opens a listening window.
  Future<void> _announceSequenceAndListen(List<String> texts) async {
    if (!mounted) return;
    final session = ++_voiceLoopSession;
    // See _announceAndListen: the engine must be free before TTS starts.
    await ref.read(sttServiceProvider).stopListening();
    if (!mounted || session != _voiceLoopSession) return;
    final tts = ref.read(ttsServiceProvider);
    for (final text in texts) {
      if (!mounted || session != _voiceLoopSession) return;
      await tts.speakAndWait(text);
    }
    _noteSpoke(texts.join(' '));
    if (!mounted || session != _voiceLoopSession) return;
    await _listenForVoiceCommand(session);
  }

  /// Opens ONE listening window after an announcement. If nothing usable is
  /// heard (silence, or only our own prompt echoing back), it re-arms at most
  /// [_maxSilentWindows] times then goes quiet — a gesture or the next
  /// announcement revives it. This deliberately does NOT loop forever or speak
  /// reminders: continuous re-listening made the speaker's echo of command
  /// words (e.g. "subjects", "play") trigger navigation on its own.
  Future<void> _listenForVoiceCommand(int session) async {
    if (!mounted || _voiceLoopSuspended || session != _voiceLoopSession) return;

    final stt = ref.read(sttServiceProvider);
    final ready = await stt.initialize();
    if (!ready ||
        !mounted ||
        _voiceLoopSuspended ||
        session != _voiceLoopSession) {
      return;
    }

    // Settle gap: let the TTS audio tail fully drain before the mic opens so
    // the recogniser doesn't immediately transcribe our own announcement.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _voiceLoopSuspended || session != _voiceLoopSession) {
      return;
    }

    _listenStartedAt = DateTime.now();
    var handled = false;
    stt.startListening(
      onPartial: (words) {
        if (handled || session != _voiceLoopSession || !mounted) return;
        if (_isEcho(words)) return; // our own prompt bleeding into the mic
        if (_tryDispatchVoiceCommand(words)) {
          handled = true;
          _silentWindows = 0;
          unawaited(stt.stopListening());
        }
      },
      onResult: (words) {
        if (handled || session != _voiceLoopSession) return;
        handled = true;
        unawaited(stt.stopListening());
        if (_isEcho(words) || !_tryDispatchVoiceCommand(words)) {
          // Echo or unrecognised — try once more, within budget.
          _retryListen(session);
        } else {
          _silentWindows = 0;
        }
      },
      onDone: () {
        if (handled || session != _voiceLoopSession) return;
        handled = true;
        _retryListen(session);
      },
    );
  }

  /// Re-arms the single listening window a bounded number of times, then stops.
  /// No spoken reminder, no infinite loop — keeps voice available briefly while
  /// preventing echo-driven runaway listening.
  void _retryListen(int session) {
    if (!mounted || _voiceLoopSuspended || session != _voiceLoopSession) return;
    _silentWindows++;
    if (_silentWindows >= _maxSilentWindows) return; // go quiet
    unawaited(_listenForVoiceCommand(session));
  }

  /// Maps a recognised phrase to the same actions gestures trigger and
  /// returns whether anything matched. Voice is the primary channel; gestures
  /// (`_onSwipeLeft/Right/Up/Down`, `_onDoubleTap`) remain fully functional
  /// as a fallback. Called with both in-flight partials (instant response)
  /// and final results (safety net), so it must act ONLY on a clear match.
  bool _tryDispatchVoiceCommand(String heard) {
    if (!mounted) return false;
    final command = heard.toLowerCase().trim();
    if (command.isEmpty) return false;

    bool has(List<String> phrases) => phrases.any(command.contains);

    // A real spoken command is short ("science", "answer two", "open food").
    // A long phrase containing a subject name or a number is almost always
    // our own announcement echoing back through the microphone — never treat
    // it as a high-impact selection command.
    final isShortPhrase = command.split(RegExp(r'\s+')).length <= 4;

    // In an active quiz, "answer two" / "option three" / a bare number picks
    // an option directly and submits it.
    if (_stage == LearningStage.quiz &&
        !_quizAnswered &&
        !_quizComplete &&
        isShortPhrase) {
      final answer = _answerNumberFromCommand(command);
      if (answer != null) {
        final question = _currentQuizQuestion();
        if (question != null) {
          final options = _quizOptions(question);
          if (answer >= 1 && answer <= options.length) {
            setState(() => _answerIndex = answer - 1);
            unawaited(_selectQuizAnswer());
            return true;
          }
        }
      }
    }

    // On the subjects screen, let the student jump straight to a subject by
    // speaking its name ("open Science", "Food", "social studies") instead of
    // stepping through them one at a time. Short phrases only: the subjects
    // announcement itself names every subject, so a long echoed fragment of it
    // must never be allowed to "say" a subject name on the student's behalf.
    if (_stage == LearningStage.subjects && isShortPhrase) {
      final matchedIndex = _subjectIndexFromCommand(command);
      if (matchedIndex != null) {
        setState(() => _subjectIndex = matchedIndex);
        _openCurrentSubject();
        return true;
      }
    }

    // Ask-a-question (lesson stage only): an explicit "I have a question" opens
    // a prompt; a direct "what is X / explain X" is answered straight away from
    // the lesson's own text. Both are content-bound and work offline.
    if (_stage == LearningStage.lesson) {
      if (has([
        'i have a question',
        'ask a question',
        'i want to ask',
        'i have a doubt',
        'have a question',
      ])) {
        unawaited(_enterAskMode());
        return true;
      }
      final isDirectQuestion = command.startsWith('what is ') ||
          command.startsWith('what are ') ||
          command.startsWith('what does ') ||
          command.startsWith('explain ') ||
          command.startsWith('why ') ||
          command.startsWith('how does ') ||
          command.startsWith('how do ') ||
          command.startsWith('tell me about ');
      // Require a few words so a partial ("what is") doesn't fire before the
      // student has finished asking.
      if (isDirectQuestion && command.split(' ').length >= 3) {
        unawaited(_answerQuestion(command));
        return true;
      }
    }

    if (has(['next', 'forward', 'continue', 'right'])) {
      _onSwipeRight();
    } else if (has(['previous', 'back', 'left'])) {
      _onSwipeLeft();
    } else if (has(['repeat', 'again', 'replay', 'say that again'])) {
      if (_stage == LearningStage.lesson) {
        _onSwipeUp();
      } else {
        _announceCurrentState(force: true);
      }
    } else if (has(['help', 'instruction', 'what can i say', 'what do i do'])) {
      // Quiz instructions are spoken once when the quiz starts (not repeated
      // per question); "help" re-speaks them on demand. Everywhere else, help
      // simply re-announces the current state, which carries its guidance.
      if (_stage == LearningStage.quiz) {
        unawaited(_announceAndListen(_quizInstructionsText(_questionsCount())));
      } else {
        _announceCurrentState(force: true);
      }
    } else if (has(['faster', 'speed up', 'too slow', 'quick'])) {
      // Checked before the slower-list: "too slow" means the student wants
      // it FASTER, and the bare word "slow" below would otherwise catch it.
      unawaited(_changeSpeechRate(slower: false));
    } else if (has(['slower', 'slow', 'too fast', 'reduce'])) {
      // Bare "slow" covers "slow down" and "slowly". Checked before the
      // 'down' swipe command below, since "slow down" would otherwise match.
      unawaited(_changeSpeechRate(slower: true));
    } else if (has(['quiz', 'test', 'down'])) {
      _onSwipeDown();
    } else if (has(['up'])) {
      _onSwipeUp();
    } else if (has([
      'open',
      'select',
      'play',
      'resume',
      'pause',
      'stop',
      'choose',
      'confirm',
      'start',
      'enter'
    ])) {
      _onDoubleTap();
    } else if (has([
      'my progress',
      'progress',
      'how am i doing',
      'my score',
      'how am i',
      'report'
    ])) {
      _openProgress();
    } else if (has(['home', 'main menu', 'go home'])) {
      // NOTE: the word "subjects" is deliberately NOT a trigger here — it
      // appears in the subjects announcement ("You have two subjects…"), and
      // when the speaker echoed it back the app sent itself home and
      // re-announced, looping endlessly. If we're already on the subjects
      // screen, going home is a no-op (don't re-announce).
      if (_stage == LearningStage.subjects) return true;
      final wasInLesson = _stage == LearningStage.lesson ||
          _stage == LearningStage.quizConfirm ||
          _stage == LearningStage.quiz;
      if (wasInLesson) unawaited(_endVoiceSession());
      setState(() {
        _stage = LearningStage.subjects;
        _topicIndex = 0;
        _lessonPlaying = false;
        _quizAnswered = false;
        _quizComplete = false;
        _score = 0;
      });
      _announceCurrentState(force: true);
    } else {
      return false;
    }
    return true;
  }

  /// Adjusts the TTS playback speed by one step. If a lesson is currently
  /// playing, restarts it at the new speed so the change is heard right
  /// away; otherwise just confirms the change and resumes listening.
  ///
  /// The confirmation is spoken AT the new rate and includes the level
  /// ("speed 2 of 6"), so the student immediately hears the difference and
  /// knows how much slower or faster they can still go.
  // ── Ask a question (offline, content-bound retrieval) ────────────────────

  /// Opens a one-shot prompt: "What is your question?", captures the spoken
  /// question, then answers it from the current lesson's text.
  Future<void> _enterAskMode() async {
    if (!mounted) return;
    final session = ++_voiceLoopSession;
    await ref.read(sttServiceProvider).stopListening();
    ref.read(ttsServiceProvider).stop();
    if (mounted) setState(() => _lessonPlaying = false);
    const prompt = 'What is your question?';
    await ref.read(ttsServiceProvider).speakAndWait(prompt);
    _noteSpoke(prompt);
    if (!mounted || session != _voiceLoopSession) return;
    await _listenForQuestion(session);
  }

  /// Listens for a free-form spoken question (longer window than a command).
  Future<void> _listenForQuestion(int session) async {
    final stt = ref.read(sttServiceProvider);
    final ready = await stt.initialize();
    if (!ready || !mounted || session != _voiceLoopSession) return;

    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || session != _voiceLoopSession) return;

    var handled = false;
    stt.startListening(
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 6),
      onResult: (words) {
        if (handled || session != _voiceLoopSession) return;
        handled = true;
        unawaited(stt.stopListening());
        if (_isEcho(words) || words.trim().isEmpty) {
          unawaited(_announceAndListen(
              'I did not catch that. Say play to keep listening, or ask again.'));
        } else {
          unawaited(_answerQuestion(words));
        }
      },
      onDone: () {
        if (handled || session != _voiceLoopSession) return;
        handled = true;
        unawaited(_announceAndListen(
            'I did not hear a question. Say play to keep learning.'));
      },
    );
  }

  /// Answers [question] using only the current lesson text, then re-arms the
  /// normal command listener.
  Future<void> _answerQuestion(String question) async {
    ref.read(ttsServiceProvider).stop();
    if (mounted) setState(() => _lessonPlaying = false);

    final lesson = _currentLesson();
    final text = lesson?.rawText ?? '';
    final answer = QuestionAnswerService().answer(question, text);
    _logVoiceEvent('free_ask', question, answer ?? 'no match');

    if (answer == null || answer.trim().isEmpty) {
      await _announceAndListen(
          'I could not find that in this lesson. Try asking in different '
          'words, or say play to keep listening.');
    } else {
      await _announceSequenceAndListen([
        answer,
        'Ask another question, or say play to keep listening.',
      ]);
    }
  }

  Future<void> _changeSpeechRate({required bool slower}) async {
    final tts = ref.read(ttsServiceProvider);

    // Order matters. Calling setSpeechRate() on a LIVE Android TTS utterance
    // corrupts the audio and leaves it choppy for the rest of the lesson. So
    // when a lesson is playing: supersede + stop the current utterance FIRST
    // (settling the engine), change the rate on the now-idle engine, and only
    // then resume from where we were. Previously the rate was changed while a
    // segment was still speaking, which is exactly what broke playback.
    final resuming = _lessonPlaying && _currentLesson() != null;
    final session = ++_voiceLoopSession;
    if (resuming) {
      await tts.stop();
      if (!mounted || session != _voiceLoopSession) return;
    }

    await (slower ? tts.decreaseRate() : tts.increaseRate());

    final String label;
    if (slower && tts.isAtSlowest) {
      label = 'This is the slowest speed.';
    } else if (!slower && tts.isAtFastest) {
      label = 'This is the fastest speed.';
    } else {
      label = '${slower ? 'Slower' : 'Faster'}. '
          'Speed ${tts.speedLevel} of ${tts.speedLevelCount}.';
    }

    if (resuming) {
      _logVoiceEvent(
          'repeat', 'Adjust speed', 'Continuing lesson at new speed.');
      unawaited(_announceThenResumeLesson(session, label));
      return;
    }

    unawaited(_announceAndListen(label));
  }

  /// Long-press anywhere = read slower. A held touch is the easiest gesture
  /// for a blind student mid-lesson — no voice round-trip, no precise swipe —
  /// and slowing down is the adjustment students need most while trying to
  /// comprehend dense notes. (Two-finger tap = faster; voice works for both.)
  void _onLongPress() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    unawaited(_changeSpeechRate(slower: true));
  }

  // ── Two-finger tap = read faster ──────────────────────────────────────────
  // Long-press slows the speech down, but a student who slowed it (or who is
  // simply comfortable) needs a way BACK UP without the voice round-trip.
  // A single two-finger tap mirrors the long-press: no precision required,
  // consistent with Android accessibility conventions (TalkBack itself uses
  // multi-finger taps), and it cannot collide with the existing single-finger
  // gestures. Detected with raw pointer events (a Listener does not compete
  // in the gesture arena, so double-tap / long-press / swipes are unaffected).
  int _pointersDown = 0;
  int _tapPointerPeak = 0;
  DateTime? _firstPointerDownAt;
  double _pointerTravel = 0;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointersDown == 0) {
      _firstPointerDownAt = DateTime.now();
      _tapPointerPeak = 0;
      _pointerTravel = 0;
    }
    _pointersDown++;
    if (_pointersDown > _tapPointerPeak) _tapPointerPeak = _pointersDown;
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointerTravel += event.delta.distance;
  }

  void _onPointerEnd(PointerEvent event) {
    _pointersDown--;
    if (_pointersDown > 0) return;
    _pointersDown = 0;
    final startedAt = _firstPointerDownAt;
    _firstPointerDownAt = null;
    if (startedAt == null) return;
    final duration = DateTime.now().difference(startedAt);
    // Exactly two fingers, quick, and essentially stationary — a deliberate
    // two-finger tap, not a swipe, pinch, or an accidental brush.
    if (_tapPointerPeak == 2 &&
        duration < const Duration(milliseconds: 400) &&
        _pointerTravel < 40) {
      _onTwoFingerTap();
    }
  }

  void _onTwoFingerTap() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    unawaited(_changeSpeechRate(slower: false));
  }

  /// Extracts a 1-4 answer number from a spoken quiz response, e.g.
  /// "answer two", "option 3", or just "four".
  int? _answerNumberFromCommand(String command) {
    const words = {
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
    };
    for (final entry in words.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    final match = RegExp(r'[1-4]').firstMatch(command);
    if (match != null) return int.parse(match.group(0)!);
    return null;
  }

  // ── Voice session analytics ─────────────────────────────────────────────

  /// Starts a backend voice session for the lesson now showing, if it is a
  /// cloud-synced lesson and the student is linked to a class. No-ops (and
  /// stays silent) for purely local lessons or when offline.
  Future<void> _startVoiceSessionForCurrentLesson() async {
    final lesson = _currentLesson();
    final student = _currentStudent;
    if (lesson == null || student == null) return;

    final sessionId = await _link.startVoiceSessionForLesson(
      localStudentId: student.id,
      localLessonId: lesson.id,
    );
    if (sessionId == null) return;

    _voiceSessionId = sessionId;
    _voiceSessionStartedAt = DateTime.now();
    _voiceQuestionsAnswered = 0;
  }

  /// Closes the current voice session (if any), reporting how long the
  /// student spent and how the quiz went.
  Future<void> _endVoiceSession() async {
    final sessionId = _voiceSessionId;
    final startedAt = _voiceSessionStartedAt;
    final student = _currentStudent;
    _voiceSessionId = null;
    _voiceSessionStartedAt = null;
    if (sessionId == null || startedAt == null || student == null) return;

    await _link.endVoiceSessionForLesson(
      localStudentId: student.id,
      sessionId: sessionId,
      durationSeconds: DateTime.now().difference(startedAt).inSeconds,
      questionsAnswered: _voiceQuestionsAnswered,
      totalScore: _score.toDouble(),
    );
  }

  /// Fire-and-forget log of one interaction against the active voice session.
  /// A no-op when no session is active (local-only lesson / offline).
  void _logVoiceEvent(String interactionType, String command, String response) {
    final sessionId = _voiceSessionId;
    final student = _currentStudent;
    if (sessionId == null || student == null) return;

    unawaited(_link.logVoiceEvent(
      localStudentId: student.id,
      sessionId: sessionId,
      interactionType: interactionType,
      command: command,
      response: response,
    ));
  }

  // ── Progress capture (local, offline-first) ─────────────────────────────
  //
  // These persist durable learning progress to the local Drift tables that
  // already existed but were never written to. All are fire-and-forget and
  // swallow errors: tracking must never interrupt or break the lesson flow.

  /// Resolves the on-device student id, loading the record if it hasn't been
  /// cached yet. Returns null only when no student exists at all.
  /// Resolves the currently logged-in student (set by name-login). Falls back to
  /// the first student row for legacy single-student installs.
  Future<Student?> _activeStudent() async {
    final db = ref.read(appDatabaseProvider);
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt('active_student_id');
    if (id != null) {
      final s = await db.studentDao.getStudentById(id);
      if (s != null) return s;
    }
    return db.studentDao.getStudent();
  }

  Future<int?> _studentId() async {
    final cached = _currentStudent?.id;
    if (cached != null) return cached;
    try {
      final student = await _activeStudent();
      if (student != null && mounted) _currentStudent = student;
      return student?.id;
    } catch (_) {
      return null;
    }
  }

  /// Marks a lesson as completed once the student has heard it end to end.
  /// Upsert keyed on (lessonId, studentId), so re-listening just refreshes the
  /// timestamp rather than duplicating rows.
  Future<void> _recordLessonCompleted(int lessonId) async {
    try {
      final studentId = await _studentId();
      if (studentId == null) return;
      await ref.read(appDatabaseProvider).progressDao.upsertProgress(
            ProgressTableCompanion(
              lessonId: Value(lessonId),
              studentId: Value(studentId),
              completed: const Value(true),
              lastAccessed: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
      // Mirror the completion to the class dashboard. Fire-and-forget: a
      // local-only lesson or an offline phone makes this a silent no-op.
      unawaited(ref.read(backendLinkServiceProvider).reportLessonProgress(
            localStudentId: studentId,
            localLessonId: lessonId,
            completed: true,
          ));
    } catch (_) {
      // Non-blocking — progress tracking is additive over the learning flow.
    }
  }

  /// Records one quiz answer attempt (right or wrong) for later summarising.
  Future<void> _recordQuizResult(int questionId, bool wasCorrect) async {
    try {
      final studentId = await _studentId();
      if (studentId == null) return;
      await ref.read(appDatabaseProvider).quizResultDao.insertQuizResult(
            QuizResultsTableCompanion(
              questionId: Value(questionId),
              studentId: Value(studentId),
              wasCorrect: Value(wasCorrect),
              attemptedAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
    } catch (_) {
      // Non-blocking.
    }
  }

  List<Subject> _subjects() =>
      ref.read(allSubjectsProvider).valueOrNull ?? const [];

  /// Finds which subject the student named in [command], or null if none.
  /// Matches the spoken phrase containing a subject's full name, or — for a
  /// recognised fragment of at least four letters — a subject name containing
  /// that fragment (so "social" opens "Social Studies").
  int? _subjectIndexFromCommand(String command) {
    final subjects = _subjects();
    for (var i = 0; i < subjects.length; i++) {
      final name = subjects[i].name.toLowerCase().trim();
      if (name.isEmpty) continue;
      if (command.contains(name)) return i;
      if (command.length >= 4 && name.contains(command)) return i;
    }
    return null;
  }

  List<Topic> _topicsForSubject(Subject subject) =>
      ref.read(subjectTopicsProvider(subject.id)).valueOrNull ?? const [];

  Lesson? _lessonForTopic(Topic topic) =>
      ref.read(topicLessonProvider(topic.id)).valueOrNull;

  List<Question> _questionsForLesson(Lesson lesson) =>
      ref.read(lessonQuestionsProvider(lesson.id)).valueOrNull ?? const [];

  List<_QuizOption> _quizOptions(Question question) {
    final items = <_QuizOption>[];

    void addOption(String label, String? text) {
      final value = text?.trim();
      if (value != null && value.isNotEmpty) {
        items.add(_QuizOption(label: label, text: value));
      }
    }

    addOption('1', question.optionA);
    addOption('2', question.optionB);
    addOption('3', question.optionC);
    addOption('4', question.optionD);
    return items;
  }

  void _announceCurrentState({bool force = false}) {
    if (!mounted) return;

    final key = switch (_stage) {
      LearningStage.subjects => 'subjects:$_subjectIndex',
      LearningStage.topics => 'topics:$_subjectIndex:$_topicIndex',
      LearningStage.lesson => 'lesson:$_subjectIndex:$_topicIndex',
      LearningStage.quizConfirm => 'quizConfirm:$_subjectIndex:$_topicIndex',
      LearningStage.quiz =>
        'quiz:$_subjectIndex:$_topicIndex:$_questionIndex:$_answerIndex:$_quizAnswered:$_quizComplete',
    };

    final shouldSpeak = force || _announcementKey != key;
    _announcementKey = key;

    // A state change or explicit re-announcement means the student is active
    // again — give the silent-window budget back in full.
    _silentWindows = 0;

    final session = ++_voiceLoopSession;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || session != _voiceLoopSession) return;
      // Free the microphone before speaking (see _announceAndListen).
      await ref.read(sttServiceProvider).stopListening();
      if (!mounted || session != _voiceLoopSession) return;
      if (shouldSpeak) {
        final text = _announcementText();
        await ref.read(ttsServiceProvider).speakAndWait(text);
        _noteSpoke(text);
      }
      if (!mounted || session != _voiceLoopSession) return;
      await _listenForVoiceCommand(session);
    });
  }

  String _announcementText() {
    final subjects = _subjects();
    if (subjects.isEmpty) return 'No subjects available.';

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);

    switch (_stage) {
      // NOTE on wording: spoken prompts deliberately avoid command words
      // ("next", "open", "play", "quiz", "right", number words, …). On a
      // hands-free phone the speaker feeds the microphone, so any command word
      // we speak can echo back and trigger itself. Gesture guidance ("swipe",
      // "double tap") is safe because those aren't voice commands, and the
      // on-screen footer still lists everything for sighted helpers.
      case LearningStage.subjects:
        if (subjects.length == 1) {
          return 'You have one subject, ${subject.name}. '
              'Double tap to revise it.';
        }
        final listed = subjects.take(8).map((s) => s.name).join(', ');
        final more = subjects.length > 8
            ? ', and ${subjects.length - 8} more'
            : '';
        return 'You have ${subjects.length} subjects. $listed$more. '
            'Swipe left or right to browse, then double tap the one you want. '
            'Or just say a subject name.';
      case LearningStage.topics:
        if (topics.isEmpty) return 'No topics available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        return '${subject.name}. ${topic.name}, ${_topicIndex + 1} of ${topics.length}. '
            'Swipe to browse, double tap to begin.';
      case LearningStage.lesson:
        if (topics.isEmpty) return 'No topics available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        return '${topic.name}. Double tap to begin reading. '
            'Swipe down for the questions. Hold the screen to read slower. '
            'Tap with two fingers to read faster.';
      case LearningStage.quizConfirm:
        return 'Ready for the questions. Double tap to begin, '
            'or swipe up to return to the lesson.';
      case LearningStage.quiz:
        if (_quizComplete) return 'Quiz complete.';
        if (topics.isEmpty) return 'No questions available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        final lesson = _lessonForTopic(topic);
        if (lesson == null) return 'No questions available.';
        final questions = _questionsForLesson(lesson);
        if (questions.isEmpty) return 'No questions available.';
        final question =
            questions[_questionIndex.clamp(0, questions.length - 1)];
        final options = _quizOptions(question);
        final buffer = StringBuffer(
          'Question ${_questionIndex + 1} of ${questions.length}. ${question.questionText}',
        );
        if (options.isNotEmpty) {
          final current = options[_answerIndex.clamp(0, options.length - 1)];
          // Read the currently-highlighted option only. The how-to guidance is
          // spoken once at quiz start (see _startQuiz) and on "help" — not
          // repeated per question, which field tests showed was exhausting.
          buffer.write(' Option ${current.label}. ${current.text}.');
        }
        return buffer.toString();
    }
  }

  void _clampIndices() {
    final subjects = _subjects();
    if (subjects.isEmpty) {
      _subjectIndex = 0;
      _topicIndex = 0;
      return;
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final topics = _topicsForSubject(subjects[_subjectIndex]);
    if (topics.isEmpty) {
      _topicIndex = 0;
      return;
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
  }

  Lesson? _currentLesson() {
    final subjects = _subjects();
    if (subjects.isEmpty) return null;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) return null;

    final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
    return _lessonForTopic(topic);
  }

  Question? _currentQuizQuestion() {
    final lesson = _currentLesson();
    if (lesson == null) return null;

    final questions = _questionsForLesson(lesson);
    if (questions.isEmpty) return null;
    if (_questionIndex < 0 || _questionIndex >= questions.length) return null;
    return questions[_questionIndex];
  }

  int _questionsCount() {
    final lesson = _currentLesson();
    if (lesson == null) return 0;
    return _questionsForLesson(lesson).length;
  }

  void _moveSubject(int delta) {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final next = _subjectIndex + delta;
    if (next < 0) {
      HapticFeedback.heavyImpact();
      unawaited(_announceAndListen('First subject.'));
      return;
    }
    if (next >= subjects.length) {
      HapticFeedback.heavyImpact();
      unawaited(_announceAndListen('Last subject.'));
      return;
    }

    setState(() {
      _subjectIndex = next;
      _topicIndex = 0;
      _stage = LearningStage.subjects;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
      _lessonPlaying = false;
    });
    _announceCurrentState();
  }

  void _moveTopic(int delta) {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) return;

    final next = _topicIndex + delta;
    if (next < 0) {
      HapticFeedback.heavyImpact();
      unawaited(_announceAndListen('First topic.'));
      return;
    }
    if (next >= topics.length) {
      HapticFeedback.heavyImpact();
      unawaited(_announceAndListen('Last topic.'));
      return;
    }

    // Moving to a different topic while reading a lesson swaps lessons —
    // close out the old voice session and open a new one for the new lesson.
    final wasLessonStage = _stage == LearningStage.lesson;
    if (wasLessonStage) {
      _logVoiceEvent('next', 'Next topic', 'Moving to next topic.');
      unawaited(_endVoiceSession());
    }

    setState(() {
      _topicIndex = next;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
      if (_stage == LearningStage.subjects) {
        _stage = LearningStage.topics;
      }
    });
    _announceCurrentState();

    if (wasLessonStage) {
      unawaited(_startVoiceSessionForCurrentLesson());
    }
  }

  void _openCurrentSubject() {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      unawaited(_announceAndListen('No topics available.'));
      return;
    }

    setState(() {
      _topicIndex = 0;
      _stage = LearningStage.topics;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    _announceCurrentState(force: true);
  }

  void _openCurrentTopic() {
    final lesson = _currentLesson();
    if (lesson == null) {
      unawaited(_announceAndListen('No lesson available.'));
      return;
    }

    setState(() {
      _stage = LearningStage.lesson;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    // Opening a topic starts its lesson fresh from the beginning.
    _segmentsLessonId = null;
    _lessonSegmentIndex = 0;
    _pausedCharOffset = 0;
    _announceCurrentState(force: true);
    unawaited(_startVoiceSessionForCurrentLesson());
  }

  void _toggleLessonPlayback() {
    final lesson = _currentLesson();
    if (lesson == null) return;

    if (_lessonPlaying) {
      // Pause: stop speaking but keep our place so play resumes here.
      setState(() => _lessonPlaying = false);
      ref.read(ttsServiceProvider).stop();
      _logVoiceEvent('pause', 'Pause lesson', 'Paused.');
      unawaited(_announceAndListen('Paused. Double tap to resume.'));
    } else {
      // Play, or resume from the exact word we paused on.
      _ensureLessonSegments(lesson);
      setState(() => _lessonPlaying = true);
      final resuming = _lessonSegmentIndex != 0 || _pausedCharOffset != 0;
      _logVoiceEvent('repeat', 'Play lesson',
          resuming ? 'Resuming.' : 'Playing lesson audio.');
      final session = ++_voiceLoopSession;
      unawaited(_playLessonFrom(
        session,
        _lessonSegmentIndex,
        startCharOffset: _pausedCharOffset,
      ));
    }
  }

  void _replayLesson() {
    final lesson = _currentLesson();
    if (lesson == null) return;

    ref.read(ttsServiceProvider).stop();
    _ensureLessonSegments(lesson);
    _lessonSegmentIndex = 0; // replay restarts from the beginning
    _pausedCharOffset = 0;
    setState(() => _lessonPlaying = true);
    _logVoiceEvent('repeat', 'Replay lesson', 'Replaying from the start.');
    final session = ++_voiceLoopSession;
    unawaited(_playLessonFrom(session, 0));
  }

  /// Splits [lesson] into playback segments the first time it is played (or
  /// when the lesson changes). Keeps the current position if the same lesson
  /// is still loaded, so resume works across pause/play.
  void _ensureLessonSegments(Lesson lesson) {
    if (_segmentsLessonId != lesson.id || _lessonSegments.isEmpty) {
      _lessonSegments = splitLessonIntoSegments(lesson.rawText);
      _lessonSegmentIndex = 0;
      _pausedCharOffset = 0;
      _segmentsLessonId = lesson.id;
    }
  }

  /// Speaks the lesson segment-by-segment from [startIndex], remembering
  /// progress in [_lessonSegmentIndex] so a pause can resume from the same
  /// place. Bails the moment playback is paused (`_lessonPlaying` false), the
  /// voice loop is superseded (session changed), or the widget is torn down —
  /// without losing the position, so the next play replays the interrupted
  /// segment rather than skipping it.
  Future<void> _playLessonFrom(
    int session,
    int startIndex, {
    int startCharOffset = 0,
  }) async {
    final tts = ref.read(ttsServiceProvider);
    await ref.read(sttServiceProvider).stopListening();
    if (!mounted || session != _voiceLoopSession || !_lessonPlaying) return;

    // Safety net: never let a play action fall straight through to "end of
    // lesson". If segmentation produced nothing (e.g. a lesson whose text was
    // only headings/separators), speak the raw lesson text once instead of
    // silently ending.
    if (_lessonSegments.isEmpty) {
      final lesson = _currentLesson();
      final raw = lesson?.rawText.trim() ?? '';
      if (raw.isEmpty) {
        if (mounted) setState(() => _lessonPlaying = false);
        unawaited(_announceAndListen(
            'This lesson has no content to read yet.'));
        return;
      }
      final ok = await tts.speakAndWait(raw);
      if (!mounted || session != _voiceLoopSession || !_lessonPlaying) return;
      if (ok && lesson != null) unawaited(_recordLessonCompleted(lesson.id));
      if (mounted) setState(() => _lessonPlaying = false);
      unawaited(_announceAndListen(
        'End of lesson. Say quiz for the questions, repeat to hear it again, '
        'or next for the next topic.',
      ));
      return;
    }

    // A stale index past the end (e.g. resuming a finished lesson) should
    // replay from the start, not instantly report "end of lesson".
    if (startIndex >= _lessonSegments.length) {
      startIndex = 0;
      startCharOffset = 0;
    }

    for (var i = startIndex; i < _lessonSegments.length; i++) {
      if (!mounted || session != _voiceLoopSession || !_lessonPlaying) return;
      _lessonSegmentIndex = i;

      // Only the first segment of a resume starts partway through; every
      // later segment plays in full from its beginning.
      final segmentText = _lessonSegments[i].text;
      final base = (i == startIndex)
          ? startCharOffset.clamp(0, segmentText.length)
          : 0;
      final toSpeak = base == 0 ? segmentText : segmentText.substring(base);

      final completed = await tts.speakAndWait(toSpeak);

      // Interrupted (paused, navigated, or superseded): remember exactly where
      // so the next play resumes from this word, not the segment start.
      if (!mounted || session != _voiceLoopSession || !_lessonPlaying) {
        _lessonSegmentIndex = i;
        _pausedCharOffset = base + tts.spokenWordStart;
        return;
      }
      if (!completed) {
        // Engine error mid-segment — stop cleanly rather than skipping ahead.
        return;
      }

      _lessonSegmentIndex = i + 1;
      _pausedCharOffset = 0;

      // Natural pause after a sentence group / paragraph / heading — what makes
      // the reading sound human instead of one breathless block. Honour pause
      // and navigation during the gap so it never feels laggy to stop.
      final gap = _lessonSegments[i].pauseAfter;
      if (gap > Duration.zero && i + 1 < _lessonSegments.length) {
        await Future<void>.delayed(gap);
        if (!mounted || session != _voiceLoopSession || !_lessonPlaying) return;
      }
    }

    // Reached the end naturally — the student has listened to the whole
    // lesson, so record it as completed before resetting position.
    final finishedLesson = _currentLesson();
    if (finishedLesson != null) {
      unawaited(_recordLessonCompleted(finishedLesson.id));
    }

    // Reset to the start and reopen the mic so the student can say "quiz",
    // "repeat", or "next".
    _pausedCharOffset = 0;
    _lessonSegmentIndex = 0;
    if (mounted) setState(() => _lessonPlaying = false);
    if (!mounted || session != _voiceLoopSession) return;
    unawaited(_announceAndListen(
      'End of lesson. Say quiz for the questions, repeat to hear it again, '
      'or next for the next topic.',
    ));
  }

  /// Speaks [label] (e.g. a speed-change confirmation) then continues the
  /// lesson from the current segment, so adjusting speed mid-lesson resumes
  /// where the student was instead of restarting.
  Future<void> _announceThenResumeLesson(int session, String label) async {
    final tts = ref.read(ttsServiceProvider);
    await ref.read(sttServiceProvider).stopListening();
    if (!mounted || session != _voiceLoopSession) return;
    await tts.speakAndWait(label);
    if (!mounted || session != _voiceLoopSession || !_lessonPlaying) return;
    await _playLessonFrom(
      session,
      _lessonSegmentIndex,
      startCharOffset: _pausedCharOffset,
    );
  }

  void _openQuizConfirmation() {
    setState(() {
      _stage = LearningStage.quizConfirm;
    });
    _announceCurrentState(force: true);
  }

  void _startQuiz() {
    final lesson = _currentLesson();
    if (lesson == null) {
      unawaited(_announceAndListen('No questions available.'));
      return;
    }

    final questions = _questionsForLesson(lesson);
    if (questions.isEmpty) {
      unawaited(_announceAndListen('No questions available.'));
      return;
    }

    setState(() {
      _stage = LearningStage.quiz;
      _questionIndex = 0;
      _answerIndex = 0;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    // Instructions are spoken ONCE here, then every question announcement is
    // just "Question N of M + the highlighted option". Repeating the "swipe /
    // double tap" guidance on all M questions drowned the actual content —
    // by ear, redundancy is cost, not reassurance. "Help" re-speaks it.
    _announcementKey =
        'quiz:$_subjectIndex:$_topicIndex:0:0:false:false';
    unawaited(_announceSequenceAndListen([
      _quizInstructionsText(questions.length),
      _announcementText(),
    ]));
  }

  /// The one-time (and on-demand, via "help") spoken quiz instructions.
  String _quizInstructionsText(int total) {
    return 'The questions are starting. There are $total. For each one, '
        'swipe left or right to hear the answer choices, then double tap '
        'to choose. Say help to hear these instructions again.';
  }

  void _moveQuizAnswer(int delta) {
    final question = _currentQuizQuestion();
    if (question == null || _quizAnswered || _quizComplete) return;

    final options = _quizOptions(question);
    if (options.isEmpty) return;

    setState(() {
      _answerIndex = (_answerIndex + delta) % options.length;
      if (_answerIndex < 0) _answerIndex = options.length - 1;
    });

    unawaited(_announceAndListen(
        'Option ${_answerIndex + 1}. ${options[_answerIndex].text}'));
  }

  Future<void> _selectQuizAnswer() async {
    final question = _currentQuizQuestion();
    if (question == null) return;

    final options = _quizOptions(question);
    if (options.isEmpty) return;

    if (_quizAnswered) {
      if (_questionIndex >= _questionsCount() - 1) {
        setState(() {
          _stage = LearningStage.lesson;
          _quizComplete = false;
          _quizAnswered = false;
        });
        _announceCurrentState(force: true);
        return;
      }
      _nextQuizQuestion();
      return;
    }

    final selected = options[_answerIndex.clamp(0, options.length - 1)];
    final selectedIndex = options.indexOf(selected);
    final boundedIndex = selectedIndex < 0
        ? 0
        : selectedIndex > 3
            ? 3
            : selectedIndex;
    final selectedLetter = const ['A', 'B', 'C', 'D'][boundedIndex];

    setState(() {
      _quizAnswered = true;
    });

    final correct = question.correctOption.toUpperCase() == selectedLetter;
    if (correct) _score += 1;
    _voiceQuestionsAnswered += 1;
    unawaited(_recordQuizResult(question.id, correct));
    _logVoiceEvent(
      'answer',
      'Option ${_answerIndex + 1}: ${selected.text}',
      correct ? 'Correct' : 'Incorrect',
    );

    // Distinct tactile confirmation so the result is felt as well as heard.
    unawaited(
      correct ? HapticFeedback.mediumImpact() : HapticFeedback.heavyImpact(),
    );

    // Speak corrective feedback, not just "Incorrect." A blind student can't
    // glance back at the options to see what they missed, so on a wrong answer
    // read out the correct option (and the lesson explanation when it adds
    // something beyond restating that option) — turning the quiz into a
    // learning moment delivered entirely through audio.
    final feedback = StringBuffer(correct ? 'Correct.' : 'Incorrect.');
    if (!correct) {
      final letter = question.correctOption.toUpperCase();
      final correctIndex = const ['A', 'B', 'C', 'D'].indexOf(letter);
      final correctText = (switch (letter) {
        'A' => question.optionA,
        'B' => question.optionB,
        'C' => question.optionC,
        'D' => question.optionD ?? '',
        _ => '',
      })
          .trim();
      if (correctIndex >= 0 && correctText.isNotEmpty) {
        feedback.write(
            ' The correct answer is option ${correctIndex + 1}. $correctText.');
      }
      // Speak the explanation whenever it adds something — i.e. it isn't simply
      // a restatement of the option we just read out. (A good explanation is
      // the source sentence, which gives the student the surrounding context.)
      final explanation = question.explanation.trim();
      String norm(String s) =>
          s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (explanation.isNotEmpty && norm(explanation) != norm(correctText)) {
        feedback.write(' $explanation.');
      }
    }

    final messages = <String>[feedback.toString()];
    final isLast = _questionIndex >= _questionsCount() - 1;
    if (isLast) {
      setState(() => _quizComplete = true);
      messages.add('Quiz complete. Score $_score of ${_questionsCount()}.');
      // Gesture-only guidance (no command words to echo back).
      messages.add('Double tap to return to the lesson.');
    } else {
      messages.add('Double tap to go on.');
    }

    await _announceSequenceAndListen(messages);
  }

  void _nextQuizQuestion() {
    final total = _questionsCount();
    if (total == 0) return;

    if (_questionIndex >= total - 1) {
      setState(() {
        _quizComplete = true;
      });
      unawaited(_announceAndListen('Quiz complete. Score $_score of $total.'));
      return;
    }

    setState(() {
      _questionIndex += 1;
      _answerIndex = 0;
      _quizAnswered = false;
      _quizComplete = false;
    });
    _announceCurrentState(force: true);
  }

  Widget _stageCard({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required String hint,
    String? progress,
    String? actionLabel,
    String? body,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.18),
            accent.withValues(alpha: 0.05)
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: 40),
          ),
          const SizedBox(height: 16),
          if (progress != null) ...[
            Text(
              progress,
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: accent,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 16),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              actionLabel ?? hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String message, IconData icon) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: const Color(0xFF1A56DB)),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A56DB),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubjectsStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];

    return _stageCard(
      icon: Icons.school_rounded,
      accent: const Color(0xFF1A56DB),
      title: subject.name,
      subtitle: 'Subjects',
      progress: '${_subjectIndex + 1} of ${subjects.length}',
      actionLabel: 'Double tap to open',
      hint:
          'Swipe right for next. Swipe left for previous. Double tap to open.',
    );
  }

  Widget _buildTopicsStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return _stageCard(
      icon: Icons.layers_rounded,
      accent: const Color(0xFF059669),
      title: topic.name,
      subtitle: '${subject.name} topics',
      progress: '${_topicIndex + 1} of ${topics.length}',
      actionLabel: 'Double tap to open lesson',
      hint:
          'Swipe right for next. Swipe left for previous. Double tap to open.',
    );
  }

  Widget _buildLessonStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return _stageCard(
              icon: _lessonPlaying
                  ? Icons.pause_circle_rounded
                  : Icons.play_circle_rounded,
              accent: const Color(0xFF7C3AED),
              title: topic.name,
              subtitle: 'Ready to play',
              body: lesson.rawText.length > 220
                  ? '${lesson.rawText.substring(0, 220)}...'
                  : lesson.rawText,
              actionLabel:
                  _lessonPlaying ? 'Double tap to pause' : 'Double tap to play',
              hint:
                  'Swipe right for next topic. Swipe left for previous. Swipe up to replay. Swipe down for quiz.',
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _emptyState(
              'Could not load lesson.', Icons.error_outline_rounded),
        );
  }

  Widget _buildQuizConfirmStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return _stageCard(
              icon: Icons.quiz_rounded,
              accent: const Color(0xFF0EA5E9),
              title: 'Go to quiz',
              subtitle: topic.name,
              actionLabel: 'Double tap to confirm',
              hint: 'Double tap to confirm. Swipe up to return.',
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) =>
              _emptyState('Could not load quiz.', Icons.error_outline_rounded),
        );
  }

  Widget _buildQuizStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return ref.watch(lessonQuestionsProvider(lesson.id)).when(
                  data: (questions) {
                    if (questions.isEmpty) {
                      return _emptyState(
                          'No questions available.', Icons.quiz_outlined);
                    }

                    if (_questionIndex >= questions.length) {
                      _questionIndex = questions.length - 1;
                    }
                    final question = questions[_questionIndex];
                    final options = _quizOptions(question);
                    if (options.isEmpty) {
                      return _emptyState(
                          'No answer options.', Icons.quiz_outlined);
                    }

                    _answerIndex = _answerIndex.clamp(0, options.length - 1);
                    final current = options[_answerIndex];

                    return _stageCard(
                      icon: Icons.quiz_rounded,
                      accent: const Color(0xFF1A56DB),
                      title:
                          'Question ${_questionIndex + 1} of ${questions.length}',
                      subtitle: question.questionText,
                      body: _quizAnswered
                          ? (_quizComplete
                              ? 'Quiz complete. Score $_score of ${questions.length}.'
                              : 'Swipe right for next question.')
                          : 'Option ${current.label}. ${current.text}',
                      actionLabel: _quizComplete
                          ? 'Double tap to return to lesson'
                          : 'Double tap to select answer',
                      hint: _quizAnswered
                          ? 'Swipe right for next question. Swipe left for previous question.'
                          : 'Swipe right for next answer. Swipe left for previous answer. Double tap to select.',
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) => _emptyState(
                      'Could not load quiz.', Icons.error_outline_rounded),
                );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _emptyState(
              'Could not load lesson.', Icons.error_outline_rounded),
        );
  }

  void _onSwipeRight() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    switch (_stage) {
      case LearningStage.subjects:
        _moveSubject(1);
        break;
      case LearningStage.topics:
        _moveTopic(1);
        break;
      case LearningStage.lesson:
        _moveTopic(1);
        break;
      case LearningStage.quizConfirm:
        break;
      case LearningStage.quiz:
        if (_quizAnswered) {
          _nextQuizQuestion();
        } else {
          _moveQuizAnswer(1);
        }
        break;
    }
  }

  void _onSwipeLeft() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    switch (_stage) {
      case LearningStage.subjects:
        _moveSubject(-1);
        break;
      case LearningStage.topics:
        _moveTopic(-1);
        break;
      case LearningStage.lesson:
        _moveTopic(-1);
        break;
      case LearningStage.quizConfirm:
        setState(() => _stage = LearningStage.lesson);
        _announceCurrentState(force: true);
        break;
      case LearningStage.quiz:
        if (_quizAnswered) {
          if (_questionIndex > 0) {
            setState(() {
              _questionIndex -= 1;
              _answerIndex = 0;
              _quizAnswered = false;
              _quizComplete = false;
            });
            _announceCurrentState(force: true);
          }
        } else {
          _moveQuizAnswer(-1);
        }
        break;
    }
  }

  void _onSwipeUp() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    if (_stage == LearningStage.lesson) {
      _replayLesson();
    } else if (_stage == LearningStage.quizConfirm) {
      setState(() => _stage = LearningStage.lesson);
      _announceCurrentState(force: true);
    }
  }

  void _onSwipeDown() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    if (_stage == LearningStage.lesson) {
      _openQuizConfirmation();
    }
  }

  void _onDoubleTap() {
    _silentWindows = 0;
    HapticFeedback.selectionClick();
    switch (_stage) {
      case LearningStage.subjects:
        _openCurrentSubject();
        break;
      case LearningStage.topics:
        _openCurrentTopic();
        break;
      case LearningStage.lesson:
        _toggleLessonPlayback();
        break;
      case LearningStage.quizConfirm:
        _startQuiz();
        break;
      case LearningStage.quiz:
        _selectQuizAnswer();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(allSubjectsProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (_stage == LearningStage.quiz) {
          setState(() {
            _stage = LearningStage.lesson;
            _quizAnswered = false;
            _quizComplete = false;
            _score = 0;
          });
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.quizConfirm) {
          setState(() => _stage = LearningStage.lesson);
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.lesson) {
          unawaited(_endVoiceSession());
          setState(() => _stage = LearningStage.topics);
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.topics) {
          setState(() => _stage = LearningStage.subjects);
          _announceCurrentState(force: true);
        } else {
          context.go('/role');
        }
      },
      child: Scaffold(
        body: Listener(
          // Raw pointer tracking for the two-finger "faster" tap; it observes
          // without claiming gestures, so everything below still works.
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _onDoubleTap,
          onLongPress: _onLongPress,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity > 120) {
              _onSwipeRight();
            } else if (velocity < -120) {
              _onSwipeLeft();
            }
          },
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity > 120) {
              _onSwipeDown();
            } else if (velocity < -120) {
              _onSwipeUp();
            }
          },
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF5F9FF),
                  Color(0xFFE7F0FF),
                  Color(0xFFF6F7FB),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF1A56DB).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.headphones_rounded,
                            color: Color(0xFF1A56DB),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Audio Learning Hub',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF123B7A),
                            ),
                          ),
                        ),
                        if (_cloudSyncing) ...[
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                        ],
                        _buildProgressButton(),
                        const SizedBox(width: 8),
                        _buildJoinClassButton(),
                        const SizedBox(width: 8),
                        _stageChip(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        // Keying on `_stage` (not the rebuilt subtree
                        // itself) means a provider invalidation that leaves
                        // the stage unchanged updates this subtree in place
                        // instead of cross-fading — avoiding a transition
                        // mid-dispose while a provider it depends on is also
                        // being torn down/rebuilt.
                        child: KeyedSubtree(
                          key: ValueKey(_stage),
                          child: _buildBody(subjectsAsync),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Text(
                        _footerHint(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF355CA8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  /// Header entry point into the "My Progress" screen. Mirrors the spoken
  /// "my progress" voice command so the feature is reachable by touch too.
  Widget _buildProgressButton() {
    return Tooltip(
      message: 'My progress',
      child: Material(
        color: const Color(0xFF16A34A).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _openProgress,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(
              Icons.insights_rounded,
              color: Color(0xFF16A34A),
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  /// Header entry point into the voice-guided "join your class" flow. Always
  /// visible — joining (or leaving/rejoining) a class is how cloud lessons
  /// start flowing into this device, so it must never be a buried setting.
  Widget _buildJoinClassButton() {
    return Tooltip(
      message: 'Join your class with a class code',
      child: Material(
        color: const Color(0xFF1A56DB).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _openJoinClassFlow,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(
              Icons.group_add_rounded,
              color: Color(0xFF1A56DB),
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  Widget _stageChip() {
    final label = switch (_stage) {
      LearningStage.subjects => 'Subjects',
      LearningStage.topics => 'Topics',
      LearningStage.lesson => 'Lesson',
      LearningStage.quizConfirm => 'Quiz',
      LearningStage.quiz => 'Question',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A56DB).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF1A56DB),
        ),
      ),
    );
  }

  String _footerHint() {
    return switch (_stage) {
      LearningStage.subjects =>
        'Swipe right for next. Swipe left for previous. Double tap to open. '
            'Tap the chart icon for your progress.',
      LearningStage.topics =>
        'Swipe right for next. Swipe left for previous. Double tap to open.',
      LearningStage.lesson =>
        'Double tap to play or pause. Swipe up to replay. Swipe down for quiz. '
            'Hold to read slower. Two-finger tap to read faster.',
      LearningStage.quizConfirm =>
        'Double tap to confirm quiz. Swipe up to return.',
      LearningStage.quiz => _quizAnswered
          ? 'Swipe right for next question. Swipe left for previous question.'
          : 'Swipe right for next answer. Swipe left for previous answer. Double tap to select.',
    };
  }

  Widget _buildBody(AsyncValue<List<Subject>> subjectsAsync) {
    return subjectsAsync.when(
      data: (subjects) {
        // `_topicsForSubject`, `_lessonForTopic`, and `_questionsForLesson`
        // all read their providers via `ref.read`, which never triggers a
        // rebuild on its own. Watching them here for the currently selected
        // subject/topic/lesson keeps each autoDispose family provider alive
        // and rebuilds this widget once its data finishes loading —
        // otherwise a provider nothing watches gets disposed before its data
        // can ever reach the UI (or a gesture handler reading it via
        // `ref.read` right after a stage change), so topics, lessons, and
        // quizzes would never appear.
        if (subjects.isNotEmpty) {
          final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
          final topics =
              ref.watch(subjectTopicsProvider(subject.id)).valueOrNull ??
                  const [];
          if (topics.isNotEmpty) {
            final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
            final lesson =
                ref.watch(topicLessonProvider(topic.id)).valueOrNull;
            if (lesson != null) {
              ref.watch(lessonQuestionsProvider(lesson.id));
            }
          }
        }
        _clampIndices();
        return switch (_stage) {
          LearningStage.subjects => _buildSubjectsStage(subjects),
          LearningStage.topics => _buildTopicsStage(subjects),
          LearningStage.lesson => _buildLessonStage(subjects),
          LearningStage.quizConfirm => _buildQuizConfirmStage(subjects),
          LearningStage.quiz => _buildQuizStage(subjects),
        };
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) =>
          _emptyState('Could not load subjects.', Icons.error_outline_rounded),
    );
  }
}

class _QuizOption {
  const _QuizOption({required this.label, required this.text});

  final String label;
  final String text;
}

// ─────────────────────────────────────────────────────────────────────────────
// Join-class dialog — voice-guided, code-based class linking
//
// This is the proposed login bridge made real for students: Class Teacher
// creates a class and gets a code → Subject Teacher and Student both join
// using that same class-teacher code. A student here never sees or types a
// password — one is generated on-device and stored only locally
// (BackendLinkService.linkStudentAccount). Visual text mirrors every spoken
// prompt for sighted helpers / low-vision students. Once linked, the learning
// hub automatically pulls the class's cloud lessons into local storage, which
// is what turns "no subjects available" into a populated subject list.
// ─────────────────────────────────────────────────────────────────────────────

enum _JoinStage {
  loading,
  alreadyLinked,
  intro,
  askName,
  confirmName,
  askCode,
  confirmCode,
  linking,
  success,
  error,
}

class _JoinClassDialog extends ConsumerStatefulWidget {
  final Student student;
  const _JoinClassDialog({required this.student});

  @override
  ConsumerState<_JoinClassDialog> createState() => _JoinClassDialogState();
}

class _JoinClassDialogState extends ConsumerState<_JoinClassDialog> {
  static const _baseUrl = kDefaultBackendBaseUrl;

  _JoinStage _stage = _JoinStage.loading;
  String _statusText = 'Checking your class link…';
  String _spokenName = '';
  String _spokenCode = '';
  StudentLinkInfo? _existingLink;
  int _session = 0;
  final TextEditingController _codeController = TextEditingController();

  // Captured while `ref` is valid — never touch `ref` in dispose().
  late final SttService _stt;

  @override
  void initState() {
    super.initState();
    _stt = ref.read(sttServiceProvider);
    _bootstrap();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _stt.stopListening();
    super.dispose();
  }

  Future<void> _say(String text) async {
    if (!mounted) return;
    setState(() => _statusText = text);
    await ref.read(ttsServiceProvider).speakAndWait(text);
  }

  Future<void> _bootstrap() async {
    await ref.read(ttsInitProvider.future);
    final link = ref.read(backendLinkServiceProvider);
    final existing = await link.getStudentLink(widget.student.id);
    if (!mounted) return;

    if (existing != null) {
      setState(() {
        _stage = _JoinStage.alreadyLinked;
        _existingLink = existing;
        _statusText = 'You are already part of a class.';
      });
      await _say(
        'You are already linked to a class. Tap leave class if you want to '
        'join a different one, or close to go back.',
      );
      return;
    }

    final stt = ref.read(sttServiceProvider);
    final ready = await stt.initialize();
    if (!mounted) return;

    if (!ready) {
      setState(() {
        _stage = _JoinStage.error;
        _statusText =
            'Voice recognition is unavailable on this device. Ask your '
            'teacher to link your class from their dashboard instead.';
      });
      return;
    }

    // Reuse the name the student already gave at login instead of asking for
    // it again (that second prompt felt like the login was looping back).
    if (widget.student.name.trim().isEmpty) {
      setState(() => _stage = _JoinStage.intro);
      await _say('Let\'s join your class. First, what is your name?');
      if (!mounted) return;
      await _beginNameCapture();
    } else {
      _spokenName = widget.student.name;
      setState(() => _stage = _JoinStage.intro);
      await _say(
        'Let\'s join your class, ${widget.student.name}. '
        'I just need your class code.',
      );
      if (!mounted) return;
      await _beginCodeCapture();
    }
  }

  // ── Generic capture helper: speak a prompt, listen once, hand off result ──

  Future<void> _captureSpeech({
    required String prompt,
    required _JoinStage listeningStage,
    required Future<void> Function(String heard) onHeard,
    required Future<void> Function() onUnclear,
  }) async {
    if (!mounted) return;
    final session = ++_session;
    final tts = ref.read(ttsServiceProvider);
    final stt = ref.read(sttServiceProvider);

    setState(() => _stage = listeningStage);
    await tts.speakAndWait(prompt);
    if (!mounted || session != _session) return;
    // Settle gap: let the prompt's audio tail drain before the mic opens, so
    // the recogniser doesn't transcribe our own example ("S C, 4 2 7 1") as
    // the student's answer.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || session != _session) return;

    var handled = false;
    var lastPartial = '';
    setState(() => _statusText = 'Listening… speak now.');

    stt.startListening(
      // Many Android recognizers end a session WITHOUT a final result and
      // send only partials. Without this fallback, every capture attempt on
      // such devices ended in "I didn't catch that" forever — field test:
      // a student could never join a class by voice.
      onPartial: (words) {
        if (words.trim().isNotEmpty) lastPartial = words.trim();
      },
      onResult: (words) {
        if (handled || session != _session) return;
        final trimmed = words.trim();
        if (trimmed.isEmpty) return;
        handled = true;
        unawaited(onHeard(trimmed));
      },
      onDone: () {
        if (handled || session != _session) return;
        handled = true;
        if (lastPartial.isNotEmpty) {
          unawaited(onHeard(lastPartial));
        } else {
          unawaited(onUnclear());
        }
      },
    );
  }

  // ── Step 1: name ──────────────────────────────────────────────────────────

  Future<void> _beginNameCapture() async {
    await _captureSpeech(
      prompt: 'What is your name? Say it clearly after the beep.',
      listeningStage: _JoinStage.askName,
      onHeard: (heard) async {
        await ref.read(sttServiceProvider).stopListening();
        if (!mounted) return;
        final name = _toTitleCase(heard);
        setState(() {
          _spokenName = name;
          _stage = _JoinStage.confirmName;
        });
        await _say(
          'I heard $name. Tap once if that is right. Tap twice to say it again.',
        );
      },
      onUnclear: () async {
        if (!mounted) return;
        await _say('I didn\'t catch that. Let\'s try again.');
        await _beginNameCapture();
      },
    );
  }

  void _confirmName({required bool correct}) {
    if (correct) {
      unawaited(_beginCodeCapture());
    } else {
      unawaited(_beginNameCapture());
    }
  }

  // ── Step 2: class code ───────────────────────────────────────────────────

  Future<void> _beginCodeCapture() async {
    await _captureSpeech(
      prompt: 'Now ask your teacher for your class code, and say it now, '
          'one character at a time: S, C, dash, then the four letters or '
          'numbers. A helper can also type it in the box on the screen.',
      listeningStage: _JoinStage.askCode,
      onHeard: (heard) async {
        await ref.read(sttServiceProvider).stopListening();
        if (!mounted) return;
        final code = _normalizeCode(heard);
        setState(() {
          _spokenCode = code;
          _stage = _JoinStage.confirmCode;
        });
        await _say(
          'I heard the code ${_spellOut(code)}. Tap once if that is right. '
          'Tap twice to say it again.',
        );
      },
      onUnclear: () async {
        if (!mounted) return;
        await _say('I didn\'t catch the code. Let\'s try again.');
        await _beginCodeCapture();
      },
    );
  }

  void _confirmCode({required bool correct}) {
    if (correct) {
      unawaited(_finishLinking());
    } else {
      unawaited(_beginCodeCapture());
    }
  }

  /// Typed-code fallback for when voice capture keeps failing (noisy room,
  /// no offline recognizer, unusual accent for letter names). A sighted
  /// helper or the teacher types the code exactly; no spoken confirm loop is
  /// needed because typing is already deliberate.
  Future<void> _useTypedCode() async {
    final typed = _codeController.text.trim();
    if (typed.isEmpty) return;
    _session++; // cancel any in-flight voice capture callbacks
    await ref.read(sttServiceProvider).stopListening();
    if (!mounted) return;
    setState(() => _spokenCode = _normalizeCode(typed));
    await _finishLinking();
  }

  // ── Step 3: link the account (silent network step) ───────────────────────

  /// A class code is `SC-` or `TC-` plus exactly four letters/digits. Checked
  /// BEFORE any network call: a mis-heard code used to travel all the way to
  /// the server (possibly through a 40-second cold start) only to bounce with
  /// a validation error — the student waited in silence for a rejection we
  /// could have spoken immediately.
  static final RegExp _codeShape = RegExp(r'^(SC|TC)-[A-Z0-9]{4}$');

  Future<void> _finishLinking() async {
    if (!mounted) return;

    if (!_codeShape.hasMatch(_spokenCode)) {
      setState(() => _stage = _JoinStage.confirmCode);
      await _say(
        'That code doesn\'t sound complete. A class code is S C or T C, '
        'dash, then exactly four letters or numbers — like S C dash 9 F X 2. '
        'Let\'s try the code again.',
      );
      if (!mounted) return;
      await _beginCodeCapture();
      return;
    }

    setState(() => _stage = _JoinStage.linking);

    // Wake the free-tier server BEFORE registering, with honest feedback —
    // the first request after ~15 idle minutes takes 30-60 seconds, and a
    // blind student left in silence that long assumes the app is broken
    // (field report: a student's join "failed" during exactly this window).
    final api = ref.read(backendApiServiceProvider);
    await _say('Joining your class. If the school server is asleep, '
        'this can take up to a minute. Please hold on…');
    final awake = await api.warmUp(baseUrl: _baseUrl);
    if (!mounted) return;
    if (!awake) {
      setState(() {
        _stage = _JoinStage.error;
        _statusText = 'Could not reach the class server.';
      });
      await _say(
        'I could not reach the class server. Make sure this phone has '
        'internet, then tap try again. Your lessons on this phone still '
        'work without the class link.',
      );
      return;
    }

    try {
      final link = ref.read(backendLinkServiceProvider);
      final result = await link.linkStudentAccount(
        localStudentId: widget.student.id,
        baseUrl: _baseUrl,
        fullName: _spokenName,
        studentCode: _spokenCode,
      );
      if (!mounted) return;
      setState(() {
        _existingLink = result;
        _stage = _JoinStage.success;
      });
      await _say(
        'You\'re in! Your progress will now be saved to your class, and your '
        'teacher\'s lessons will start appearing in your subjects. '
        'Tap anywhere to continue learning.',
      );
    } on BackendApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _JoinStage.error;
        _statusText = e.message;
      });
      await _say(
        'I could not join the class. ${e.message}. '
        'Tap try again, or ask your teacher for help.',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _JoinStage.error;
        _statusText = 'Something went wrong while joining the class.';
      });
      await _say(
        'Something went wrong while joining the class. '
        'Tap try again, or ask your teacher for help.',
      );
    }
  }

  Future<void> _unlink() async {
    final link = ref.read(backendLinkServiceProvider);
    await link.forgetStudentLink(widget.student.id);
    if (!mounted) return;
    setState(() {
      _existingLink = null;
      _stage = _JoinStage.intro;
    });
    await _say(
      'You\'ve left your class. Tap anywhere when you\'re ready to join a new one.',
    );
  }

  Future<void> _retryFromError() async {
    // Keep the name we already have (from login or the earlier capture) so a
    // retry after a network hiccup goes straight back to the class code
    // instead of restarting the whole interview.
    final knownName = _spokenName.trim().isNotEmpty
        ? _spokenName
        : widget.student.name.trim();
    setState(() {
      _stage = _JoinStage.intro;
      _spokenName = knownName;
      _spokenCode = '';
    });
    if (knownName.isNotEmpty) {
      await _say('Let\'s try again.');
      if (!mounted) return;
      await _beginCodeCapture();
    } else {
      await _say('Let\'s try again. Tap anywhere when you\'re ready to begin.');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _toTitleCase(String input) {
    final words = input.trim().split(RegExp(r'\s+'));
    return words
        .where((w) => w.isNotEmpty)
        .map((w) =>
            w[0].toUpperCase() +
            (w.length > 1 ? w.substring(1).toLowerCase() : ''))
        .join(' ');
  }

  /// Turns whatever the speech engine heard into a best-guess class code.
  /// Codes follow the shape `SC-XXXX`; this converts spoken digit words
  /// ("four" -> "4") and spoken letter names ("ess"/"see" -> "S"/"C"),
  /// strips remaining punctuation, uppercases, and re-inserts the dash so
  /// common spoken variants ("S C 4 2 7 1", "es see four two seven one",
  /// "S C dash 4 2 7 1", "sc4271") all converge.
  static String _normalizeCode(String raw) {
    final tokens = raw
        .toLowerCase()
        .split(RegExp(r'[\s\-_,]+'))
        .where((t) => t.isNotEmpty);

    final buffer = StringBuffer();
    for (final token in tokens) {
      final cleaned = token.replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (cleaned.isEmpty || cleaned == 'dash' || cleaned == 'hyphen') {
        continue;
      }

      final digit = _digitFromWord(cleaned);
      if (digit != null) {
        buffer.write(digit);
        continue;
      }

      final letter = _letterFromWord(cleaned);
      if (letter != null) {
        buffer.write(letter);
        continue;
      }

      buffer.write(cleaned.toUpperCase());
    }

    final cleaned = buffer.toString();
    if (cleaned.length > 2) {
      final prefix = cleaned.substring(0, 2);
      final rest = cleaned.substring(2);
      if (prefix == 'SC' || prefix == 'TC') {
        return '$prefix-$rest';
      }
    }
    return cleaned.isEmpty ? raw.trim().toUpperCase() : cleaned;
  }

  /// Maps a spoken digit word (or numeral) to its single-character digit.
  static String? _digitFromWord(String token) {
    final numeric = int.tryParse(token);
    if (numeric != null && numeric >= 0 && numeric <= 9) {
      return numeric.toString();
    }

    switch (token) {
      case 'zero':
      case 'oh':
      case 'o':
        return '0';
      case 'one':
      case 'won':
        return '1';
      case 'two':
      case 'too':
      case 'to':
        return '2';
      case 'three':
        return '3';
      case 'four':
      case 'for':
        return '4';
      case 'five':
        return '5';
      case 'six':
        return '6';
      case 'seven':
        return '7';
      case 'eight':
      case 'ate':
        return '8';
      case 'nine':
        return '9';
    }

    return null;
  }

  /// Maps a spoken letter name to the letter it represents. Class codes are
  /// `SC-`/`TC-` plus FOUR RANDOM CHARACTERS from the full A–Z, 0–9 alphabet
  /// (the backend's `generate_student_code`), so every letter name must be
  /// recognisable — a code like SC-MFQ8 was impossible to say before this
  /// covered more than S, C and T. Digit homophones ("oh"→0, "for"→4) are
  /// resolved first by [_digitFromWord], so they never reach this table.
  static String? _letterFromWord(String token) {
    switch (token) {
      case 'a':
      case 'ay':
        return 'A';
      case 'b':
      case 'be':
      case 'bee':
        return 'B';
      case 'c':
      case 'see':
      case 'sea':
      case 'si':
      case 'cee':
        return 'C';
      case 'd':
      case 'de':
      case 'dee':
        return 'D';
      case 'e':
      case 'ee':
        return 'E';
      case 'f':
      case 'ef':
      case 'eff':
        return 'F';
      case 'g':
      case 'gee':
      case 'ji':
        return 'G';
      case 'h':
      case 'aitch':
      case 'haitch':
      case 'age':
        return 'H';
      case 'i':
      case 'eye':
      case 'aye':
        return 'I';
      case 'j':
      case 'jay':
      case 'jae':
        return 'J';
      case 'k':
      case 'kay':
      case 'cay':
        return 'K';
      case 'l':
      case 'el':
      case 'ell':
        return 'L';
      case 'm':
      case 'em':
        return 'M';
      case 'n':
      case 'en':
        return 'N';
      case 'p':
      case 'pee':
      case 'pea':
        return 'P';
      case 'q':
      case 'cue':
      case 'queue':
      case 'kyu':
        return 'Q';
      case 'r':
      case 'ar':
      case 'are':
        return 'R';
      case 's':
      case 'ess':
      case 'es':
      case 'as':
        return 'S';
      case 't':
      case 'tee':
      case 'ti':
      case 'tea':
        return 'T';
      case 'u':
      case 'you':
      case 'yu':
        return 'U';
      case 'v':
      case 'vee':
      case 've':
        return 'V';
      case 'w':
        return 'W';
      case 'x':
      case 'ex':
        return 'X';
      case 'y':
      case 'why':
        return 'Y';
      case 'z':
      case 'zee':
      case 'zed':
        return 'Z';
    }

    return null;
  }

  /// Spells a code out character by character for an unambiguous read-back,
  /// e.g. "SC-4271" -> "S, C, dash, 4, 2, 7, 1".
  static String _spellOut(String code) {
    return code.split('').map((c) => c == '-' ? 'dash' : c).join(', ');
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onDoubleTap: _handleDoubleTap,
      child: AlertDialog(
        title: const Text('Join your class'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_stage == _JoinStage.loading ||
                  _stage == _JoinStage.linking) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 14),
              ],
              Text(
                _statusText,
                style: const TextStyle(fontSize: 16, height: 1.4),
              ),
              if (_stage == _JoinStage.confirmName ||
                  _stage == _JoinStage.confirmCode) ...[
                const SizedBox(height: 14),
                Text(
                  'Tap once: yes, that\'s right.   Tap twice: try again.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
              // Typed fallback: voice capture of a spelled code can fail in a
              // noisy room or without a recognizer. A sighted helper types the
              // code exactly as the teacher shared it (e.g. SC-MFQ8).
              if (_stage == _JoinStage.askCode ||
                  _stage == _JoinStage.confirmCode ||
                  _stage == _JoinStage.error) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Or type the class code',
                    hintText: 'e.g. SC-4B7K',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _useTypedCode(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _useTypedCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A56DB),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Join with typed code'),
                  ),
                ),
              ],
              if (_stage == _JoinStage.intro) ...[
                const SizedBox(height: 14),
                Text(
                  'Listening for your name…',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
              if (_stage == _JoinStage.success && _existingLink != null) ...[
                const SizedBox(height: 14),
                Text(
                  'Class joined. You can close this and keep learning.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
              if (_stage == _JoinStage.error) ...[
                const SizedBox(height: 14),
                Text(
                  'Tap once to try again.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
        actions: _buildActions(context),
      ),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    switch (_stage) {
      case _JoinStage.alreadyLinked:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: _unlink,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Leave class'),
          ),
        ];
      case _JoinStage.success:
        return [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A56DB),
              foregroundColor: Colors.white,
            ),
            child: const Text('Done'),
          ),
        ];
      case _JoinStage.loading:
      case _JoinStage.linking:
        return const [];
      default:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ];
    }
  }

  // ── Tap routing — every screen-tap doubles as a voice-flow control ───────

  void _handleTap() {
    switch (_stage) {
      case _JoinStage.intro:
        unawaited(_beginNameCapture());
        break;
      case _JoinStage.confirmName:
        _confirmName(correct: true);
        break;
      case _JoinStage.confirmCode:
        _confirmCode(correct: true);
        break;
      case _JoinStage.error:
        unawaited(_retryFromError());
        break;
      case _JoinStage.success:
        // The success prompt says "tap anywhere to continue" — honour it.
        // Closing the dialog hands control back to the hub, which starts the
        // cloud sync that pulls the teacher's lessons down.
        Navigator.pop(context);
        break;
      default:
        break;
    }
  }

  void _handleDoubleTap() {
    switch (_stage) {
      case _JoinStage.confirmName:
        _confirmName(correct: false);
        break;
      case _JoinStage.confirmCode:
        _confirmCode(correct: false);
        break;
      default:
        break;
    }
  }
}
