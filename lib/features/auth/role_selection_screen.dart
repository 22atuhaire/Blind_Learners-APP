import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  final FlutterTts _tts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _initTts();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _speak(
          'Welcome to the Audio Learning Platform. '
          'Are you a student or a teacher?',
        );
      }
    });
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.headphones_rounded,
                size: 80,
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
              const SizedBox(height: 12),
              const Text(
                'Interactive audio learning for\nvisually impaired students in Uganda',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Color(0xFF4A5568),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 64),
              Semantics(
                label: 'I am a Student. Tap to continue as a student.',
                button: true,
                child: SizedBox(
                  height: 80,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A56DB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 2,
                    ),
                    icon: const Icon(Icons.school_rounded, size: 28),
                    label: const Text(
                      'I am a Student',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () {
                      _speak('Student selected. Please enter your PIN.');
                      context.go('/student/pin');
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Semantics(
                label: 'I am a Teacher. Tap to continue as a teacher.',
                button: true,
                child: SizedBox(
                  height: 80,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1A56DB),
                      side: const BorderSide(
                        color: Color(0xFF1A56DB),
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(Icons.person_rounded, size: 28),
                    label: const Text(
                      'I am a Teacher',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () {
                      _speak('Teacher selected. Please enter your PIN.');
                      context.go('/teacher/pin');
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
