import 'dart:async';

import 'package:audioapp/shared/services/pin_auth_service.dart';
import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class StudentPinScreen extends ConsumerStatefulWidget {
  const StudentPinScreen({super.key});

  @override
  ConsumerState<StudentPinScreen> createState() => _StudentPinScreenState();
}

class _StudentPinScreenState extends ConsumerState<StudentPinScreen>
    with SingleTickerProviderStateMixin {
  Student? _student;
  bool _legacyPinMode = false;
  bool _listening = false;
  bool _processingSpeech = false;
  bool _setupMode = false;
  int _sessionToken = 0;

  final List<String> _digits = [];
  final List<String> _confirmationDigits = [];
  final PinAuthService _legacyPinAuth = PinAuthService();

  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    ref.read(ttsServiceProvider).stop();
    ref.read(sttServiceProvider).stopListening();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await ref.read(ttsInitProvider.future);

    final db = ref.read(appDatabaseProvider);
    var student = await db.studentDao.getStudent();
    var legacyPinMode = false;

    if (student == null) {
      final hasLegacyPin = await _legacyPinAuth.hasPin();
      if (hasLegacyPin) {
        legacyPinMode = true;
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        final studentId = await db.studentDao.insertStudent(
          StudentsTableCompanion.insert(
            name: 'Student',
            createdAt: now,
          ),
        );
        student = await db.studentDao.getStudentById(studentId);
      }
    }

    if (!mounted) return;

    setState(() {
      _student = student;
      _legacyPinMode = legacyPinMode;
      _setupMode = !legacyPinMode &&
          student != null &&
          (!student.pinCreated ||
              student.pinHash == null ||
              student.pinHash!.isEmpty);
    });

    final tts = ref.read(ttsServiceProvider);
    final stt = ref.read(sttServiceProvider);

    final voiceReady = await stt.initialize();
    if (!mounted) return;

    if (!voiceReady) {
      await tts.speak(
        'Voice recognition is unavailable. Give the phone to your teacher.',
      );
      return;
    }

    if (student == null && !legacyPinMode) {
      await tts.speak('Give the phone to your teacher.');
      return;
    }

    if (_setupMode) {
      await _beginPinSetup();
    } else {
      await _beginLogin();
    }
  }

  Future<void> _beginLogin() async {
    final student = _student;
    if (!mounted) return;

    if (!_legacyPinMode && student == null) {
      return;
    }

    _sessionToken += 1;
    setState(() {
      _digits.clear();
      _confirmationDigits.clear();
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait(
      'Welcome back ${student?.name ?? 'student'}. Say your four-digit PIN, one digit at a time.',
    );

    if (!mounted) return;
    await _captureDigits(
      prompt: 'Say the first digit.',
      nextPrompt: 'Say the next digit.',
      buffer: _digits,
      onComplete: _verifyLoginPin,
    );
  }

  Future<void> _beginPinSetup() async {
    final student = _student;
    if (!mounted || student == null) return;

    _sessionToken += 1;
    setState(() {
      _digits.clear();
      _confirmationDigits.clear();
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait(
      'Create your account, ${student.name}. Say the PIN you would like, one digit at a time.',
    );

    if (!mounted) return;
    await _captureDigits(
      prompt: 'Say the first digit.',
      nextPrompt: 'Say the next digit.',
      buffer: _digits,
      onComplete: _handleFirstSetupEntry,
    );
  }

  Future<void> _handleFirstSetupEntry(List<String> digits) async {
    if (!mounted) return;

    setState(() {
      _confirmationDigits
        ..clear()
        ..addAll(digits);
      _digits.clear();
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait(
      'You said ${_spokenDigits(digits)}. Repeat the same PIN to confirm.',
    );

    if (!mounted) return;
    await _captureDigits(
      prompt: 'Repeat the first digit.',
      nextPrompt: 'Say the next digit.',
      buffer: _digits,
      onComplete: _handleConfirmationEntry,
    );
  }

  Future<void> _handleConfirmationEntry(List<String> digits) async {
    final student = _student;
    if (!mounted || student == null) return;

    final original = _confirmationDigits.join();
    final repeated = digits.join();

    if (original != repeated) {
      setState(() {
        _digits.clear();
        _confirmationDigits.clear();
      });

      final tts = ref.read(ttsServiceProvider);
      await tts.speakAndWait('The PINs do not match. Let us try again.');
      if (!mounted) return;
      await _beginPinSetup();
      return;
    }

    final pinService = ref.read(pinServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final hash = pinService.hashPin(repeated);

    await db.studentDao.updateStudentPinHash(student.id, hash);
    await db.studentDao.markPinAsCreated(student.id);

    if (!mounted) return;

    setState(() {
      _digits.clear();
      _confirmationDigits.clear();
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait('Your account is ready. You are logged in.');
    if (!mounted) return;
    context.go('/student/home');
  }

  Future<void> _verifyLoginPin(List<String> digits) async {
    final student = _student;
    if (!mounted) return;

    final enteredPin = digits.join();

    if (_legacyPinMode) {
      final isValid = await _legacyPinAuth.verifyPin(enteredPin);
      if (isValid) {
        setState(() {
          _digits.clear();
        });

        final tts = ref.read(ttsServiceProvider);
        await tts.speakAndWait('You are logged in.');
        if (!mounted) return;
        context.go('/student/home');
        return;
      }

      setState(() {
        _digits.clear();
        _confirmationDigits.clear();
      });

      final tts = ref.read(ttsServiceProvider);
      await tts.speakAndWait('Incorrect. Try again.');
      if (!mounted) return;
      await _beginLogin();
      return;
    }

    if (student == null) return;

    final storedHash = student.pinHash;
    if (storedHash == null || storedHash.isEmpty) {
      final tts = ref.read(ttsServiceProvider);
      await tts.speak('Give the phone to your teacher.');
      return;
    }

    final pinService = ref.read(pinServiceProvider);

    if (pinService.verifyPin(enteredPin, storedHash)) {
      setState(() {
        _digits.clear();
      });

      final tts = ref.read(ttsServiceProvider);
      await tts.speakAndWait('You are logged in.');
      if (!mounted) return;
      context.go('/student/home');
      return;
    }

    setState(() {
      _digits.clear();
      _confirmationDigits.clear();
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait('Incorrect. Try again.');
    if (!mounted) return;
    await _beginLogin();
  }

  Future<void> _captureDigits({
    required String prompt,
    required String nextPrompt,
    required List<String> buffer,
    required Future<void> Function(List<String> digits) onComplete,
  }) async {
    if (!mounted) return;

    final session = ++_sessionToken;
    final tts = ref.read(ttsServiceProvider);
    final stt = ref.read(sttServiceProvider);

    _setListening(true);
    _processingSpeech = false;

    final currentPrompt = buffer.isEmpty ? prompt : nextPrompt;
    await tts.speakAndWait(currentPrompt);

    if (!mounted || session != _sessionToken) return;

    stt.startListening(
      onResult: (words) {
        if (_processingSpeech || session != _sessionToken) return;
        final digit = _parseDigit(words);
        if (digit == null) return;
        _processingSpeech = true;
        unawaited(
          _handleRecognizedDigit(
            digit: digit,
            buffer: buffer,
            prompt: prompt,
            nextPrompt: nextPrompt,
            onComplete: onComplete,
            session: session,
          ),
        );
      },
      onDone: () {
        if (_processingSpeech || session != _sessionToken) return;
        _processingSpeech = true;
        unawaited(
          _handleUnclearSpeech(
            buffer: buffer,
            prompt: prompt,
            nextPrompt: nextPrompt,
            onComplete: onComplete,
            session: session,
          ),
        );
      },
    );
  }

  Future<void> _handleRecognizedDigit({
    required int digit,
    required List<String> buffer,
    required String prompt,
    required String nextPrompt,
    required Future<void> Function(List<String> digits) onComplete,
    required int session,
  }) async {
    final stt = ref.read(sttServiceProvider);
    await stt.stopListening();

    if (!mounted || session != _sessionToken) return;

    _setListening(false);
    setState(() {
      buffer.add('$digit');
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.speakAndWait(_digitToWord(digit));

    if (!mounted || session != _sessionToken) return;

    if (buffer.length >= 4) {
      await onComplete(List<String>.from(buffer));
      return;
    }

    await _captureDigits(
      prompt: prompt,
      nextPrompt: nextPrompt,
      buffer: buffer,
      onComplete: onComplete,
    );
  }

  Future<void> _handleUnclearSpeech({
    required List<String> buffer,
    required String prompt,
    required String nextPrompt,
    required Future<void> Function(List<String> digits) onComplete,
    required int session,
  }) async {
    final stt = ref.read(sttServiceProvider);
    await stt.stopListening();

    if (!mounted || session != _sessionToken) return;

    _setListening(false);

    final tts = ref.read(ttsServiceProvider);
    final repeatPrompt = buffer.isEmpty ? prompt : nextPrompt;
    await tts.speakAndWait('I did not hear that. $repeatPrompt');

    if (!mounted || session != _sessionToken) return;

    await _captureDigits(
      prompt: prompt,
      nextPrompt: nextPrompt,
      buffer: buffer,
      onComplete: onComplete,
    );
  }

  void _setListening(bool value) {
    if (_listening == value) return;
    setState(() {
      _listening = value;
    });

    if (value) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  int? _parseDigit(String words) {
    final tokens = words
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();

    for (final token in tokens) {
      final digit = _digitFromToken(token);
      if (digit != null) return digit;
    }

    return null;
  }

  int? _digitFromToken(String token) {
    final numeric = int.tryParse(token);
    if (numeric != null && numeric >= 0 && numeric <= 9) {
      return numeric;
    }

    switch (token) {
      case 'zero':
      case 'oh':
      case 'o':
        return 0;
      case 'one':
      case 'won':
        return 1;
      case 'two':
      case 'too':
      case 'to':
        return 2;
      case 'three':
        return 3;
      case 'four':
      case 'for':
        return 4;
      case 'five':
        return 5;
      case 'six':
        return 6;
      case 'seven':
        return 7;
      case 'eight':
      case 'ate':
        return 8;
      case 'nine':
        return 9;
    }

    return null;
  }

  String _spokenDigits(List<String> digits) {
    return digits
        .map((digit) => _digitToWord(int.tryParse(digit) ?? -1))
        .join(' ');
  }

  String _digitToWord(int digit) {
    switch (digit) {
      case 0:
        return 'zero';
      case 1:
        return 'one';
      case 2:
        return 'two';
      case 3:
        return 'three';
      case 4:
        return 'four';
      case 5:
        return 'five';
      case 6:
        return 'six';
      case 7:
        return 'seven';
      case 8:
        return 'eight';
      case 9:
        return 'nine';
      default:
        return '$digit';
    }
  }

  @override
  Widget build(BuildContext context) {
    final studentName = _student?.name ?? 'Student';
    final filledDots = _digits.length;

    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                studentName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A56DB),
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  final filled = index < filledDots;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 7),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          filled ? const Color(0xFF1A56DB) : Colors.transparent,
                      border: Border.all(
                        color: const Color(0xFF1A56DB),
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final pulse = _listening
                      ? 1.0 + (_pulseController.value * 0.08)
                      : 1.0;
                  final glow = _listening
                      ? 0.45 + (_pulseController.value * 0.35)
                      : 0.25;

                  return Transform.scale(
                    scale: pulse,
                    child: Icon(
                      Icons.mic_rounded,
                      size: 74,
                      color: Color.fromRGBO(26, 86, 219, glow),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
