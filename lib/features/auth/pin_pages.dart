import 'package:flutter/material.dart';
import '../../shared/services/pin_auth_service.dart';
import '../../shared/services/speech_pin_service.dart';

class PinEnrollPage extends StatefulWidget {
  const PinEnrollPage({super.key});

  @override
  State<PinEnrollPage> createState() => _PinEnrollPageState();
}

class _PinEnrollPageState extends State<PinEnrollPage> {
  final _speech = SpeechPinService();
  final _auth = PinAuthService();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _speech.init();
  }

  Future<void> _enroll() async {
    if (_busy) return;
    setState(() => _busy = true);

    await _speech.speak('Create a four digit PIN. I will ask for each digit.');
    final first = await _collectFourDigits();
    if (first == null) {
      await _speech
          .speak('I could not capture your PIN. Enrollment cancelled.');
      setState(() => _busy = false);
      return;
    }

    await _speech.speak('Please repeat the full four digit PIN now.');
    final second = await _collectFourDigits();
    if (second == null) {
      await _speech.speak(
          'I could not capture your repeated PIN. Enrollment cancelled.');
      setState(() => _busy = false);
      return;
    }

    if (first != second) {
      await _speech.speak('The two PINs did not match. Enrollment failed.');
      setState(() => _busy = false);
      return;
    }

    await _auth.savePin(first);
    await _speech.speak('Account created successfully.');
    setState(() => _busy = false);
  }

  Future<String?> _collectFourDigits() async {
    final digits = <String>[];
    for (var i = 1; i <= 4; i++) {
      await _speech.speak('Digit $i. Say the digit now.');
      final d = await _speech.listenOnceForDigit();
      if (d == null) return null;
      await _speech.speak('You said $d');
      digits.add(d);
    }
    return digits.join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll PIN')),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ElevatedButton(
            onPressed: _busy ? null : _enroll,
            child: Text(_busy ? 'Working…' : 'Create PIN (speak)'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () async {
              await _auth.clearPin();
              await _speech.speak('Stored PIN cleared.');
            },
            child: const Text('Clear stored PIN'),
          ),
        ]),
      ),
    );
  }
}

class PinLoginPage extends StatefulWidget {
  const PinLoginPage({super.key});

  @override
  State<PinLoginPage> createState() => _PinLoginPageState();
}

class _PinLoginPageState extends State<PinLoginPage> {
  final _speech = SpeechPinService();
  final _auth = PinAuthService();
  bool _busy = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _speech.init();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() => _busy = true);

    await _speech.speak('Please say your four digit PIN now.');
    final entered = await _collectFourDigits();
    if (entered == null) {
      await _speech.speak('I could not capture your PIN.');
      setState(() => _busy = false);
      return;
    }

    final ok = await _auth.verifyPin(entered);
    if (ok) {
      await _speech.speak('PIN accepted. Opening learning page.');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LearningPage()));
    } else {
      _attempts++;
      await _speech.speak('Incorrect PIN.');
      if (_attempts >= 3) {
        await _speech.speak('Too many failed attempts. Try again later.');
      }
    }

    setState(() => _busy = false);
  }

  Future<String?> _collectFourDigits() async {
    final digits = <String>[];
    for (var i = 1; i <= 4; i++) {
      await _speech.speak('Digit $i. Say the digit now.');
      final d = await _speech.listenOnceForDigit();
      if (d == null) return null;
      await _speech.speak('You said $d');
      digits.add(d);
    }
    return digits.join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PIN Login')),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ElevatedButton(
              onPressed: _busy ? null : _login,
              child: Text(_busy ? 'Working…' : 'Login (speak)')),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () async {
              final has = await _auth.hasPin();
              await _speech
                  .speak(has ? 'An account is present.' : 'No account found.');
            },
            child: const Text('Check account'),
          ),
        ]),
      ),
    );
  }
}

class LearningPage extends StatelessWidget {
  const LearningPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Learning')),
      body: const Center(child: Text('Welcome to the learning page')),
    );
  }
}
