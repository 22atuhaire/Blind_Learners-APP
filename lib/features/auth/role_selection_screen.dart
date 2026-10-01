import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audioapp/features/student/student_login_screen.dart'
    show kActiveStudentIdKey;
import 'package:audioapp/shared/services/accessibility_service.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/stt_service.dart';
import 'package:audioapp/shared/services/tts_service.dart';

class RoleSelectionScreen extends ConsumerStatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  ConsumerState<RoleSelectionScreen> createState() =>
      _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends ConsumerState<RoleSelectionScreen> {
  bool _navigated = false;

  // Captured while `ref` is valid (initState). Using `ref` inside dispose()
  // throws "Cannot use ref after the widget was disposed" and, during a
  // teardown triggered by the screen locking or fast navigation, corrupts
  // the widget-tree finalization badly enough to restart the whole app.
  late final SttService _stt;
  late final TtsService _tts;

  @override
  void initState() {
    super.initState();
    _stt = ref.read(sttServiceProvider);
    _tts = ref.read(ttsServiceProvider);
    // Wake the free-tier backend now, in the background — by the time a
    // student reaches "join class" or lesson sync, the 30-60 second cold
    // start has already happened invisibly instead of in their face.
    unawaited(ref.read(backendApiServiceProvider).warmUp());
    Future<void>(() async {
      await ref.read(ttsInitProvider.future);
      if (!mounted) return;

      // Resume straight into learning for a student who has used this phone
      // before. Without this, every launch asks "student or teacher?" and
      // then "say your name" again — a toll a sighted user never pays,
      // charged to the student least able to pay it. It is also what makes
      // "Hey Google, open AudioLearner" genuinely useful: the student lands
      // in their lessons, speaking, instead of on a menu.
      if (await _resumeReturningStudent()) return;

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      const welcome =
          'Welcome to AudioLearner. Say student to continue as a student, '
          'or say teacher to continue as a teacher. You can also tap the '
          'bottom of the screen for student, or the teacher button at the '
          'top right.';
      // Let TalkBack speak this if it is running, rather than talking over it.
      if (AccessibilityMode.isScreenReaderActive) {
        AccessibilityMode.announce(welcome);
        return;
      }
      await ref.read(ttsServiceProvider).speakAndWait(welcome);
      if (mounted) unawaited(_listenForRole());
    });
  }

  /// Sends a previously signed-in student straight to the learning hub.
  ///
  /// Returns true when it navigated, so the caller skips the role prompt.
  /// Any failure falls through to the normal flow — a student who cannot be
  /// resumed must still be able to choose a role.
  Future<bool> _resumeReturningStudent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final studentId = prefs.getInt(kActiveStudentIdKey);
      if (studentId == null || !mounted) return false;

      // Confirm the row still exists — app data may have been cleared, and
      // resuming into a hub with no student would strand them silently.
      final student =
          await ref.read(appDatabaseProvider).studentDao.getStudentById(studentId);
      if (student == null || !mounted) return false;

      _navigated = true;
      final greeting = 'Welcome back, ${student.name}. Opening your lessons.';
      if (AccessibilityMode.isScreenReaderActive) {
        AccessibilityMode.announce(greeting);
      } else {
        unawaited(ref.read(ttsServiceProvider).speak(greeting));
      }
      if (!mounted) return false;
      context.go('/student/home');
      return true;
    } catch (_) {
      return false; // never block the normal path
    }
  }

  Future<void> _speak(String text) async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(text);
  }

  /// Voice-first role pick: listens for "student" or "teacher" and navigates
  /// accordingly. Re-listens on silence/unclear speech. The tap zones below
  /// remain fully functional as a fallback.
  Future<void> _listenForRole() async {
    if (!mounted || _navigated) return;

    final stt = ref.read(sttServiceProvider);
    final ready = await stt.initialize();
    if (!ready || !mounted || _navigated) return;

    var handled = false;
    void match(String words) {
      if (handled || _navigated) return;
      final command = words.toLowerCase();
      if (command.contains('student') || command.contains('learner')) {
        handled = true;
        _navigated = true;
        unawaited(stt.stopListening());
        _speak('Student selected. Opening the learner screen.');
        context.go('/student/pin');
      } else if (command.contains('teacher')) {
        handled = true;
        _navigated = true;
        unawaited(stt.stopListening());
        _speak('Teacher selected. Opening teacher sign in.');
        context.push('/teacher/pin');
      }
    }

    stt.startListening(
      // Single-keyword pick: matching on partials keeps the response instant,
      // while the final result acts as a safety net for slower recognisers.
      onPartial: match,
      onResult: match,
      onDone: () {
        if (handled || _navigated || !mounted) return;
        handled = true;
        unawaited(_listenForRole());
      },
    );
  }

  @override
  void dispose() {
    _stt.stopListening();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          context.go('/');
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFEBF2FF),
        body: Stack(
          children: [
            // ── Main content area with welcome message ───────────────────
            const SafeArea(
              child: SizedBox.expand(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.headphones_rounded,
                        size: 72,
                        color: Color(0xFF1A56DB),
                      ),
                      SizedBox(height: 24),
                      Text(
                        'Audio Learning\nPlatform',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A56DB),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Top-right Teacher Button ──────────────────────────────────
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: Semantics(
                  label: 'Teacher mode. Tap to continue as a teacher.',
                  button: true,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1A56DB),
                      side: const BorderSide(
                        color: Color(0xFF1A56DB),
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.person_rounded, size: 20),
                    label: const Text(
                      'Teacher',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () {
                      // Stop the background voice-command loop — otherwise it
                      // keeps restarting every few seconds on the screen
                      // underneath, each restart triggering the speech
                      // recognizer's start/stop chime and a platform-channel
                      // hiccup that freezes typing on the next screen.
                      _navigated = true;
                      unawaited(ref.read(sttServiceProvider).stopListening());
                      context.push('/teacher/pin');
                    },
                  ),
                ),
              ),
            ),

            // ── Clickable bottom zone for students ─────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 200,
              child: GestureDetector(
                onTap: () {
                  _navigated = true;
                  unawaited(ref.read(sttServiceProvider).stopListening());
                  _speak('Student selected. Opening the learner screen.');
                  context.go('/student/pin');
                },
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF1A56DB).withValues(alpha: 0.1),
                        const Color(0xFF1A56DB).withValues(alpha: 0.25),
                      ],
                    ),
                    border: const Border(
                      top: BorderSide(
                        color: Color(0xFF1A56DB),
                        width: 3,
                      ),
                    ),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.school_rounded,
                          size: 40,
                          color: Color(0xFF1A56DB),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Tap to Enter as Student',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A56DB),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
