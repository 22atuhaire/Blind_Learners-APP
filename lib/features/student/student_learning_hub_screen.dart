import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';

class StudentLearningHubScreen extends ConsumerStatefulWidget {
  const StudentLearningHubScreen({super.key});

  @override
  ConsumerState<StudentLearningHubScreen> createState() =>
      _StudentLearningHubScreenState();
}

class _StudentLearningHubScreenState
    extends ConsumerState<StudentLearningHubScreen> {
  // ── Navigation State ──────────────────────────────────────────────────────

  Subject? _selectedSubject;
  Topic? _selectedTopic;
  Lesson? _selectedLesson;

  // ── UI State ──────────────────────────────────────────────────────────────

  int _currentQuestionIndex = 0;
  bool _isPlayingLesson = false;
  String _navigationBreadcrumb = 'Select a Subject';

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _speak(
            'Welcome to the Audio Learning Hub. Swipe up or down to navigate subjects, topics, and lessons.');
      }
    });
  }

  @override
  void dispose() {
    ref.read(ttsServiceProvider).stop();
    super.dispose();
  }

  // ── Speech ────────────────────────────────────────────────────────────────

  Future<void> _speak(String text) async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(text);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectedSubject == null) {
          context.go('/role');
        } else if (!didPop && _selectedSubject != null && _selectedTopic == null) {
          setState(() => _selectedSubject = null);
          _speak('Returned to subject selection.');
        } else if (!didPop && _selectedTopic != null && _selectedLesson == null) {
          setState(() => _selectedTopic = null);
          _speak('Returned to topic selection.');
        } else if (!didPop && _selectedLesson != null) {
          setState(() => _selectedLesson = null);
          _speak('Returned to lesson selection.');
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFEBF2FF),
        appBar: AppBar(
          title: const Text('Audio Learning Hub'),
          backgroundColor: const Color(0xFF1A56DB),
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_selectedLesson != null) {
                setState(() => _selectedLesson = null);
                _speak('Returned to lesson selection.');
              } else if (_selectedTopic != null) {
                setState(() => _selectedTopic = null);
                _speak('Returned to topic selection.');
              } else if (_selectedSubject != null) {
                setState(() => _selectedSubject = null);
                _speak('Returned to subject selection.');
              } else {
                context.go('/role');
              }
            },
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  _navigationBreadcrumb,
                  style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.white70,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ],
        ),
        body: _selectedLesson != null
            ? _buildLessonView()
            : _selectedTopic != null
                ? _buildLessonSelectionView()
                : _selectedSubject != null
                    ? _buildTopicSelectionView()
                    : _buildSubjectSelectionView(),
      ),
    );
  }

  // ── Subject Selection View ────────────────────────────────────────────────

  Widget _buildSubjectSelectionView() {
    return ref.watch(teacherSubjectsProvider).when(
      data: (subjects) {
        if (subjects.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.school_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No subjects available yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: subjects.length,
          itemBuilder: (context, index) {
            final subject = subjects[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Semantics(
                  label: 'Subject: ${subject.name}. Tap to select.',
                  button: true,
                  child: InkWell(
                    onTap: () {
                      setState(() => _selectedSubject = subject);
                      _speak('Selected subject: ${subject.name}');
                      setState(() =>
                          _navigationBreadcrumb = subject.name);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF1A56DB).withOpacity(0.1),
                            const Color(0xFF1A56DB).withOpacity(0.05),
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A56DB)
                                  .withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.subject_rounded,
                              size: 32,
                              color: Color(0xFF1A56DB),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  subject.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1A56DB),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Tap to explore topics',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF1A56DB),
                            size: 28,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (e, st) => Center(
        child: Text('Error: $e'),
      ),
    );
  }

  // ── Topic Selection View ──────────────────────────────────────────────────

  Widget _buildTopicSelectionView() {
    if (_selectedSubject == null) return const SizedBox.shrink();

    return ref.watch(subjectTopicsProvider(_selectedSubject!.id)).when(
      data: (topics) {
        if (topics.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.library_books_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No topics in this subject yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: topics.length,
          itemBuilder: (context, index) {
            final topic = topics[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Semantics(
                  label: 'Topic: ${topic.name}. Tap to select.',
                  button: true,
                  child: InkWell(
                    onTap: () {
                      setState(() => _selectedTopic = topic);
                      _speak('Selected topic: ${topic.name}');
                      setState(() =>
                          _navigationBreadcrumb =
                              '${_selectedSubject?.name} > ${topic.name}');
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF059669).withOpacity(0.1),
                            const Color(0xFF059669).withOpacity(0.05),
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF059669)
                                  .withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.folder_open_rounded,
                              size: 32,
                              color: Color(0xFF059669),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  topic.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF059669),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Tap to view lessons',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF059669),
                            size: 28,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (e, st) => Center(
        child: Text('Error: $e'),
      ),
    );
  }

  // ── Lesson Selection View ─────────────────────────────────────────────────

  Widget _buildLessonSelectionView() {
    if (_selectedTopic == null) return const SizedBox.shrink();

    return ref.watch(topicLessonProvider(_selectedTopic!.id)).when(
      data: (lesson) {
        if (lesson == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.description_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No lesson available for this topic yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Lesson card
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Semantics(
                label: 'Lesson: ${_selectedTopic?.name}. Tap to view.',
                button: true,
                child: InkWell(
                  onTap: () {
                    setState(() => _selectedLesson = lesson);
                    _speak(
                        'Opening lesson: ${_selectedTopic?.name}. Lesson text will be read to you.');
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF7C3AED).withOpacity(0.1),
                          const Color(0xFF7C3AED).withOpacity(0.05),
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C3AED)
                                .withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.description_rounded,
                            size: 32,
                            color: Color(0xFF7C3AED),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selectedTopic?.name ?? 'Lesson',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF7C3AED),
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Tap to read lesson content',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: Color(0xFF7C3AED),
                          size: 28,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (e, st) => Center(
        child: Text('Error: $e'),
      ),
    );
  }

  // ── Lesson Content View ───────────────────────────────────────────────────

  Widget _buildLessonView() {
    if (_selectedLesson == null) return const SizedBox.shrink();

    return ref.watch(lessonQuestionsProvider(_selectedLesson!.id)).when(
      data: (questions) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Lesson Content Card ────────────────────────────────────
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lesson Content',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A56DB),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _selectedLesson!.rawText,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A56DB),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: Icon(_isPlayingLesson
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                          label: Text(_isPlayingLesson
                              ? 'Pause Reading'
                              : 'Read Lesson'),
                          onPressed: () {
                            setState(
                                () => _isPlayingLesson = !_isPlayingLesson);
                            if (_isPlayingLesson) {
                              _speak(_selectedLesson!.rawText);
                            } else {
                              ref.read(ttsServiceProvider).stop();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Quiz Section ───────────────────────────────────────────
              if (questions.isNotEmpty) ...[
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Quiz',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A56DB),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A56DB)
                                    .withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Q${_currentQuestionIndex + 1}/${questions.length}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A56DB),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF059669),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () {
                              _speak(
                                  'Starting quiz. You have ${questions.length} questions to answer.');
                              context.pushNamed(
                                'studentQuiz',
                                pathParameters: {
                                  'lessonId': _selectedLesson!.id.toString(),
                                },
                              );
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.quiz_rounded),
                                SizedBox(width: 8),
                                Text(
                                  'Start Quiz',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          size: 32,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No quiz questions available for this lesson yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ),
      error: (e, st) => Center(
        child: Text('Error: $e'),
      ),
    );
  }
}
