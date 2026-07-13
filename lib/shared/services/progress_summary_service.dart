import 'db/app_database.dart';

/// Per-subject slice of a student's progress.
class SubjectProgress {
  const SubjectProgress({
    required this.subjectName,
    required this.totalLessons,
    required this.completedLessons,
    required this.quizCorrect,
    required this.quizAnswered,
  });

  final String subjectName;
  final int totalLessons;
  final int completedLessons;
  final int quizCorrect;
  final int quizAnswered;

  /// 0–100. A subject with no lessons reports 0 (nothing to do yet).
  double get completionPercent =>
      totalLessons == 0 ? 0 : (completedLessons / totalLessons) * 100;

  /// 0–100, or null when the student hasn't answered any quiz here yet
  /// (so callers can say "no quizzes taken" instead of "0 percent").
  double? get quizAccuracyPercent =>
      quizAnswered == 0 ? null : (quizCorrect / quizAnswered) * 100;
}

/// A complete, ready-to-speak snapshot of one student's learning progress:
/// per-subject and overall lesson completion, quiz accuracy, and a simple
/// day-streak used for light encouragement.
class ProgressSummary {
  const ProgressSummary({
    required this.subjects,
    required this.totalLessons,
    required this.completedLessons,
    required this.quizCorrect,
    required this.quizAnswered,
    required this.studyStreakDays,
  });

  final List<SubjectProgress> subjects;
  final int totalLessons;
  final int completedLessons;
  final int quizCorrect;
  final int quizAnswered;

  /// Consecutive calendar days (ending today) on which the student did
  /// something — listened to a lesson or answered a quiz.
  final int studyStreakDays;

  bool get hasAnyContent => totalLessons > 0;
  bool get hasStarted => completedLessons > 0 || quizAnswered > 0;

  double get overallCompletionPercent =>
      totalLessons == 0 ? 0 : (completedLessons / totalLessons) * 100;

  double? get overallQuizAccuracyPercent =>
      quizAnswered == 0 ? null : (quizCorrect / quizAnswered) * 100;

  /// The subject the student has completed the most of (by percentage, then
  /// by count), or null when nothing has been completed yet.
  SubjectProgress? get bestSubject {
    SubjectProgress? best;
    for (final s in subjects) {
      if (s.completedLessons == 0) continue;
      if (best == null ||
          s.completionPercent > best.completionPercent ||
          (s.completionPercent == best.completionPercent &&
              s.completedLessons > best.completedLessons)) {
        best = s;
      }
    }
    return best;
  }
}

/// Builds a [ProgressSummary] from the local Drift tables. Pure read — it never
/// writes — and is meant to be called on demand (when the student asks "how am
/// I doing"), so walking subjects → topics → lessons → questions in Dart is
/// perfectly fine for a per-device dataset.
class ProgressSummaryService {
  ProgressSummaryService(this._db);

  final AppDatabase _db;

  Future<ProgressSummary> buildForStudent(int studentId) async {
    final progressRows = await _db.progressDao.getProgressByStudentId(studentId);
    final completedLessonIds = progressRows
        .where((p) => p.completed)
        .map((p) => p.lessonId)
        .toSet();

    final quizResults = await _db.quizResultDao.getResultsByStudentId(studentId);

    // questionId → subject name, so quiz results (which only store questionId)
    // can be attributed to the right subject.
    final questionSubject = <int, String>{};

    final subjects = await _db.subjectDao.getAllSubjects();
    final subjectProgress = <String, _MutableSubject>{};

    for (final subject in subjects) {
      final bucket = subjectProgress.putIfAbsent(
        subject.name,
        () => _MutableSubject(subject.name),
      );

      final topics = await _db.topicDao.getTopicsBySubjectId(subject.id);
      for (final topic in topics) {
        final lessons = await _db.lessonDao.getLessonsByTopicId(topic.id);
        for (final lesson in lessons) {
          bucket.totalLessons++;
          if (completedLessonIds.contains(lesson.id)) {
            bucket.completedLessons++;
          }
          final questions =
              await _db.questionDao.getQuestionsByLessonId(lesson.id);
          for (final q in questions) {
            questionSubject[q.id] = subject.name;
          }
        }
      }
    }

    // Tally quiz accuracy per subject (and overall).
    var quizCorrect = 0;
    var quizAnswered = 0;
    for (final r in quizResults) {
      quizAnswered++;
      if (r.wasCorrect) quizCorrect++;
      final name = questionSubject[r.questionId];
      if (name != null) {
        final bucket = subjectProgress[name];
        if (bucket != null) {
          bucket.quizAnswered++;
          if (r.wasCorrect) bucket.quizCorrect++;
        }
      }
    }

    final totalLessons =
        subjectProgress.values.fold<int>(0, (s, b) => s + b.totalLessons);
    final completedLessons =
        subjectProgress.values.fold<int>(0, (s, b) => s + b.completedLessons);

    final streak = _computeStreak(progressRows, quizResults);

    final list = subjectProgress.values
        .map((b) => SubjectProgress(
              subjectName: b.subjectName,
              totalLessons: b.totalLessons,
              completedLessons: b.completedLessons,
              quizCorrect: b.quizCorrect,
              quizAnswered: b.quizAnswered,
            ))
        .where((s) => s.totalLessons > 0)
        .toList()
      ..sort((a, b) => a.subjectName
          .toLowerCase()
          .compareTo(b.subjectName.toLowerCase()));

    return ProgressSummary(
      subjects: list,
      totalLessons: totalLessons,
      completedLessons: completedLessons,
      quizCorrect: quizCorrect,
      quizAnswered: quizAnswered,
      studyStreakDays: streak,
    );
  }

  /// Counts consecutive days (ending today) with any activity. Used only for a
  /// gentle "you've studied N days in a row" nudge — never to gate anything.
  int _computeStreak(List<Progress> progress, List<QuizResult> quiz) {
    final days = <DateTime>{};
    void add(int epochMs) {
      final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
      days.add(DateTime(d.year, d.month, d.day));
    }

    for (final p in progress) {
      add(p.lastAccessed);
    }
    for (final q in quiz) {
      add(q.attemptedAt);
    }
    if (days.isEmpty) return 0;

    final now = DateTime.now();
    var cursor = DateTime(now.year, now.month, now.day);
    // Allow the streak to "start" yesterday if the student hasn't studied yet
    // today — they shouldn't lose their streak just for opening it in the
    // morning before studying.
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }

    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }
}

class _MutableSubject {
  _MutableSubject(this.subjectName);
  final String subjectName;
  int totalLessons = 0;
  int completedLessons = 0;
  int quizCorrect = 0;
  int quizAnswered = 0;
}

/// Turns a [ProgressSummary] into a single, natural spoken paragraph for a
/// visually impaired student: per-subject lesson completion, overall totals,
/// quiz accuracy, and a short, genuine encouragement. Kept free of any visual
/// vocabulary ("see", "below") so it stands on its own as audio.
String buildSpokenProgressSummary(ProgressSummary s) {
  if (!s.hasAnyContent) {
    return 'You have no lessons yet. When your teacher adds lessons, '
        'your progress will appear here.';
  }
  if (!s.hasStarted) {
    return 'You have ${s.totalLessons} '
        '${_lessonWord(s.totalLessons)} ready, but you have not finished any '
        'yet. Open a subject and listen to a lesson to begin. You can do it!';
  }

  final buffer = StringBuffer('Here is your progress. ');

  for (final subj in s.subjects) {
    if (subj.completedLessons == 0 && subj.quizAnswered == 0) continue;
    buffer.write('In ${subj.subjectName}, you have completed '
        '${subj.completedLessons} of ${subj.totalLessons} '
        '${_lessonWord(subj.totalLessons)}');
    final acc = subj.quizAccuracyPercent;
    if (acc != null) {
      buffer.write(', with a quiz score of ${acc.round()} percent');
    }
    buffer.write('. ');
  }

  buffer.write('Overall, you have completed ${s.completedLessons} of '
      '${s.totalLessons} ${_lessonWord(s.totalLessons)}, '
      'that is ${s.overallCompletionPercent.round()} percent. ');

  final overallAcc = s.overallQuizAccuracyPercent;
  if (overallAcc != null) {
    buffer.write('Your overall quiz score is ${overallAcc.round()} percent. ');
  }

  buffer.write(_encouragement(s));
  return buffer.toString();
}

String _lessonWord(int n) => n == 1 ? 'lesson' : 'lessons';

/// Short, honest encouragement — tied to real signals (streak, accuracy,
/// completion) so it never feels hollow.
String _encouragement(ProgressSummary s) {
  if (s.studyStreakDays >= 3) {
    return 'Amazing! You have studied ${s.studyStreakDays} days in a row. '
        'Keep that streak going!';
  }
  if (s.studyStreakDays == 2) {
    return 'Two days in a row, well done! Come back tomorrow to keep it up.';
  }

  final acc = s.overallQuizAccuracyPercent;
  if (acc != null && acc >= 80) {
    return 'Your quiz scores are excellent. Great work!';
  }

  final best = s.bestSubject;
  if (best != null) {
    return 'You are doing well in ${best.subjectName}. Keep going!';
  }
  return 'Great progress. Keep listening and learning!';
}
