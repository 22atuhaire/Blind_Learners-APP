import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:audioapp/shared/services/backend_api_service.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Teacher Access — ONE account, identified by email + password.
//
// A teacher creates a single account (name, subject, email, password). That
// registers the cloud account + their class on the backend and writes an
// on-device cache row; signing in on any device restores everything. There is
// no separate device PIN and no separate "connect your class" step — the local
// database is simply a cache of the one cloud account. "Stay signed in" keeps
// them in until they sign out from the dashboard.
// ─────────────────────────────────────────────────────────────────────────────

/// Client-side password check mirroring the backend policy, so a teacher sees
/// the rule before a network round-trip: at least 6 characters with a letter
/// and a number (no special characters required).
String? validateTeacherPassword(String password) {
  if (password.length < 6) return 'Use a password of at least 6 characters.';
  if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
      !RegExp(r'\d').hasMatch(password)) {
    return 'Password must include at least one letter and one number.';
  }
  return null;
}

class TeacherPinScreen extends ConsumerStatefulWidget {
  const TeacherPinScreen({super.key});

  @override
  ConsumerState<TeacherPinScreen> createState() => _TeacherPinScreenState();
}

class _TeacherPinScreenState extends ConsumerState<TeacherPinScreen> {
  static const _baseUrl = kDefaultBackendBaseUrl;

  bool _loading = true; // checking for an existing signed-in session
  bool _signInMode = false; // false = create account, true = sign in
  bool _busy = false;
  String _error = '';

  final _nameController = TextEditingController();
  final _classController = TextEditingController();
  final _subjectController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _classController.dispose();
    _subjectController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// "Stay signed in": if a teacher signed in on this device before, go
  /// straight to the dashboard; otherwise show the form.
  Future<void> _restoreSession() async {
    final link = ref.read(backendLinkServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final id = await link.getSignedInTeacherId();
    if (id != null) {
      final teacher = await db.teacherDao.getTeacherById(id);
      if (teacher != null) {
        if (!mounted) return;
        ref.read(currentTeacherProvider.notifier).state = teacher;
        context.go('/teacher/dashboard');
        return;
      }
      await link.clearSignedInTeacher(); // stale id — forget it
    }
    if (mounted) setState(() => _loading = false);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _handleCreate() async {
    final name = _nameController.text.trim();
    final className = _classController.text.trim();
    final subject = _subjectController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (name.isEmpty) return _fail('Enter your full name.');
    if (className.isEmpty) return _fail('Enter your class name.');
    if (subject.isEmpty) return _fail('Enter the subject you teach.');
    if (!email.contains('@') || email.length < 5) {
      return _fail('Enter a valid email.');
    }
    final pwError = validateTeacherPassword(password);
    if (pwError != null) return _fail(pwError);

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final db = ref.read(appDatabaseProvider);
      final link = ref.read(backendLinkServiceProvider);
      final now = DateTime.now().millisecondsSinceEpoch;

      // On-device cache row (no PIN in the unified model).
      final teacherId = await db.teacherDao.insertTeacher(
        TeachersTableCompanion(
          name: Value(name),
          pinHash: const Value(''),
          subjectName: Value(subject),
          createdAt: Value(now),
        ),
      );
      await db.subjectDao.insertSubject(
        SubjectsTableCompanion(
          teacherId: Value(teacherId),
          name: Value(subject),
          createdAt: Value(now),
        ),
      );

      // Create the cloud account (class teacher) + class + sharable codes,
      // and the subject they teach inside that class.
      await link.linkTeacherAccount(
        localTeacherId: teacherId,
        baseUrl: _baseUrl,
        fullName: name,
        email: email,
        password: password,
        subjectName: subject,
        className: className,
      );
      await link.setSignedInTeacher(teacherId);

      final teacher = await db.teacherDao.getTeacherById(teacherId);
      if (!mounted) return;
      ref.read(currentTeacherProvider.notifier).state = teacher;
      ref.invalidate(teacherSubjectsProvider);
      if (teacher != null) await showTeacherLinkDialog(context, teacher);
      if (mounted) context.go('/teacher/dashboard');
    } on BackendApiException catch (e) {
      _fail('${e.message} If you already have an account, switch to Sign in.');
    } catch (_) {
      _fail('Could not reach the server. Check your connection and try again.');
    }
  }

  Future<void> _handleSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!email.contains('@') || email.length < 5) {
      return _fail('Enter your account email.');
    }
    if (password.isEmpty) return _fail('Enter your password.');

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final db = ref.read(appDatabaseProvider);
      final link = ref.read(backendLinkServiceProvider);
      final teacher = await link.loginAndRestoreTeacher(
        db: db,
        baseUrl: _baseUrl,
        email: email,
        password: password,
      );
      await link.setSignedInTeacher(teacher.id);
      if (!mounted) return;
      ref.read(currentTeacherProvider.notifier).state = teacher;
      ref.invalidate(teacherSubjectsProvider);
      context.go('/teacher/dashboard');
    } on BackendApiException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Could not reach the server. Check your connection and try again.');
    }
  }

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
      appBar: AppBar(
        title: const Text('Teacher Access'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: _signInMode ? _buildSignIn() : _buildCreate(),
      ),
    );
  }

  Widget _buildCreate() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.person_add_rounded,
            size: 56, color: Color(0xFF1A56DB)),
        const SizedBox(height: 12),
        const Text(
          'Create your account',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A56DB)),
        ),
        const SizedBox(height: 6),
        const Text(
          'Your email and password are your account — they back up your notes '
          'and let students join your class.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        _field(_nameController, 'Your full name', Icons.person_outline),
        const SizedBox(height: 14),
        _field(_classController, 'Class name (e.g. Primary 5)',
            Icons.groups_outlined),
        const SizedBox(height: 14),
        _field(_subjectController, 'Subject you teach (e.g. Biology)',
            Icons.book_outlined),
        const SizedBox(height: 14),
        _field(_emailController, 'Email', Icons.email_outlined,
            keyboard: TextInputType.emailAddress),
        const SizedBox(height: 14),
        _field(_passwordController, 'Password', Icons.lock_outline,
            obscure: true,
            helper: 'At least 6 characters, with a letter and a number.'),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_error,
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
        ],
        const SizedBox(height: 24),
        _primaryButton('Create account', _handleCreate),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _signInMode = true;
                    _error = '';
                  }),
          child: const Text('Already have an account? Sign in'),
        ),
      ],
    );
  }

  Widget _buildSignIn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.login_rounded, size: 56, color: Color(0xFF1A56DB)),
        const SizedBox(height: 12),
        const Text(
          'Sign in',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A56DB)),
        ),
        const SizedBox(height: 6),
        const Text(
          'Sign in with your email and password. Your notes are restored to '
          'this device.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        _field(_emailController, 'Email', Icons.email_outlined,
            keyboard: TextInputType.emailAddress),
        const SizedBox(height: 14),
        _field(_passwordController, 'Password', Icons.lock_outline,
            obscure: true),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_error,
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
        ],
        const SizedBox(height: 24),
        _primaryButton('Sign in', _handleSignIn),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _signInMode = false;
                    _error = '';
                  }),
          child: const Text('New here? Create an account'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool obscure = false,
    TextInputType? keyboard,
    String? helper,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      textCapitalization:
          (keyboard == TextInputType.emailAddress || obscure)
              ? TextCapitalization.none
              : TextCapitalization.words,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _primaryButton(String label, Future<void> Function() onPressed) {
    return SizedBox(
      height: 54,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A56DB),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: _busy ? null : () => onPressed(),
        child: _busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2))
            : Text(label,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Class code dialog — shows the codes a teacher shares so students (and other
// teachers) can join their class. Opened right after sign-up and from the
// dashboard. Account creation now happens on the main screen, so this no
// longer asks for any credentials.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showTeacherLinkDialog(BuildContext context, Teacher teacher) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ClassCodeDialog(teacher: teacher),
  );
}

class _ClassCodeDialog extends ConsumerStatefulWidget {
  final Teacher teacher;
  const _ClassCodeDialog({required this.teacher});

  @override
  ConsumerState<_ClassCodeDialog> createState() => _ClassCodeDialogState();
}

class _ClassCodeDialogState extends ConsumerState<_ClassCodeDialog> {
  bool _loading = true;
  String? _teacherCode;
  String? _studentCode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info =
        await ref.read(backendLinkServiceProvider).getTeacherLink(widget.teacher.id);
    if (!mounted) return;
    setState(() {
      _teacherCode = info?.teacherCode;
      _studentCode = info?.studentCode;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasCodes = _studentCode != null || _teacherCode != null;
    return AlertDialog(
      title: const Text('Your class codes'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasCodes) ...[
                    const Text('Share these so others can join your class.',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 14),
                    if (_studentCode != null)
                      _codeTile('Student code', _studentCode!,
                          'Give this to your students.'),
                    if (_studentCode != null && _teacherCode != null)
                      const SizedBox(height: 10),
                    if (_teacherCode != null)
                      _codeTile('Teacher code', _teacherCode!,
                          'For another teacher joining your class.'),
                  ] else
                    const Text(
                      'Your class codes aren\'t saved on this device. Open the '
                      'device where you created the class to view them.',
                      style: TextStyle(fontSize: 13),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _codeTile(String label, String code, String hint) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A56DB).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(code,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF123B7A),
                  letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Text(hint,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
