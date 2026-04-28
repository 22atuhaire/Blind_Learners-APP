import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Teacher Upload Screen
// Allows a teacher to pick a PDF / DOCX file, preview extracted text, trigger
// offline AI question generation, and persist everything to the local database
// before redirecting to the questions review screen.
// ─────────────────────────────────────────────────────────────────────────────

class TeacherUploadScreen extends ConsumerStatefulWidget {
  final String topicId;
  const TeacherUploadScreen({super.key, required this.topicId});

  @override
  ConsumerState<TeacherUploadScreen> createState() =>
      _TeacherUploadScreenState();
}

class _TeacherUploadScreenState extends ConsumerState<TeacherUploadScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  String? _filePath; // persisted so _saveLesson can re-read if needed
  String? _fileName;
  String _extractedText = '';
  bool _extracting = false;
  bool _saving = false;
  int _questionsGenerated = 0;
  String _statusMessage = '';
  String _error = '';

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      appBar: AppBar(
        title: const Text('Upload Notes'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 1. Topic info header ─────────────────────────────────────────
            _buildTopicHeader(),
            const SizedBox(height: 20),

            // ── 2. File picker card ──────────────────────────────────────────
            _buildFilePickerCard(),

            // ── 3. Extracted text preview ────────────────────────────────────
            if (_extractedText.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildTextPreviewCard(),
            ],

            // ── 4. Status / error feedback ───────────────────────────────────
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildStatusRow(),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildErrorRow(),
            ],

            // ── 5. Save button ────────────────────────────────────────────────
            if (_extractedText.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildSaveButton(),
            ],

            // Bottom breathing room for FAB / keyboard avoidance.
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Section builders ───────────────────────────────────────────────────────

  Widget _buildTopicHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Upload lesson notes',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Topic #${widget.topicId} — choose a PDF or Word document to get started.',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildFilePickerCard() {
    return Card(
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Card header row ───────────────────────────────────────────
            const Row(
              children: [
                Icon(
                  Icons.upload_file_rounded,
                  color: Color(0xFF1A56DB),
                  size: 32,
                ),
                SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select a file',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'PDF or Word document (.docx)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── File picker / file-chosen UI ──────────────────────────────
            if (_fileName == null) ...[
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text(
                    'Choose File',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A56DB),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _extracting ? null : _pickFile,
                ),
              ),
            ] else ...[
              // Show selected filename with a green checkmark.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF16A34A),
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _fileName!,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Change File'),
                onPressed: _extracting ? null : _pickFile,
              ),
            ],

            // ── Extraction in-progress indicator ──────────────────────────
            if (_extracting) ...[
              const SizedBox(height: 20),
              const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
              const SizedBox(height: 10),
              const Center(
                child: Text(
                  'Extracting text from file…',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTextPreviewCard() {
    return Card(
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Extracted Text Preview',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Color(0xFF1A56DB),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 180,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Text(
                  _extractedText,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Questions will be auto-generated from this text',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.check_circle_outline_rounded,
          color: Color(0xFF16A34A),
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _statusMessage,
            style: const TextStyle(
              color: Color(0xFF16A34A),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.error_outline_rounded,
          color: Color(0xFFDC2626),
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _error,
            style: const TextStyle(
              color: Color(0xFFDC2626),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A56DB),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF1A56DB).withOpacity(0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
        ),
        onPressed: _saving ? null : _saveLesson,
        child: _saving
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              )
            : const Text(
                'Save & Generate Questions',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  // ── Logic ──────────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx'],
    );

    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    setState(() {
      _filePath = file.path;
      _fileName = file.name;
      _extractedText = '';
      _extracting = true;
      _error = '';
      _statusMessage = '';
    });

    try {
      final extractor = ref.read(fileExtractionServiceProvider);
      final text = await extractor.extractText(_filePath!);

      if (text.trim().isEmpty) {
        setState(() {
          _extracting = false;
          _error =
              'Could not extract text from this file. Please try a different file.';
        });
        return;
      }

      setState(() {
        _extractedText = text.trim();
        _extracting = false;
      });
    } catch (e) {
      setState(() {
        _extracting = false;
        _error = 'Error reading file: ${e.toString()}';
      });
    }
  }

  Future<void> _saveLesson() async {
    if (_extractedText.isEmpty) return;

    setState(() {
      _saving = true;
      _error = '';
      _statusMessage = '';
    });

    try {
      final topicId = int.parse(widget.topicId);
      final db = ref.read(appDatabaseProvider);

      // ── 1. Persist the lesson ──────────────────────────────────────────
      final lessonId = await db.lessonDao.insertLesson(
        LessonsTableCompanion(
          topicId: Value(topicId),
          rawText: Value(_extractedText),
          createdAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

      // ── 2. Generate questions offline ─────────────────────────────────
      final aiService = ref.read(aiQuestionServiceProvider);
      final aiQuestions = aiService.generateQuestions(_extractedText);

      // ── 3. Persist each generated question ────────────────────────────
      for (int i = 0; i < aiQuestions.length; i++) {
        final q = aiQuestions[i];
        await db.questionDao.insertQuestion(
          QuestionsTableCompanion(
            lessonId: Value(lessonId),
            questionText: Value(q.questionText),
            optionA: Value(q.optionA),
            optionB: Value(q.optionB),
            optionC: Value(q.optionC),
            optionD: Value(q.optionD),
            correctOption: Value(q.correctOption),
            explanation: Value(q.explanation),
            positionInLesson: Value(i),
            source: const Value('ai'),
          ),
        );
      }

      setState(() {
        _saving = false;
        _questionsGenerated = aiQuestions.length;
        _statusMessage =
            '$_questionsGenerated questions generated. Redirecting…';
      });

      // ── 4. Navigate to questions review after a brief pause ───────────
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        context.pushNamed(
          'teacherQuestions',
          pathParameters: {'lessonId': lessonId.toString()},
        );
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Error saving lesson: ${e.toString()}';
      });
    }
  }
}
