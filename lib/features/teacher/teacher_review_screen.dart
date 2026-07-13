import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/services/providers.dart';
import '../../shared/services/teacher_review_service.dart';

/// Lets a teacher review the server-generated MCQs for a lesson before students
/// receive them: approve the good ones, edit wording/options, delete bad ones.
/// Only approved questions are served to students.
class TeacherReviewScreen extends ConsumerStatefulWidget {
  const TeacherReviewScreen({super.key, required this.lessonId});

  final String lessonId;

  @override
  ConsumerState<TeacherReviewScreen> createState() =>
      _TeacherReviewScreenState();
}

class _TeacherReviewScreenState extends ConsumerState<TeacherReviewScreen> {
  final TeacherReviewService _service = TeacherReviewService();

  bool _loading = true;
  String? _error;
  String _baseUrl = '';
  String _token = '';
  List<ReviewQuestion> _questions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final teacher = ref.read(currentTeacherProvider);
      if (teacher == null) {
        throw Exception('Please sign in as a teacher first.');
      }

      final link = ref.read(backendLinkServiceProvider);
      final lessonId = int.tryParse(widget.lessonId);
      if (lessonId == null) throw Exception('Invalid lesson.');

      final noteId = await link.getRemoteNoteId(lessonId);
      final teacherLink = await link.getTeacherLink(teacher.id);
      final token = await link.ensureTeacherToken(teacher.id);

      if (noteId == null || teacherLink == null || token == null) {
        throw Exception(
          'This lesson is not published to your class yet, so there are no '
          'questions to review online. Publish it first, then come back.',
        );
      }

      final questions = await _service.listQuestions(
        baseUrl: teacherLink.baseUrl,
        token: token,
        noteId: noteId,
      );

      if (!mounted) return;
      setState(() {
        _baseUrl = teacherLink.baseUrl;
        _token = token;
        _questions = questions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _toggleApprove(ReviewQuestion q) async {
    try {
      await _service.setApproved(
        baseUrl: _baseUrl,
        token: _token,
        id: q.id,
        approved: !q.approved,
      );
      setState(() => q.approved = !q.approved);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _approveAll() async {
    final pending = _questions.where((q) => !q.approved).toList();
    for (final q in pending) {
      try {
        await _service.setApproved(
            baseUrl: _baseUrl, token: _token, id: q.id, approved: true);
        if (mounted) setState(() => q.approved = true);
      } catch (_) {
        // continue; report at the end
      }
    }
    _snack('Approved ${pending.length} question(s).');
  }

  Future<void> _delete(ReviewQuestion q) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete question?'),
        content: Text(q.questionText),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _service.deleteQuestion(baseUrl: _baseUrl, token: _token, id: q.id);
      setState(() => _questions.removeWhere((x) => x.id == q.id));
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _edit(ReviewQuestion q) async {
    final qController = TextEditingController(text: q.questionText);
    final expController = TextEditingController(text: q.explanation);
    final optControllers =
        q.options.map((o) => TextEditingController(text: o.text)).toList();
    var correctIndex =
        q.options.indexWhere((o) => o.isCorrect).clamp(0, q.options.length - 1);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Edit question'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: qController,
                  decoration: const InputDecoration(labelText: 'Question'),
                  maxLines: null,
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < optControllers.length; i++)
                  Row(
                    children: [
                      Radio<int>(
                        value: i,
                        groupValue: correctIndex,
                        onChanged: (v) => setLocal(() => correctIndex = v ?? 0),
                      ),
                      Expanded(
                        child: TextField(
                          controller: optControllers[i],
                          decoration:
                              InputDecoration(labelText: 'Option ${i + 1}'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: expController,
                  decoration:
                      const InputDecoration(labelText: 'Explanation'),
                  maxLines: null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final newOptions = <ReviewOption>[];
    for (var i = 0; i < optControllers.length; i++) {
      newOptions.add(
          ReviewOption(text: optControllers[i].text, isCorrect: i == correctIndex));
    }
    try {
      await _service.updateQuestion(
        baseUrl: _baseUrl,
        token: _token,
        id: q.id,
        questionText: qController.text,
        options: newOptions,
        explanation: expController.text,
      );
      setState(() {
        q.questionText = qController.text;
        q.options = newOptions;
        q.explanation = expController.text;
      });
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review questions'),
        actions: [
          if (!_loading && _error == null && _questions.isNotEmpty)
            TextButton(
              onPressed: _approveAll,
              child: const Text('Approve all',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _message(_error!)
              : _questions.isEmpty
                  ? _message(
                      'No questions to review yet. They appear here after the '
                      'lesson is processed by the backend.')
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _questions.length,
                        itemBuilder: (_, i) => _card(_questions[i], i),
                      ),
                    ),
    );
  }

  Widget _message(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );

  Widget _card(ReviewQuestion q, int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Q${index + 1}. ${q.questionText}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(q.approved ? 'Approved' : 'Pending'),
                  backgroundColor:
                      q.approved ? Colors.green.shade100 : Colors.orange.shade100,
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final o in q.options)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      o.isCorrect
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: o.isCorrect ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(o.text)),
                  ],
                ),
              ),
            if (q.explanation.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(q.explanation,
                  style: const TextStyle(
                      fontSize: 13, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _toggleApprove(q),
                  icon: Icon(q.approved ? Icons.undo : Icons.check),
                  label: Text(q.approved ? 'Un-approve' : 'Approve'),
                ),
                TextButton.icon(
                  onPressed: () => _edit(q),
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _delete(q),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
