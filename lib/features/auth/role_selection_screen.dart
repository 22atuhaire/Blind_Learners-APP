import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audioapp/shared/services/providers.dart';

class RoleSelectionScreen extends ConsumerStatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  ConsumerState<RoleSelectionScreen> createState() =>
      _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends ConsumerState<RoleSelectionScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>(() async {
      await ref.read(ttsInitProvider.future);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        _speak(
          'Welcome to audio learning platform, if you are a student click in the bottom zone',
        );
      }
    });
  }

  Future<void> _speak(String text) async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(text);
  }

  @override
  void dispose() {
    ref.read(ttsServiceProvider).stop();
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
            SafeArea(
              child: SizedBox.expand(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.headphones_rounded,
                        size: 72,
                        color: Color(0xFF1A56DB),
                      ),
                      const SizedBox(height: 24),
                      const Text(
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
                  _speak('Student selected. Opening the learner screen.');
                  context.go('/student/home');
                },
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF1A56DB).withOpacity(0.1),
                        const Color(0xFF1A56DB).withOpacity(0.25),
                      ],
                    ),
                    border: const Border(
                      top: BorderSide(
                        color: Color(0xFF1A56DB),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.school_rounded,
                          size: 40,
                          color: Color(0xFF1A56DB),
                        ),
                        const SizedBox(height: 12),
                        const Text(
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
