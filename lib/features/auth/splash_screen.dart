import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          context.go('/role');
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFEBF2FF),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The real AudioLearner mark. The source PNG is a full-bleed
              // navy square with sharp corners (correct for icon generation —
              // Android and iOS apply their own masks). Shown raw on this pale
              // background it would read as a hard rectangle, so round it here
              // to the same proportion a launcher uses (~22% of the side).
              //
              // `errorBuilder` keeps the app running if the asset is missing
              // (e.g. a fresh clone before the icon is added) rather than
              // throwing on the very first screen a student reaches.
              ClipRRect(
                borderRadius: BorderRadius.circular(36),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  width: 160,
                  height: 160,
                  // Decorative: the screen is announced by TTS, and a
                  // duplicate label here would make a screen reader say the
                  // app's name twice.
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) => const Icon(
                    Icons.headphones_rounded,
                    size: 80,
                    color: Color(0xFF032A5F),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'AudioLearner',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF032A5F),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'For visually impaired students in Uganda',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Color(0xFF4A5568),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
