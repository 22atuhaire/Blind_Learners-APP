import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

enum LearningStage { subjects, topics, lesson, quizConfirm, quiz }

class StudentLearningHubScreen extends ConsumerStatefulWidget {
  const StudentLearningHubScreen({super.key});

  @override
  ConsumerState<StudentLearningHubScreen> createState() =>
      _StudentLearningHubScreenState();
}

class _StudentLearningHubScreenState
    extends ConsumerState<StudentLearningHubScreen> {
  LearningStage _stage = LearningStage.subjects;
  int _subjectIndex = 0;
  int _topicIndex = 0;
  int _questionIndex = 0;
  int _answerIndex = 0;
  int _score = 0;
  bool _lessonPlaying = false;
  bool _quizAnswered = false;
  bool _quizComplete = false;
  String? _announcementKey;

  @override
  void initState() {
    super.initState();
    Future<void>(() async {
      await ref.read(ttsInitProvider.future);
      if (!mounted) return;
      _announceCurrentState(force: true);
    });
  }

  @override
  void dispose() {
    ref.read(ttsServiceProvider).stop();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(text);
  }

  List<Subject> _subjects() =>
      ref.read(allSubjectsProvider).valueOrNull ?? const [];

  List<Topic> _topicsForSubject(Subject subject) =>
      ref.read(subjectTopicsProvider(subject.id)).valueOrNull ?? const [];

  Lesson? _lessonForTopic(Topic topic) =>
      ref.read(topicLessonProvider(topic.id)).valueOrNull;

  List<Question> _questionsForLesson(Lesson lesson) =>
      ref.read(lessonQuestionsProvider(lesson.id)).valueOrNull ?? const [];

  List<_QuizOption> _quizOptions(Question question) {
    final items = <_QuizOption>[];

    void addOption(String label, String? text) {
      final value = text?.trim();
      if (value != null && value.isNotEmpty) {
        items.add(_QuizOption(label: label, text: value));
      }
    }

    addOption('1', question.optionA);
    addOption('2', question.optionB);
    addOption('3', question.optionC);
    addOption('4', question.optionD);
    return items;
  }

  void _announceCurrentState({bool force = false}) {
    if (!mounted) return;

    final key = switch (_stage) {
      LearningStage.subjects => 'subjects:$_subjectIndex',
      LearningStage.topics => 'topics:$_subjectIndex:$_topicIndex',
      LearningStage.lesson => 'lesson:$_subjectIndex:$_topicIndex',
      LearningStage.quizConfirm => 'quizConfirm:$_subjectIndex:$_topicIndex',
      LearningStage.quiz =>
        'quiz:$_subjectIndex:$_topicIndex:$_questionIndex:$_answerIndex:$_quizAnswered:$_quizComplete',
    };

    if (!force && _announcementKey == key) return;
    _announcementKey = key;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _speak(_announcementText());
    });
  }

  String _announcementText() {
    final subjects = _subjects();
    if (subjects.isEmpty) return 'No subjects available.';

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);

    switch (_stage) {
      case LearningStage.subjects:
        return 'Subjects. ${subject.name}. ${_subjectIndex + 1} of ${subjects.length}.';
      case LearningStage.topics:
        if (topics.isEmpty) return 'No topics available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        return '${subject.name} topics. ${topic.name}. ${_topicIndex + 1} of ${topics.length}.';
      case LearningStage.lesson:
        if (topics.isEmpty) return 'No topics available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        return '${topic.name} introduction. Ready to play.';
      case LearningStage.quizConfirm:
        return 'Go to quiz. Double tap to confirm.';
      case LearningStage.quiz:
        if (_quizComplete) return 'Quiz complete.';
        if (topics.isEmpty) return 'No questions available.';
        final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
        final lesson = _lessonForTopic(topic);
        if (lesson == null) return 'No questions available.';
        final questions = _questionsForLesson(lesson);
        if (questions.isEmpty) return 'No questions available.';
        return 'Question ${_questionIndex + 1} of ${questions.length}.';
    }
  }

  void _clampIndices() {
    final subjects = _subjects();
    if (subjects.isEmpty) {
      _subjectIndex = 0;
      _topicIndex = 0;
      return;
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final topics = _topicsForSubject(subjects[_subjectIndex]);
    if (topics.isEmpty) {
      _topicIndex = 0;
      return;
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
  }

  Lesson? _currentLesson() {
    final subjects = _subjects();
    if (subjects.isEmpty) return null;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) return null;

    final topic = topics[_topicIndex.clamp(0, topics.length - 1)];
    return _lessonForTopic(topic);
  }

  Question? _currentQuizQuestion() {
    final lesson = _currentLesson();
    if (lesson == null) return null;

    final questions = _questionsForLesson(lesson);
    if (questions.isEmpty) return null;
    if (_questionIndex < 0 || _questionIndex >= questions.length) return null;
    return questions[_questionIndex];
  }

  int _questionsCount() {
    final lesson = _currentLesson();
    if (lesson == null) return 0;
    return _questionsForLesson(lesson).length;
  }

  void _moveSubject(int delta) {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final next = _subjectIndex + delta;
    if (next < 0) {
      _speak('First subject.');
      return;
    }
    if (next >= subjects.length) {
      _speak('Last subject.');
      return;
    }

    setState(() {
      _subjectIndex = next;
      _topicIndex = 0;
      _stage = LearningStage.subjects;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
      _lessonPlaying = false;
    });
    _announceCurrentState();
  }

  void _moveTopic(int delta) {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) return;

    final next = _topicIndex + delta;
    if (next < 0) {
      _speak('First topic.');
      return;
    }
    if (next >= topics.length) {
      _speak('Last topic.');
      return;
    }

    setState(() {
      _topicIndex = next;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
      if (_stage == LearningStage.subjects) {
        _stage = LearningStage.topics;
      }
    });
    _announceCurrentState();
  }

  void _openCurrentSubject() {
    final subjects = _subjects();
    if (subjects.isEmpty) return;

    final subject = subjects[_subjectIndex.clamp(0, subjects.length - 1)];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      _speak('No topics available.');
      return;
    }

    setState(() {
      _topicIndex = 0;
      _stage = LearningStage.topics;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    _announceCurrentState(force: true);
  }

  void _openCurrentTopic() {
    final lesson = _currentLesson();
    if (lesson == null) {
      _speak('No lesson available.');
      return;
    }

    setState(() {
      _stage = LearningStage.lesson;
      _lessonPlaying = false;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    _announceCurrentState(force: true);
  }

  void _toggleLessonPlayback() {
    final lesson = _currentLesson();
    if (lesson == null) return;

    setState(() => _lessonPlaying = !_lessonPlaying);
    if (_lessonPlaying) {
      _speak(lesson.rawText);
    } else {
      ref.read(ttsServiceProvider).stop();
      _speak('Paused.');
    }
  }

  void _replayLesson() {
    final lesson = _currentLesson();
    if (lesson == null) return;

    ref.read(ttsServiceProvider).stop();
    setState(() => _lessonPlaying = false);
    _speak(lesson.rawText);
  }

  void _openQuizConfirmation() {
    setState(() {
      _stage = LearningStage.quizConfirm;
    });
    _announceCurrentState(force: true);
  }

  void _startQuiz() {
    final lesson = _currentLesson();
    if (lesson == null) {
      _speak('No questions available.');
      return;
    }

    final questions = _questionsForLesson(lesson);
    if (questions.isEmpty) {
      _speak('No questions available.');
      return;
    }

    setState(() {
      _stage = LearningStage.quiz;
      _questionIndex = 0;
      _answerIndex = 0;
      _quizAnswered = false;
      _quizComplete = false;
      _score = 0;
    });
    _announceCurrentState(force: true);
  }

  void _moveQuizAnswer(int delta) {
    final question = _currentQuizQuestion();
    if (question == null || _quizAnswered || _quizComplete) return;

    final options = _quizOptions(question);
    if (options.isEmpty) return;

    setState(() {
      _answerIndex = (_answerIndex + delta) % options.length;
      if (_answerIndex < 0) _answerIndex = options.length - 1;
    });

    _speak('Option ${_answerIndex + 1}. ${options[_answerIndex].text}');
  }

  Future<void> _selectQuizAnswer() async {
    final question = _currentQuizQuestion();
    if (question == null) return;

    final options = _quizOptions(question);
    if (options.isEmpty) return;

    if (_quizAnswered) {
      if (_questionIndex >= _questionsCount() - 1) {
        setState(() {
          _stage = LearningStage.lesson;
          _quizComplete = false;
          _quizAnswered = false;
        });
        _announceCurrentState(force: true);
        return;
      }
      _nextQuizQuestion();
      return;
    }

    final selected = options[_answerIndex.clamp(0, options.length - 1)];
    final selectedIndex = options.indexOf(selected);
    final boundedIndex = selectedIndex < 0
        ? 0
        : selectedIndex > 3
            ? 3
            : selectedIndex;
    final selectedLetter = const ['A', 'B', 'C', 'D'][boundedIndex];

    setState(() {
      _quizAnswered = true;
    });

    if (question.correctOption.toUpperCase() == selectedLetter) {
      _score += 1;
      await _speak('Correct.');
    } else {
      await _speak('Incorrect.');
    }
    await _speak('Swipe right for next question.');

    if (_questionIndex >= _questionsCount() - 1) {
      setState(() => _quizComplete = true);
      await _speak('Quiz complete.');
    }
  }

  void _nextQuizQuestion() {
    final total = _questionsCount();
    if (total == 0) return;

    if (_questionIndex >= total - 1) {
      setState(() {
        _quizComplete = true;
      });
      _speak('Quiz complete.');
      return;
    }

    setState(() {
      _questionIndex += 1;
      _answerIndex = 0;
      _quizAnswered = false;
      _quizComplete = false;
    });
    _announceCurrentState(force: true);
  }

  Widget _stageCard({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required String hint,
    String? progress,
    String? actionLabel,
    String? body,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withOpacity(0.18), accent.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.15),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: 40),
          ),
          const SizedBox(height: 16),
          if (progress != null) ...[
            Text(
              progress,
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: accent,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 16),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.75),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              actionLabel ?? hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String message, IconData icon) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.75),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: const Color(0xFF1A56DB)),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A56DB),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubjectsStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];

    return _stageCard(
      icon: Icons.school_rounded,
      accent: const Color(0xFF1A56DB),
      title: subject.name,
      subtitle: 'Subjects',
      progress: '${_subjectIndex + 1} of ${subjects.length}',
      actionLabel: 'Double tap to open',
      hint:
          'Swipe right for next. Swipe left for previous. Double tap to open.',
    );
  }

  Widget _buildTopicsStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return _stageCard(
      icon: Icons.layers_rounded,
      accent: const Color(0xFF059669),
      title: topic.name,
      subtitle: '${subject.name} topics',
      progress: '${_topicIndex + 1} of ${topics.length}',
      actionLabel: 'Double tap to open lesson',
      hint:
          'Swipe right for next. Swipe left for previous. Double tap to open.',
    );
  }

  Widget _buildLessonStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return _stageCard(
              icon: _lessonPlaying
                  ? Icons.pause_circle_rounded
                  : Icons.play_circle_rounded,
              accent: const Color(0xFF7C3AED),
              title: topic.name,
              subtitle: 'Ready to play',
              body: lesson.rawText.length > 220
                  ? '${lesson.rawText.substring(0, 220)}...'
                  : lesson.rawText,
              actionLabel:
                  _lessonPlaying ? 'Double tap to pause' : 'Double tap to play',
              hint:
                  'Swipe right for next topic. Swipe left for previous. Swipe up to replay. Swipe down for quiz.',
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _emptyState(
              'Could not load lesson.', Icons.error_outline_rounded),
        );
  }

  Widget _buildQuizConfirmStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return _stageCard(
              icon: Icons.quiz_rounded,
              accent: const Color(0xFF0EA5E9),
              title: 'Go to quiz',
              subtitle: topic.name,
              actionLabel: 'Double tap to confirm',
              hint: 'Double tap to confirm. Swipe up to return.',
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) =>
              _emptyState('Could not load quiz.', Icons.error_outline_rounded),
        );
  }

  Widget _buildQuizStage(List<Subject> subjects) {
    if (subjects.isEmpty) {
      return _emptyState('No subjects available.', Icons.menu_book_rounded);
    }

    _subjectIndex = _subjectIndex.clamp(0, subjects.length - 1);
    final subject = subjects[_subjectIndex];
    final topics = _topicsForSubject(subject);
    if (topics.isEmpty) {
      return _emptyState('No topics available.', Icons.layers_rounded);
    }

    _topicIndex = _topicIndex.clamp(0, topics.length - 1);
    final topic = topics[_topicIndex];

    return ref.watch(topicLessonProvider(topic.id)).when(
          data: (lesson) {
            if (lesson == null) {
              return _emptyState(
                  'No lesson available.', Icons.description_rounded);
            }

            return ref.watch(lessonQuestionsProvider(lesson.id)).when(
                  data: (questions) {
                    if (questions.isEmpty) {
                      return _emptyState(
                          'No questions available.', Icons.quiz_outlined);
                    }

                    if (_questionIndex >= questions.length) {
                      _questionIndex = questions.length - 1;
                    }
                    final question = questions[_questionIndex];
                    final options = _quizOptions(question);
                    if (options.isEmpty) {
                      return _emptyState(
                          'No answer options.', Icons.quiz_outlined);
                    }

                    _answerIndex = _answerIndex.clamp(0, options.length - 1);
                    final current = options[_answerIndex];

                    return _stageCard(
                      icon: Icons.quiz_rounded,
                      accent: const Color(0xFF1A56DB),
                      title:
                          'Question ${_questionIndex + 1} of ${questions.length}',
                      subtitle: question.questionText,
                      body: _quizAnswered
                          ? (_quizComplete
                              ? 'Quiz complete. Score $_score of ${questions.length}.'
                              : 'Swipe right for next question.')
                          : 'Option ${current.label}. ${current.text}',
                      actionLabel: _quizComplete
                          ? 'Double tap to return to lesson'
                          : 'Double tap to select answer',
                      hint: _quizAnswered
                          ? 'Swipe right for next question. Swipe left for previous question.'
                          : 'Swipe right for next answer. Swipe left for previous answer. Double tap to select.',
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) => _emptyState(
                      'Could not load quiz.', Icons.error_outline_rounded),
                );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _emptyState(
              'Could not load lesson.', Icons.error_outline_rounded),
        );
  }

  void _onSwipeRight() {
    switch (_stage) {
      case LearningStage.subjects:
        _moveSubject(1);
        break;
      case LearningStage.topics:
        _moveTopic(1);
        break;
      case LearningStage.lesson:
        _moveTopic(1);
        break;
      case LearningStage.quizConfirm:
        break;
      case LearningStage.quiz:
        if (_quizAnswered) {
          _nextQuizQuestion();
        } else {
          _moveQuizAnswer(1);
        }
        break;
    }
  }

  void _onSwipeLeft() {
    switch (_stage) {
      case LearningStage.subjects:
        _moveSubject(-1);
        break;
      case LearningStage.topics:
        _moveTopic(-1);
        break;
      case LearningStage.lesson:
        _moveTopic(-1);
        break;
      case LearningStage.quizConfirm:
        setState(() => _stage = LearningStage.lesson);
        _announceCurrentState(force: true);
        break;
      case LearningStage.quiz:
        if (_quizAnswered) {
          if (_questionIndex > 0) {
            setState(() {
              _questionIndex -= 1;
              _answerIndex = 0;
              _quizAnswered = false;
              _quizComplete = false;
            });
            _announceCurrentState(force: true);
          }
        } else {
          _moveQuizAnswer(-1);
        }
        break;
    }
  }

  void _onSwipeUp() {
    if (_stage == LearningStage.lesson) {
      _replayLesson();
    } else if (_stage == LearningStage.quizConfirm) {
      setState(() => _stage = LearningStage.lesson);
      _announceCurrentState(force: true);
    }
  }

  void _onSwipeDown() {
    if (_stage == LearningStage.lesson) {
      _openQuizConfirmation();
    }
  }

  void _onDoubleTap() {
    switch (_stage) {
      case LearningStage.subjects:
        _openCurrentSubject();
        break;
      case LearningStage.topics:
        _openCurrentTopic();
        break;
      case LearningStage.lesson:
        _toggleLessonPlayback();
        break;
      case LearningStage.quizConfirm:
        _startQuiz();
        break;
      case LearningStage.quiz:
        _selectQuizAnswer();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(allSubjectsProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (_stage == LearningStage.quiz) {
          setState(() {
            _stage = LearningStage.lesson;
            _quizAnswered = false;
            _quizComplete = false;
            _score = 0;
          });
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.quizConfirm) {
          setState(() => _stage = LearningStage.lesson);
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.lesson) {
          setState(() => _stage = LearningStage.topics);
          _announceCurrentState(force: true);
        } else if (_stage == LearningStage.topics) {
          setState(() => _stage = LearningStage.subjects);
          _announceCurrentState(force: true);
        } else {
          context.go('/role');
        }
      },
      child: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _onDoubleTap,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity > 120) {
              _onSwipeRight();
            } else if (velocity < -120) {
              _onSwipeLeft();
            }
          },
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity > 120) {
              _onSwipeDown();
            } else if (velocity < -120) {
              _onSwipeUp();
            }
          },
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF5F9FF),
                  Color(0xFFE7F0FF),
                  Color(0xFFF6F7FB),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A56DB).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.headphones_rounded,
                            color: Color(0xFF1A56DB),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Audio Learning Hub',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF123B7A),
                            ),
                          ),
                        ),
                        _stageChip(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _buildBody(subjectsAsync),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.82),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Text(
                        _footerHint(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF355CA8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stageChip() {
    final label = switch (_stage) {
      LearningStage.subjects => 'Subjects',
      LearningStage.topics => 'Topics',
      LearningStage.lesson => 'Lesson',
      LearningStage.quizConfirm => 'Quiz',
      LearningStage.quiz => 'Question',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A56DB).withOpacity(0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF1A56DB),
        ),
      ),
    );
  }

  String _footerHint() {
    return switch (_stage) {
      LearningStage.subjects =>
        'Swipe right for next. Swipe left for previous. Double tap to open.',
      LearningStage.topics =>
        'Swipe right for next. Swipe left for previous. Double tap to open.',
      LearningStage.lesson =>
        'Double tap to play or pause. Swipe up to replay. Swipe down for quiz.',
      LearningStage.quizConfirm =>
        'Double tap to confirm quiz. Swipe up to return.',
      LearningStage.quiz => _quizAnswered
          ? 'Swipe right for next question. Swipe left for previous question.'
          : 'Swipe right for next answer. Swipe left for previous answer. Double tap to select.',
    };
  }

  Widget _buildBody(AsyncValue<List<Subject>> subjectsAsync) {
    return subjectsAsync.when(
      data: (subjects) {
        _clampIndices();
        return switch (_stage) {
          LearningStage.subjects => _buildSubjectsStage(subjects),
          LearningStage.topics => _buildTopicsStage(subjects),
          LearningStage.lesson => _buildLessonStage(subjects),
          LearningStage.quizConfirm => _buildQuizConfirmStage(subjects),
          LearningStage.quiz => _buildQuizStage(subjects),
        };
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) =>
          _emptyState('Could not load subjects.', Icons.error_outline_rounded),
    );
  }
}

class _QuizOption {
  const _QuizOption({required this.label, required this.text});

  final String label;
  final String text;
}
