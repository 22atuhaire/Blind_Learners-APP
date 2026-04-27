import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';
// PinService is accessed through pinServiceProvider; no direct import needed.

// ─────────────────────────────────────────────────────────────────────────────
// Teacher PIN Screen
// ─────────────────────────────────────────────────────────────────────────────

class TeacherPinScreen extends ConsumerStatefulWidget {
  const TeacherPinScreen({super.key});

  @override
  ConsumerState<TeacherPinScreen> createState() => _TeacherPinScreenState();
}

class _TeacherPinScreenState extends ConsumerState<TeacherPinScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  List<Teacher> _teachers = [];
  bool _loading = true;
  bool _createMode = false;
  Teacher? _selectedTeacher;
  String _loginPin = '';
  String _loginError = '';

  // Create form
  final _nameController = TextEditingController();
  final _subjectController = TextEditingController();
  String _createPin = '';
  String _confirmPin = '';
  String _createError = '';
  bool _saving = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadTeachers();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  Future<void> _loadTeachers() async {
    final db = ref.read(appDatabaseProvider);
    final teachers = await db.teacherDao.getAllTeachers();
    setState(() {
      _teachers = teachers;
      _loading = false;
      _createMode = teachers.isEmpty;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      appBar: AppBar(
        title: const Text('Teacher Access'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: !(_createMode && _teachers.isEmpty),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _createMode
              ? _buildCreateForm()
              : _buildLoginList(),
    );
  }

  // ── Create Form ────────────────────────────────────────────────────────────

  Widget _buildCreateForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.person_add_rounded,
            size: 64,
            color: Color(0xFF1A56DB),
          ),
          const SizedBox(height: 16),
          const Text(
            'Set Up Teacher Profile',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A56DB),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Create your profile to upload lessons',
            style: TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Name field
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Your full name',
              prefixIcon: const Icon(Icons.person_outline),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),

          // Subject field
          TextField(
            controller: _subjectController,
            decoration: InputDecoration(
              labelText: 'Subject (e.g. Biology)',
              prefixIcon: const Icon(Icons.book_outlined),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 24),

          // Create PIN
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Create your 4-digit PIN',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _PinInputRow(
            onChanged: (pin) => setState(() => _createPin = pin),
          ),
          const SizedBox(height: 20),

          // Confirm PIN
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Confirm PIN',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _PinInputRow(
            onChanged: (pin) => setState(() => _confirmPin = pin),
          ),
          const SizedBox(height: 8),

          // Error text
          if (_createError.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _createError,
                style: const TextStyle(
                  color: Color(0xFFDC2626),
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 24),

          // Create button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A56DB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: _saving ? null : _handleCreate,
              child: _saving
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      'Create Profile',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),

          // Back to login (only if teachers already exist)
          if (_teachers.isNotEmpty) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _createMode = false;
                  _createError = '';
                });
              },
              child: const Text('Back to login'),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _handleCreate() async {
    final name = _nameController.text.trim();
    final subject = _subjectController.text.trim();

    if (name.isEmpty) {
      setState(() => _createError = 'Please enter your name.');
      return;
    }
    if (subject.isEmpty) {
      setState(() => _createError = 'Please enter a subject name.');
      return;
    }

    final pinService = ref.read(pinServiceProvider);

    if (!pinService.isValidPin(_createPin)) {
      setState(() => _createError = 'PIN must be exactly 4 digits.');
      return;
    }
    if (_createPin != _confirmPin) {
      setState(() => _createError = 'PINs do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _createError = '';
    });

    try {
      final db = ref.read(appDatabaseProvider);
      final hash = pinService.hashPin(_createPin);

      final teacherId = await db.teacherDao.insertTeacher(
        TeachersTableCompanion(
          name: Value(name),
          pinHash: Value(hash),
          subjectName: Value(subject),
          createdAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

      await db.subjectDao.insertSubject(
        SubjectsTableCompanion(
          teacherId: Value(teacherId),
          name: Value(subject),
          createdAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

      final teacher = await db.teacherDao.getTeacherById(teacherId);
      ref.read(currentTeacherProvider.notifier).state = teacher;

      if (mounted) context.go('/teacher/dashboard');
    } catch (e) {
      setState(() {
        _saving = false;
        _createError = 'Error creating profile. Please try again.';
      });
    }
  }

  // ── Login List ─────────────────────────────────────────────────────────────

  Widget _buildLoginList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header banner
        Container(
          color: const Color(0xFF1A56DB),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select Your Profile',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap your name to log in',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),

        // Teacher list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _teachers.length,
            itemBuilder: (context, index) {
              final teacher = _teachers[index];
              return Card(
                elevation: 2,
                margin: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF1A56DB),
                    child: Text(
                      teacher.name[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    teacher.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(teacher.subjectName),
                  trailing: const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    setState(() {
                      _selectedTeacher = teacher;
                      _loginPin = '';
                      _loginError = '';
                    });
                    _showLoginBottomSheet(teacher);
                  },
                ),
              );
            },
          ),
        ),

        // Add new teacher button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: TextButton.icon(
            onPressed: () => setState(() => _createMode = true),
            icon: const Icon(Icons.add),
            label: const Text('Add New Teacher'),
          ),
        ),
      ],
    );
  }

  // ── Login Bottom Sheet ─────────────────────────────────────────────────────

  void _showLoginBottomSheet(Teacher teacher) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        // Seed from parent state so a re-opened sheet starts clean, and the
        // parent fields (_loginPin, _loginError) are meaningfully read.
        String localPin = _loginPin;
        String localError = _loginError;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              // Push the sheet above the keyboard
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          teacher.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const Text(
                      'Enter your 4-digit PIN',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 16),

                    // PIN input — keyed so it resets when teacher changes
                    _PinInputRow(
                      key: ValueKey(teacher.id),
                      onChanged: (pin) {
                        localPin = pin;
                        // Clear error as user types
                        if (localError.isNotEmpty) {
                          setModalState(() => localError = '');
                        }
                      },
                    ),
                    const SizedBox(height: 8),

                    // Inline error text
                    if (localError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          localError,
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),

                    // Login button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A56DB),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () => _handleLogin(
                          loginPin: localPin,
                          sheetContext: ctx,
                          setError: (err) =>
                              setModalState(() => localError = err),
                        ),
                        child: const Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Verifies the entered PIN against the stored hash.
  ///
  /// Reads [_selectedTeacher] from parent state (set in the card's onTap
  /// before the sheet opens). On success navigates to the dashboard; on
  /// failure calls [setError] so the bottom sheet updates inline without
  /// requiring the parent to rebuild.
  Future<void> _handleLogin({
    required String loginPin,
    required BuildContext sheetContext,
    required void Function(String) setError,
  }) async {
    // _selectedTeacher is the source of truth — read it here.
    final teacher = _selectedTeacher;
    if (teacher == null) return;

    // Keep parent tracking fields in sync.
    setState(() {
      _loginPin = loginPin;
      _loginError = '';
    });

    final pinService = ref.read(pinServiceProvider);

    if (pinService.verifyPin(loginPin, teacher.pinHash)) {
      ref.read(currentTeacherProvider.notifier).state = teacher;
      if (mounted) {
        Navigator.pop(sheetContext); // close bottom sheet
        context.go('/teacher/dashboard');
      }
    } else {
      const msg = 'Incorrect PIN. Please try again.';
      setState(() {
        _loginError = msg;
        _loginPin = '';
      });
      setError(msg); // update the bottom sheet directly
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private PIN Input Row Widget
// ─────────────────────────────────────────────────────────────────────────────

class _PinInputRow extends StatefulWidget {
  final ValueChanged<String> onChanged;

  const _PinInputRow({super.key, required this.onChanged});

  @override
  State<_PinInputRow> createState() => _PinInputRowState();
}

class _PinInputRowState extends State<_PinInputRow> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Rebuild when focus changes so the active-cell border animates correctly.
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // ── Four visible PIN cells ─────────────────────────────────────
          ...List.generate(4, (i) {
            final filled = i < _controller.text.length;
            final isActive =
                i == _controller.text.length && _focusNode.hasFocus;

            return Container(
              width: 56,
              height: 68,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      isActive ? const Color(0xFF1A56DB) : Colors.grey.shade300,
                  width: isActive ? 2 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Center(
                child: filled
                    ? Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF1A56DB),
                        ),
                      )
                    : null,
              ),
            );
          }),

          // ── Hidden text field that captures keyboard input ─────────────
          SizedBox(
            width: 0,
            height: 0,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              decoration: const InputDecoration(counterText: ''),
              onChanged: (val) {
                setState(() {});
                widget.onChanged(val);
              },
            ),
          ),
        ],
      ),
    );
  }
}
