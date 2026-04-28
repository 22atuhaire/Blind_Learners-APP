import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Teacher Questions Screen
// Displays all questions for a given lesson, allowing the teacher to review,
// edit, add, and delete questions before students access them.
// ─────────────────────────────────────────────────────────────────────────────

class TeacherQuestionsScreen extends ConsumerStatefulWidget {
  final String lessonId;
  const TeacherQuestionsScreen({super.key, required this.lessonId});

  @override
  ConsumerState<TeacherQuestionsScreen> createState() =>
      _TeacherQuestionsScreenState();
}

class _TeacherQuestionsScreenState
    extends ConsumerState<TeacherQuestionsScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  List<Question> _questions = [];
  bool _loading = true;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  Future<void> _loadQuestions() async {
    final id = int.parse(widget.lessonId);
    final db = ref.read(appDatabaseProvider);
    final q = await db.questionDao.getQuestionsByLessonId(id);
    if (!mounted) return;
    setState(() {
      _questions = q;
      _loading = false;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      appBar: AppBar(
        title: Text('Review Questions (${_questions.length})'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Info banner ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A56DB).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Review and edit AI-generated questions before students see them.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFF1A56DB),
                      ),
                    ),
                  ),
                ),

                // ── Question list ──────────────────────────────────────────
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    // +1 for the "Add New Question" card at the bottom.
                    itemCount: _questions.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _questions.length) {
                        return _buildAddQuestionCard();
                      }
                      return _buildQuestionCard(_questions[index], index);
                    },
                  ),
                ),
              ],
            ),
    );
  }

  // ── Question card ──────────────────────────────────────────────────────────

  Widget _buildQuestionCard(Question q, int i) {
    final isTeacher = q.source == 'teacher';
    final badgeColor =
        isTeacher ? const Color(0xFF16A34A) : const Color(0xFF1A56DB);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        // ── Avatar ────────────────────────────────────────────────────────
        leading: CircleAvatar(
          backgroundColor: badgeColor,
          foregroundColor: Colors.white,
          radius: 16,
          child: Text(
            '${i + 1}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        // ── Question text ─────────────────────────────────────────────────
        title: Text(
          q.questionText,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        // ── Source badge + answer key ─────────────────────────────────────
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isTeacher ? 'Teacher' : 'AI',
                style: TextStyle(
                  fontSize: 11,
                  color: badgeColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Answer: ${q.correctOption}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        // ── Expanded content ──────────────────────────────────────────────
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _optionRow('A', q.optionA, q.correctOption == 'A'),
                _optionRow('B', q.optionB, q.correctOption == 'B'),
                _optionRow('C', q.optionC, q.correctOption == 'C'),
                if (q.optionD != null && q.optionD!.isNotEmpty)
                  _optionRow('D', q.optionD!, q.correctOption == 'D'),
                const SizedBox(height: 8),
                Text(
                  'Explanation: ${q.explanation}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 12),
                // ── Edit / delete buttons ──────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit'),
                        onPressed: () => _showEditQuestionDialog(q),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.red,
                        ),
                        label: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.red.shade200),
                        ),
                        onPressed: () => _confirmDeleteQuestion(q),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── "Add New Question" card ────────────────────────────────────────────────

  Widget _buildAddQuestionCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: const Color(0xFF1A56DB).withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: ListTile(
        leading: const Icon(
          Icons.add_circle_outline,
          color: Color(0xFF1A56DB),
        ),
        title: const Text(
          'Add New Question',
          style: TextStyle(
            color: Color(0xFF1A56DB),
            fontWeight: FontWeight.w600,
          ),
        ),
        onTap: _showAddQuestionDialog,
      ),
    );
  }

  // ── Option row ─────────────────────────────────────────────────────────────

  Widget _optionRow(String letter, String text, bool isCorrect) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isCorrect
            ? const Color(0xFF16A34A).withOpacity(0.08)
            : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCorrect ? const Color(0xFF16A34A) : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          // ── Letter circle ──────────────────────────────────────────────
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCorrect ? const Color(0xFF16A34A) : Colors.grey.shade200,
            ),
            child: Center(
              child: Text(
                letter,
                style: TextStyle(
                  color: isCorrect ? Colors.white : Colors.grey.shade700,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // ── Option text ────────────────────────────────────────────────
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color:
                    isCorrect ? const Color(0xFF16A34A) : Colors.grey.shade800,
                fontWeight: isCorrect ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          // ── Correct tick ───────────────────────────────────────────────
          if (isCorrect)
            const Icon(
              Icons.check_circle,
              size: 16,
              color: Color(0xFF16A34A),
            ),
        ],
      ),
    );
  }

  // ── Shared form-field helper ───────────────────────────────────────────────

  Widget _dialogField({
    required TextEditingController controller,
    required String label,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
    );
  }

  // ── Edit question dialog ───────────────────────────────────────────────────

  void _showEditQuestionDialog(Question q) {
    // Controllers are created outside the builder so they are not recreated
    // on every StatefulBuilder rebuild triggered by the dropdown setState.
    final qCtrl = TextEditingController(text: q.questionText);
    final aCtrl = TextEditingController(text: q.optionA);
    final bCtrl = TextEditingController(text: q.optionB);
    final cCtrl = TextEditingController(text: q.optionC);
    final dCtrl = TextEditingController(text: q.optionD ?? '');
    final exCtrl = TextEditingController(text: q.explanation);
    String correctOption = q.correctOption;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            // Fixed height ensures Expanded works correctly inside the Column.
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.8,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Dialog title ───────────────────────────────────────
                    const Text(
                      'Edit Question',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Scrollable fields ──────────────────────────────────
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _dialogField(
                              controller: qCtrl,
                              label: 'Question',
                              maxLines: 3,
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: aCtrl,
                              label: 'Option A',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: bCtrl,
                              label: 'Option B',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: cCtrl,
                              label: 'Option C',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: dCtrl,
                              label: 'Option D (optional)',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: exCtrl,
                              label: 'Explanation',
                              maxLines: 2,
                            ),
                            const SizedBox(height: 14),
                            // ── Correct answer dropdown ────────────────────
                            Row(
                              children: [
                                const Text(
                                  'Correct Answer:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                DropdownButton<String>(
                                  value: correctOption,
                                  items: ['A', 'B', 'C', 'D']
                                      .map(
                                        (l) => DropdownMenuItem(
                                          value: l,
                                          child: Text(l),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setDialogState(() => correctOption = v);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── Action buttons ─────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1A56DB),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () async {
                              final db = ref.read(appDatabaseProvider);
                              await db.questionDao.updateQuestion(
                                q.id,
                                QuestionsTableCompanion(
                                  questionText: Value(qCtrl.text.trim()),
                                  optionA: Value(aCtrl.text.trim()),
                                  optionB: Value(bCtrl.text.trim()),
                                  optionC: Value(cCtrl.text.trim()),
                                  optionD: Value(
                                    dCtrl.text.trim().isEmpty
                                        ? null
                                        : dCtrl.text.trim(),
                                  ),
                                  correctOption: Value(correctOption),
                                  explanation: Value(exCtrl.text.trim()),
                                ),
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                              await _loadQuestions();
                            },
                            child: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      // Dispose controllers once the dialog is fully closed.
      qCtrl.dispose();
      aCtrl.dispose();
      bCtrl.dispose();
      cCtrl.dispose();
      dCtrl.dispose();
      exCtrl.dispose();
    });
  }

  // ── Add question dialog ────────────────────────────────────────────────────

  void _showAddQuestionDialog() {
    final qCtrl = TextEditingController();
    final aCtrl = TextEditingController();
    final bCtrl = TextEditingController();
    final cCtrl = TextEditingController();
    final dCtrl = TextEditingController();
    final exCtrl = TextEditingController();
    String correctOption = 'A';
    // Capture current list length so the new question is appended correctly
    // even if _loadQuestions fires before the dialog closes.
    final nextPosition = _questions.length;
    final lessonId = int.parse(widget.lessonId);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.8,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Dialog title ───────────────────────────────────────
                    const Text(
                      'Add New Question',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Scrollable fields ──────────────────────────────────
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _dialogField(
                              controller: qCtrl,
                              label: 'Question',
                              maxLines: 3,
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: aCtrl,
                              label: 'Option A',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: bCtrl,
                              label: 'Option B',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: cCtrl,
                              label: 'Option C',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: dCtrl,
                              label: 'Option D (optional)',
                            ),
                            const SizedBox(height: 10),
                            _dialogField(
                              controller: exCtrl,
                              label: 'Explanation',
                              maxLines: 2,
                            ),
                            const SizedBox(height: 14),
                            // ── Correct answer dropdown ────────────────────
                            Row(
                              children: [
                                const Text(
                                  'Correct Answer:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                DropdownButton<String>(
                                  value: correctOption,
                                  items: ['A', 'B', 'C', 'D']
                                      .map(
                                        (l) => DropdownMenuItem(
                                          value: l,
                                          child: Text(l),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setDialogState(() => correctOption = v);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── Action buttons ─────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1A56DB),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () async {
                              // Require at least the question text and
                              // options A–C before saving.
                              if (qCtrl.text.trim().isEmpty ||
                                  aCtrl.text.trim().isEmpty ||
                                  bCtrl.text.trim().isEmpty ||
                                  cCtrl.text.trim().isEmpty) {
                                return;
                              }
                              final db = ref.read(appDatabaseProvider);
                              await db.questionDao.insertQuestion(
                                QuestionsTableCompanion(
                                  lessonId: Value(lessonId),
                                  questionText: Value(qCtrl.text.trim()),
                                  optionA: Value(aCtrl.text.trim()),
                                  optionB: Value(bCtrl.text.trim()),
                                  optionC: Value(cCtrl.text.trim()),
                                  optionD: Value(
                                    dCtrl.text.trim().isEmpty
                                        ? null
                                        : dCtrl.text.trim(),
                                  ),
                                  correctOption: Value(correctOption),
                                  explanation: Value(exCtrl.text.trim()),
                                  positionInLesson: Value(nextPosition),
                                  source: Value('teacher'),
                                ),
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                              await _loadQuestions();
                            },
                            child: const Text('Add'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      // Dispose controllers once the dialog is fully closed.
      qCtrl.dispose();
      aCtrl.dispose();
      bCtrl.dispose();
      cCtrl.dispose();
      dCtrl.dispose();
      exCtrl.dispose();
    });
  }

  // ── Confirm delete question dialog ─────────────────────────────────────────

  void _confirmDeleteQuestion(Question q) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Question'),
        content: const Text('Delete this question? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final db = ref.read(appDatabaseProvider);
              await db.questionDao.deleteQuestion(q.id);
              if (ctx.mounted) Navigator.pop(ctx);
              await _loadQuestions();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
