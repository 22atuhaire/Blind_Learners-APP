import 'dart:async';

import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/stt_service.dart';
import 'package:audioapp/shared/services/tts_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Name-based student login. A pupil simply says their name - no PIN, no
/// passwords. A new name (after confirmation) creates a profile; a name close
/// to an existing one is fuzzy-matched and confirmed. Several pupils can share
/// one phone, each with their own progress. Big tappable name buttons are the
/// fallback when the microphone is unavailable.
const String kActiveStudentIdKey = 'active_student_id';

class StudentLoginScreen extends ConsumerStatefulWidget {
  const StudentLoginScreen({super.key});

  @override
  ConsumerState<StudentLoginScreen> createState() => _StudentLoginScreenState();
}

class _StudentLoginScreenState extends ConsumerState<StudentLoginScreen> {
  List<Student> _students = [];
  bool _loading = true;
  bool _addingNew = false;
  final TextEditingController _nameController = TextEditingController();
  int _session = 0;
  int _voiceAttempts = 0; // bound voice retries; then fall back to buttons

  // Captured while `ref` is valid — using `ref` in dispose() throws and can
  // tear the whole app down during a screen-lock/navigation teardown.
  late final SttService _stt;
  late final TtsService _tts;

  @override
  void initState() {
    super.initState();
    _stt = ref.read(sttServiceProvider);
    _tts = ref.read(ttsServiceProvider);
    _bootstrap();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _tts.stop();
    _stt.stopListening();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await ref.read(ttsInitProvider.future);
    final db = ref.read(appDatabaseProvider);
    final students = await db.studentDao.getAllStudents();
    final stt = ref.read(sttServiceProvider);
    final ready = await stt.initialize();
    if (!mounted) return;
    setState(() {
      _students = students;
      _loading = false;
    });

    if (!ready) {
      await ref.read(ttsServiceProvider).speak(
            'Voice is not available. Tap your name on the screen, '
            'or tap new student.',
          );
      return;
    }
    await _promptName();
  }

  // ── Voice flow ────────────────────────────────────────────────────────────

  Future<void> _promptName() async {
    if (!mounted) return;
    if (_voiceAttempts >= 6) {
      await ref.read(ttsServiceProvider).speak(
            'Tap your name on the screen, or tap new student.',
          );
      return;
    }
    _voiceAttempts++;
    final session = ++_session;
    final tts = ref.read(ttsServiceProvider);
    await ref.read(sttServiceProvider).stopListening();
    final prompt = _students.isEmpty
        ? 'Welcome. What is your name? Say it clearly after the beep.'
        : 'Say your name to continue.';
    _lastPromptNorm = _normEcho(prompt);
    await tts.speakAndWait(prompt);
    if (!mounted || session != _session) return;
    // Let the prompt's audio tail drain before opening the mic, so the
    // recognizer doesn't transcribe our own voice or miss the first word.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || session != _session) return;
    _listen(session, (words) => _handleHeardName(words));
  }

  // ── Echo stripping ──────────────────────────────────────────────────────
  // On some devices the TTS engine reports "complete" BEFORE the audio has
  // fully left the speaker, so the microphone opens early and captures the
  // tail of our own prompt followed by the student's words. The recognizer
  // merges them into one phrase: "say your name to continue Joseph". Field
  // test: the app then offered to create a student literally named that.
  // Fix: remember the prompt we just spoke and strip the longest leading run
  // of the heard phrase that is a contiguous part of it — what remains is
  // what the student actually said.
  String _lastPromptNorm = '';

  static String _normEcho(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _stripPromptEcho(String heard) {
    final words =
        _normEcho(heard).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty || _lastPromptNorm.isEmpty) return heard.trim();
    // Find the longest prefix of the heard words that appears verbatim
    // inside the prompt; everything after it is the student's own speech.
    var strippedFrom = 0;
    for (var end = words.length; end > 0; end--) {
      final prefix = words.sublist(0, end).join(' ');
      if (_lastPromptNorm.contains(prefix)) {
        strippedFrom = end;
        break;
      }
    }
    return words.sublist(strippedFrom).join(' ');
  }

  void _listen(int session, void Function(String) onResult,
      {Duration listenFor = const Duration(seconds: 12),
      Duration pauseFor = const Duration(seconds: 5)}) {
    final stt = ref.read(sttServiceProvider);
    var handled = false;
    var lastPartial = '';
    void deliver(String words) {
      // If everything heard was our own prompt echoing back, this yields an
      // empty string — each caller already treats that as "no answer"
      // (name flow re-prompts, confirm flow re-asks).
      onResult(_stripPromptEcho(words));
    }

    stt.startListening(
      listenFor: listenFor,
      pauseFor: pauseFor,
      // Many Android recognizers end a session WITHOUT a final result, sending
      // only partials. Keep the latest partial so we can still use it on done -
      // otherwise a clearly-spoken name is dropped and the prompt loops.
      onPartial: (words) {
        if (words.trim().isNotEmpty) lastPartial = words.trim();
      },
      onResult: (words) {
        if (handled || session != _session) return;
        handled = true;
        unawaited(stt.stopListening());
        deliver(words);
      },
      onDone: () {
        if (handled || session != _session) return;
        handled = true;
        if (lastPartial.isNotEmpty) {
          deliver(lastPartial); // use what we heard, even without a final result
        } else if (mounted && session == _session) {
          unawaited(_promptName()); // truly silent -> re-prompt (bounded)
        }
      },
    );
  }

  Future<void> _handleHeardName(String heard) async {
    // Natural speech lead-ins are not part of the name.
    var body = _normEcho(heard);
    for (final lead in ['my name is ', 'i am ', 'im ', 'call me ', 'name is ']) {
      if (body.startsWith(lead)) {
        body = body.substring(lead.length).trim();
        break;
      }
    }
    final cleaned = _titleCase(body);
    if (_normalize(cleaned).isEmpty) {
      await _promptName();
      return;
    }
    final (best, score) = _bestMatch(cleaned);
    if (best != null && score >= 0.92) {
      await _login(best); // near-exact: log straight in
      return;
    }
    if (best != null && score >= 0.6) {
      await _confirm(
        'Welcome back, ${best.name}?',
        onYes: () => _login(best),
        onNo: () => _promptName(),
      );
      return;
    }
    // NOTE: confirm prompts must never contain the words "yes" or "no" —
    // if the mic opens early, the echoed prompt would answer itself.
    await _confirm(
      'That name is new. Should I create a student called $cleaned?',
      onYes: () => _createAndLogin(cleaned),
      onNo: () => _promptName(),
    );
  }

  Future<void> _confirm(String prompt,
      {required Future<void> Function() onYes,
      required Future<void> Function() onNo}) async {
    if (!mounted) return;
    if (_voiceAttempts >= 8) {
      await ref.read(ttsServiceProvider).speak(
            'Tap your name on the screen, or tap new student.',
          );
      return;
    }
    _voiceAttempts++;
    final session = ++_session;
    await ref.read(sttServiceProvider).stopListening();
    _lastPromptNorm = _normEcho(prompt);
    await ref.read(ttsServiceProvider).speakAndWait(prompt);
    if (!mounted || session != _session) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || session != _session) return;
    _listen(session, (words) async {
      final yn = _parseYesNo(words);
      if (yn == true) {
        await onYes();
      } else if (yn == false) {
        await onNo();
      } else {
        await _confirm(prompt, onYes: onYes, onNo: onNo);
      }
    }, listenFor: const Duration(seconds: 8), pauseFor: const Duration(seconds: 4));
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _login(Student student) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kActiveStudentIdKey, student.id);
    if (!mounted) return;
    await ref.read(ttsServiceProvider).speakAndWait('Welcome, ${student.name}.');
    if (!mounted) return;
    context.go('/student/home');
  }

  Future<void> _createAndLogin(String name) async {
    final db = ref.read(appDatabaseProvider);
    final id = await db.studentDao.insertStudent(
      StudentsTableCompanion.insert(
        name: name,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final student = await db.studentDao.getStudentById(id);
    if (student == null || !mounted) return;
    await _login(student);
  }

  // ── Matching helpers ────────────────────────────────────────────────────────

  (Student?, double) _bestMatch(String heard) {
    Student? best;
    var bestScore = 0.0;
    for (final s in _students) {
      final score = _similarity(heard, s.name);
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    return (best, bestScore);
  }

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _titleCase(String s) => s
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  double _similarity(String a, String b) {
    a = _normalize(a);
    b = _normalize(b);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final dist = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    return 1 - dist / maxLen;
  }

  int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = cur[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        var best = del < ins ? del : ins;
        if (sub < best) best = sub;
        cur[j] = best;
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }

  bool? _parseYesNo(String w) {
    // Whole words only. Substring matching misread "I do not KNOw" as "no"
    // and any echoed prompt containing "yes" as an agreement — the app was
    // answering its own questions.
    final words = _normEcho(w).split(' ').toSet();
    const yes = {'yes', 'yeah', 'yep', 'correct', 'right', 'sure', 'ok', 'okay'};
    const no = {'no', 'nope', 'wrong', 'cancel'};
    final saidYes = words.intersection(yes).isNotEmpty;
    final saidNo = words.intersection(no).isNotEmpty;
    if (saidYes && !saidNo) return true;
    if (saidNo && !saidYes) return false;
    return null; // silence, both, or neither — ask again
  }

  // ── UI (fallback for when voice is unavailable, and for sighted helpers) ────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFEBF2FF),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              const Text(
                'Who is learning?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A56DB),
                ),
              ),
              const SizedBox(height: 16),
              if (_addingNew) ...[
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Student name',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submitTypedName(),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _submitTypedName,
                  child: const Text('Start learning'),
                ),
              ] else ...[
                Expanded(
                  child: ListView(
                    children: [
                      for (final s in _students)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Semantics(
                            button: true,
                            label: 'Continue as ${s.name}',
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.all(20),
                                textStyle: const TextStyle(fontSize: 22),
                              ),
                              onPressed: () => _login(s),
                              child: Text(s.name),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New student'),
                  onPressed: () => setState(() => _addingNew = true),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitTypedName() async {
    final name = _titleCase(_nameController.text);
    if (_normalize(name).isEmpty) return;
    final (best, score) = _bestMatch(name);
    if (best != null && score >= 0.92) {
      await _login(best);
    } else {
      await _createAndLogin(name);
    }
  }
}
