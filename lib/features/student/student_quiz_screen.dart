import 'package:audioapp/shared/services/db/app_database.dart';
import 'package:audioapp/shared/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StudentQuizScreen extends ConsumerStatefulWidget {
  final String lessonId;

  const StudentQuizScreen({super.key, required this.lessonId});

  @override
  ConsumerState<StudentQuizScreen> createState() => _StudentQuizScreenState();
}

class _StudentQuizScreenState extends ConsumerState<StudentQuizScreen> {
  bool _isLoading = true;
  bool _isComplete = false;
  String? _error;

  List<Question> _questions = const [];
  int _questionIndex = 0;
  String? _selectedOption;
  bool _locked = false;
  int _score = 0;
  bool _mappingGuidancePlayed = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    ref.read(ttsServiceProvider).stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await ref.read(ttsInitProvider.future);

    final lessonInt = int.tryParse(widget.lessonId);
    if (lessonInt == null) {
      setState(() {
        _isLoading = false;
        _error = 'Invalid lesson id.';
      });
      return;
    }

    final db = ref.read(appDatabaseProvider);
    final tts = ref.read(ttsServiceProvider);

    try {
      final questions = await db.questionDao.getQuestionsByLessonId(lessonInt);
      if (!mounted) return;

      setState(() {
        _questions = questions;
        _isLoading = false;
      });

      if (questions.isEmpty) {
        await tts.speak('There are no questions in this lesson yet.');
        return;
      }

      await _announceCurrentQuestion();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load quiz questions.';
      });
      await tts.speak('Could not load quiz questions.');
    }
  }

  Question? get _currentQuestion {
    if (_questionIndex < 0 || _questionIndex >= _questions.length) return null;
    return _questions[_questionIndex];
  }

  String? _optionText(Question q, String option) {
    switch (option) {
      case 'A':
        return q.optionA;
      case 'B':
        return q.optionB;
      case 'C':
        return q.optionC;
      case 'D':
        return q.optionD;
      default:
        return null;
    }
  }

  Future<void> _announceCurrentQuestion() async {
    final tts = ref.read(ttsServiceProvider);
    final q = _currentQuestion;
    if (q == null) return;

    final dText = q.optionD == null
        ? 'There is no option D in this question.'
        : 'Long press bottom for option D.';

    await tts.speakAndWait(
      'Question ${_questionIndex + 1} of ${_questions.length}. ${q.questionText}',
    );

    if (!_mappingGuidancePlayed) {
      await tts.speakAndWait(
        'Fixed mapping: top A, middle B, bottom C. $dText Double tap to confirm.',
      );
      _mappingGuidancePlayed = true;
      return;
    }

    await tts.speak('Choose your answer, then double tap to confirm.');
  }

  Future<void> _selectOption(String option) async {
    if (_locked || _isComplete) return;

    final q = _currentQuestion;
    final tts = ref.read(ttsServiceProvider);
    if (q == null) return;

    final selectedText = _optionText(q, option);
    if (selectedText == null || selectedText.trim().isEmpty) {
      await tts.speak('That option is not available for this question.');
      return;
    }

    setState(() {
      _selectedOption = option;
    });

    await tts.speak('Option $option selected.');
  }

  Future<void> _confirmSelection() async {
    if (_locked) return;

    final q = _currentQuestion;
    final selected = _selectedOption;
    final tts = ref.read(ttsServiceProvider);

    if (_isComplete) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    if (q == null) return;
    if (selected == null) {
      await tts.speak('Please select an option first.');
      return;
    }

    setState(() {
      _locked = true;
    });

    final correct = q.correctOption.toUpperCase() == selected;
    if (correct) {
      _score += 1;
      await tts.speakAndWait('Good job. That is correct.');
    } else {
      final explanation = q.explanation.trim();
      if (explanation.isEmpty) {
        await tts.speakAndWait('Not quite. Let us continue.');
      } else {
        await tts.speakAndWait('Not quite. ${q.explanation}');
      }
    }

    final hasNext = _questionIndex < _questions.length - 1;
    if (!hasNext) {
      setState(() {
        _isComplete = true;
        _locked = false;
      });
      await tts.speak(
        'Quiz complete. Your score is $_score out of ${_questions.length}. Double tap to return to your lesson.',
      );
      return;
    }

    setState(() {
      _questionIndex += 1;
      _selectedOption = null;
      _locked = false;
    });

    await _announceCurrentQuestion();
  }

  Widget _buildZone({
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool selected = false,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: color,
            border: Border.all(
              color: selected ? Colors.amberAccent : Colors.transparent,
              width: 4,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _currentQuestion;

    return GestureDetector(
      onDoubleTap: _confirmSelection,
      child: Scaffold(
        backgroundColor: const Color(0xFFEBF2FF),
        appBar: AppBar(
          backgroundColor: const Color(0xFFEBF2FF),
          title: const Text('Quiz'),
        ),
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
                  : _questions.isEmpty
                      ? const Center(
                          child: Text(
                            'No questions available yet',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A56DB),
                            ),
                          ),
                        )
                      : _isComplete
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.verified_rounded,
                                      color: Color(0xFF1A56DB),
                                      size: 72,
                                    ),
                                    const SizedBox(height: 14),
                                    Text(
                                      'Score: $_score / ${_questions.length}',
                                      style: const TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF1A56DB),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    const Text(
                                      'Double tap anywhere to return to lesson.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF355CA8),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 18),
                                    ElevatedButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      child: const Text('Return to lesson'),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                Container(
                                  width: double.infinity,
                                  color: const Color(0xFFDDEAFF),
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Question ${_questionIndex + 1} of ${_questions.length}',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF1A56DB),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        q?.questionText ?? '',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF1A56DB),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                _buildZone(
                                  title: 'A',
                                  subtitle: q?.optionA ?? '',
                                  color: const Color(0xFF1A56DB),
                                  selected: _selectedOption == 'A',
                                  onTap: () => _selectOption('A'),
                                ),
                                _buildZone(
                                  title: 'B',
                                  subtitle: q?.optionB ?? '',
                                  color: const Color(0xFF355CA8),
                                  selected: _selectedOption == 'B',
                                  onTap: () => _selectOption('B'),
                                ),
                                _buildZone(
                                  title: 'C',
                                  subtitle: q?.optionC ?? '',
                                  color: const Color(0xFF234A8F),
                                  selected: _selectedOption == 'C' || _selectedOption == 'D',
                                  onTap: () => _selectOption('C'),
                                  onLongPress: () => _selectOption('D'),
                                ),
                                Container(
                                  width: double.infinity,
                                  color: const Color(0xFFEBF2FF),
                                  padding: const EdgeInsets.all(12),
                                  child: const Text(
                                    'Double tap anywhere to confirm selection.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Color(0xFF355CA8),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
        ),
      ),
    );
  }
}
