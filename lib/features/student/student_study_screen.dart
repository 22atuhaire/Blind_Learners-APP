import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class StudentStudyScreen extends ConsumerStatefulWidget {
  final String topicId;
  const StudentStudyScreen({super.key, required this.topicId});

  @override
  ConsumerState<StudentStudyScreen> createState() => _StudentStudyScreenState();
}

class _StudentStudyScreenState extends ConsumerState<StudentStudyScreen> {
  Topic? _topic;
  Lesson? _lesson;
  int _questionCount = 0;
  int? _previousTopicId;
  int? _nextTopicId;

  List<String> _segments = const [];
  int _segmentIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = true;
  String? _error;
  int _playToken = 0;
  int _lastSwipeMs = 0;

  static const double _minSwipeVelocity = 420;
  static const int _swipeCooldownMs = 700;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _playToken++;
    ref.read(ttsServiceProvider).stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await ref.read(ttsInitProvider.future);
    await _loadTopicContext(announce: true);
  }

  Future<void> _loadTopicContext({required bool announce}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final topicInt = int.tryParse(widget.topicId);
    if (topicInt == null) {
      setState(() {
        _isLoading = false;
        _error = 'Invalid topic id.';
      });
      return;
    }

    final db = ref.read(appDatabaseProvider);
    final tts = ref.read(ttsServiceProvider);

    try {
      final topic = await (db.select(db.topicsTable)
            ..where((t) => t.id.equals(topicInt)))
          .getSingleOrNull();

      if (topic == null) {
        setState(() {
          _isLoading = false;
          _error = 'Topic not found.';
        });
        await tts.speak('Topic not found.');
        return;
      }

      final subjectTopics = await db.topicDao.getTopicsBySubjectId(topic.subjectId);
      final lessons = await db.lessonDao.getLessonsByTopicId(topic.id);
      final lesson = lessons.isEmpty ? null : lessons.first;
      final questions = lesson == null
          ? <Question>[]
          : await db.questionDao.getQuestionsByLessonId(lesson.id);

      final currentIndex = subjectTopics.indexWhere((t) => t.id == topic.id);
      final prevId = currentIndex > 0 ? subjectTopics[currentIndex - 1].id : null;
      final nextId = (currentIndex >= 0 && currentIndex < subjectTopics.length - 1)
          ? subjectTopics[currentIndex + 1].id
          : null;

      final segments = _splitLessonText(lesson?.rawText ?? '');

      if (!mounted) return;
      setState(() {
        _topic = topic;
        _lesson = lesson;
        _questionCount = questions.length;
        _previousTopicId = prevId;
        _nextTopicId = nextId;
        _segments = segments;
        _segmentIndex = 0;
        _isPlaying = false;
        _isLoading = false;
      });

      if (announce) {
        await _speakOrientation();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load this topic.';
      });
      await tts.speak('Could not load this topic.');
    }
  }

  List<String> _splitLessonText(String rawText) {
    return rawText
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  double get _progressValue {
    if (_segments.isEmpty) return 0;
    final ratio = _segmentIndex / _segments.length;
    return ratio.clamp(0, 1);
  }

  Future<void> _speakOrientation() async {
    final tts = ref.read(ttsServiceProvider);
    final topicName = _topic?.name ?? 'Unknown topic';
    final progressPercent = (_progressValue * 100).round();
    final summary = 'You are in $topicName. Progress is $progressPercent percent. '
        'Tap middle to play or pause. '
        'Swipe right for next topic or left for previous topic. '
        'Double tap bottom when you are ready for questions.';
    await tts.speak(summary);
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _pausePlayback(announce: true);
      return;
    }
    await _startPlayback();
  }

  Future<void> _startPlayback() async {
    final tts = ref.read(ttsServiceProvider);

    if (_segments.isEmpty) {
      await tts.speak('There is no lesson audio for this topic yet.');
      return;
    }

    if (_segmentIndex >= _segments.length) {
      setState(() {
        _segmentIndex = 0;
      });
    }

    final token = ++_playToken;
    setState(() {
      _isPlaying = true;
    });

    await tts.speak('Starting lesson.');

    while (mounted && _isPlaying && token == _playToken && _segmentIndex < _segments.length) {
      final current = _segments[_segmentIndex];
      await tts.speakAndWait(current);
      if (!mounted || !_isPlaying || token != _playToken) {
        return;
      }
      setState(() {
        _segmentIndex += 1;
      });
    }

    if (!mounted || token != _playToken) return;

    setState(() {
      _isPlaying = false;
    });

    if (_segmentIndex >= _segments.length) {
      await tts.speak('Lesson complete. You can rest, or double tap the bottom zone for questions.');
    }
  }

  Future<void> _pausePlayback({required bool announce}) async {
    if (!_isPlaying) return;

    _playToken += 1;
    setState(() {
      _isPlaying = false;
    });

    final tts = ref.read(ttsServiceProvider);
    await tts.stop();
    if (announce) {
      await tts.speak('Paused. Tap middle when you want to continue.');
    }
  }

  Future<void> _repeatCurrentSegment() async {
    final tts = ref.read(ttsServiceProvider);
    if (_segments.isEmpty) {
      await tts.speak('No lesson is loaded.');
      return;
    }

    final idx = (_segmentIndex >= _segments.length)
        ? _segments.length - 1
        : _segmentIndex;
    await tts.speakAndWait(_segments[idx]);
  }

  Future<void> _navigateToAdjacentTopic(int? targetTopicId) async {
    final tts = ref.read(ttsServiceProvider);
    if (targetTopicId == null) {
      await tts.speak('No more topics that side.');
      return;
    }

    await _pausePlayback(announce: false);
    if (!mounted) return;

    context.goNamed(
      'studentStudy',
      pathParameters: {'topicId': targetTopicId.toString()},
    );
  }

  Future<void> _startQuizRoute() async {
    final tts = ref.read(ttsServiceProvider);

    final lesson = _lesson;
    if (lesson == null) {
      await tts.speak('This topic has no lesson yet, so there are no questions now.');
      return;
    }

    if (_questionCount == 0) {
      await tts.speak('No questions are available for this lesson yet.');
      return;
    }

    await _pausePlayback(announce: false);
    if (!mounted) return;

    context.pushNamed(
      'studentQuiz',
      pathParameters: {'lessonId': lesson.id.toString()},
    );
  }

  void _handleStudySwipe(DragEndDetails details) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSwipeMs < _swipeCooldownMs) return;

    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < _minSwipeVelocity) return;

    _lastSwipeMs = now;
    if (velocity > 0) {
      _navigateToAdjacentTopic(_nextTopicId);
    } else {
      _navigateToAdjacentTopic(_previousTopicId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topicName = _topic?.name ?? 'Topic ${widget.topicId}';

    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          color: Color(0xFF1A56DB),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: _speakOrientation,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
                            color: const Color(0xFFDDEAFF),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  topicName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1A56DB),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value: _progressValue,
                                  minHeight: 8,
                                  backgroundColor: const Color(0xFFBFD4FF),
                                  color: const Color(0xFF1A56DB),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Progress ${(_progressValue * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Color(0xFF355CA8),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 5,
                        child: GestureDetector(
                          onTap: _togglePlayPause,
                          onLongPress: _repeatCurrentSegment,
                          onHorizontalDragEnd: _handleStudySwipe,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xFFEBF2FF),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isPlaying
                                      ? Icons.pause_circle_filled_rounded
                                      : Icons.play_circle_fill_rounded,
                                  size: 116,
                                  color: const Color(0xFF1A56DB),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  _isPlaying ? 'Playing' : 'Paused',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1A56DB),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Tap to play or pause. Swipe for next or previous topic. Long press to repeat.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: Color(0xFF355CA8),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: () => ref
                              .read(ttsServiceProvider)
                              .speak('When ready, double tap to start questions.'),
                          onDoubleTap: _startQuizRoute,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xFF1A56DB),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.quiz_rounded,
                                  color: Colors.white,
                                  size: 40,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Questions ($_questionCount)',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Double tap to start quiz',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
