// ignore_for_file: type=lint
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

// ============================================================
// TABLE DEFINITIONS
// ============================================================

/// Teachers who create content and manage students.
@DataClassName('Teacher')
class TeachersTable extends Table {
  @override
  String get tableName => 'teachers';

  late final id = integer().autoIncrement()();
  late final name = text()();
  late final pinHash = text()();
  late final subjectName = text()();
  late final createdAt = integer()();
}

/// Students using the learning platform (one per device).
@DataClassName('Student')
class StudentsTable extends Table {
  @override
  String get tableName => 'students';

  late final id = integer().autoIncrement()();
  late final name = text()();

  /// Null until the student sets their own PIN.
  late final pinHash = text().nullable()();

  /// Whether the student has created their PIN yet.
  late final pinCreated = boolean().withDefault(const Constant(false))();

  late final createdAt = integer()();
}

/// Subjects created by teachers (one teacher, many subjects).
@DataClassName('Subject')
class SubjectsTable extends Table {
  @override
  String get tableName => 'subjects';

  late final id = integer().autoIncrement()();
  late final teacherId = integer().references(TeachersTable, #id)();
  late final name = text()();
  late final createdAt = integer()();
}

/// Topics within a subject, ordered by [orderIndex].
@DataClassName('Topic')
class TopicsTable extends Table {
  @override
  String get tableName => 'topics';

  late final id = integer().autoIncrement()();
  late final subjectId = integer().references(SubjectsTable, #id)();
  late final name = text()();
  late final orderIndex = integer().withDefault(const Constant(0))();
  late final createdAt = integer()();
}

/// Audio lessons belonging to a topic.
@DataClassName('Lesson')
class LessonsTable extends Table {
  @override
  String get tableName => 'lessons';

  late final id = integer().autoIncrement()();
  late final topicId = integer().references(TopicsTable, #id)();
  late final rawText = text()();

  /// Local file-system path to a cached audio file; null when not yet generated.
  late final audioFilePath = text().nullable()();

  late final createdAt = integer()();
}

/// Quiz questions attached to a lesson, either teacher-authored or AI-generated.
@DataClassName('Question')
class QuestionsTable extends Table {
  @override
  String get tableName => 'questions';

  late final id = integer().autoIncrement()();
  late final lessonId = integer().references(LessonsTable, #id)();
  late final questionText = text()();
  late final optionA = text()();
  late final optionB = text()();
  late final optionC = text()();

  /// Optional fourth choice; absent when only A–C are used.
  late final optionD = text().nullable()();

  /// Stores 'A', 'B', 'C', or 'D'.
  late final correctOption = text()();
  late final explanation = text()();
  late final positionInLesson = integer().withDefault(const Constant(0))();

  /// Either 'teacher' or 'ai'.
  late final source = text()();
}

/// Tracks each student's playback position and completion state per lesson.
/// The pair (lessonId, studentId) is unique, enabling clean upserts.
@DataClassName('Progress')
class ProgressTable extends Table {
  @override
  String get tableName => 'progress';

  late final id = integer().autoIncrement()();
  late final lessonId = integer().references(LessonsTable, #id)();
  late final studentId = integer().references(StudentsTable, #id)();
  late final positionSeconds = integer().withDefault(const Constant(0))();
  late final completed = boolean().withDefault(const Constant(false))();
  late final lastAccessed = integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {lessonId, studentId},
      ];
}

/// Records each student's answer attempt on a question.
@DataClassName('QuizResult')
class QuizResultsTable extends Table {
  @override
  String get tableName => 'quiz_results';

  late final id = integer().autoIncrement()();
  late final questionId = integer().references(QuestionsTable, #id)();
  late final studentId = integer().references(StudentsTable, #id)();
  late final wasCorrect = boolean()();
  late final attemptedAt = integer()();
}

// ============================================================
// DATABASE
// ============================================================

@DriftDatabase(
  tables: [
    TeachersTable,
    StudentsTable,
    SubjectsTable,
    TopicsTable,
    LessonsTable,
    QuestionsTable,
    ProgressTable,
    QuizResultsTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'audioapp'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
      );

  // Expose DAOs as lazy singletons so callers never need to instantiate them.
  late final teacherDao = TeacherDao(this);
  late final studentDao = StudentDao(this);
  late final subjectDao = SubjectDao(this);
  late final topicDao = TopicDao(this);
  late final lessonDao = LessonDao(this);
  late final questionDao = QuestionDao(this);
  late final progressDao = ProgressDao(this);
  late final quizResultDao = QuizResultDao(this);
}

// ============================================================
// DAOs
// ============================================================

// ------------------------------------------------------------------
// TeacherDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [TeachersTable])
class TeacherDao extends DatabaseAccessor<AppDatabase> with _$TeacherDaoMixin {
  TeacherDao(super.db);

  /// Insert a new teacher and return the generated row id.
  Future<int> insertTeacher(TeachersTableCompanion teacher) =>
      into(teachersTable).insert(teacher);

  /// Retrieve a single teacher by primary key; returns null if absent.
  Future<Teacher?> getTeacherById(int id) =>
      (select(teachersTable)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Return every teacher row ordered by creation time (oldest first).
  Future<List<Teacher>> getAllTeachers() =>
      (select(teachersTable)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  /// Find a teacher by their subject name (case-insensitive exact match).
  Future<Teacher?> findTeacherBySubjectName(String subjectName) =>
      (select(teachersTable)
            ..where(
              (t) => t.subjectName.lower().equals(subjectName.toLowerCase()),
            ))
          .getSingleOrNull();

  /// Overwrite the hashed PIN for an existing teacher.
  Future<bool> updateTeacherPin(int id, String newPinHash) async {
    final rowsAffected = await (update(teachersTable)
          ..where((t) => t.id.equals(id)))
        .write(TeachersTableCompanion(pinHash: Value(newPinHash)));
    return rowsAffected > 0;
  }
}

// ------------------------------------------------------------------
// StudentDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [StudentsTable])
class StudentDao extends DatabaseAccessor<AppDatabase> with _$StudentDaoMixin {
  StudentDao(super.db);

  /// Insert a new student record and return the generated row id.
  Future<int> insertStudent(StudentsTableCompanion student) =>
      into(studentsTable).insert(student);

  /// Return the single student stored on this device (first row).
  /// Returns null when no student has been created yet.
  Future<Student?> getStudent() =>
      (select(studentsTable)..limit(1)).getSingleOrNull();

    /// Retrieve a student by id.
    Future<Student?> getStudentById(int id) =>
      (select(studentsTable)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Update the hashed PIN for the given student.
  Future<bool> updateStudentPinHash(int id, String pinHash) async {
    final rowsAffected = await (update(studentsTable)
          ..where((t) => t.id.equals(id)))
        .write(StudentsTableCompanion(pinHash: Value(pinHash)));
    return rowsAffected > 0;
  }

  /// Mark the student's PIN-creation flag as true.
  Future<bool> markPinAsCreated(int id) async {
    final rowsAffected = await (update(studentsTable)
          ..where((t) => t.id.equals(id)))
        .write(const StudentsTableCompanion(pinCreated: Value(true)));
    return rowsAffected > 0;
  }
}

// ------------------------------------------------------------------
// SubjectDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [SubjectsTable])
class SubjectDao extends DatabaseAccessor<AppDatabase> with _$SubjectDaoMixin {
  SubjectDao(super.db);

  /// Insert a new subject and return the generated row id.
  Future<int> insertSubject(SubjectsTableCompanion subject) =>
      into(subjectsTable).insert(subject);

  /// Return all subjects belonging to [teacherId], ordered alphabetically.
  Future<List<Subject>> getSubjectsByTeacherId(int teacherId) =>
      (select(subjectsTable)
            ..where((t) => t.teacherId.equals(teacherId))
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .get();

  /// Delete the subject with the given [id] and return the number of rows deleted.
  Future<int> deleteSubject(int id) =>
      (delete(subjectsTable)..where((t) => t.id.equals(id))).go();
}

// ------------------------------------------------------------------
// TopicDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [TopicsTable])
class TopicDao extends DatabaseAccessor<AppDatabase> with _$TopicDaoMixin {
  TopicDao(super.db);

  /// Insert a new topic and return the generated row id.
  Future<int> insertTopic(TopicsTableCompanion topic) =>
      into(topicsTable).insert(topic);

  /// Return all topics for [subjectId] sorted by [orderIndex].
  Future<List<Topic>> getTopicsBySubjectId(int subjectId) =>
      (select(topicsTable)
            ..where((t) => t.subjectId.equals(subjectId))
            ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
          .get();

  /// Update the ordering index of a single topic.
  Future<bool> updateTopicOrder(int id, int orderIndex) async {
    final rowsAffected = await (update(topicsTable)
          ..where((t) => t.id.equals(id)))
        .write(TopicsTableCompanion(orderIndex: Value(orderIndex)));
    return rowsAffected > 0;
  }

  /// Delete the topic with the given [id] and return the number of rows deleted.
  Future<int> deleteTopic(int id) =>
      (delete(topicsTable)..where((t) => t.id.equals(id))).go();
}

// ------------------------------------------------------------------
// LessonDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [LessonsTable])
class LessonDao extends DatabaseAccessor<AppDatabase> with _$LessonDaoMixin {
  LessonDao(super.db);

  /// Insert a new lesson and return the generated row id.
  Future<int> insertLesson(LessonsTableCompanion lesson) =>
      into(lessonsTable).insert(lesson);

  /// Return all lessons belonging to [topicId], in insertion order.
  Future<List<Lesson>> getLessonsByTopicId(int topicId) =>
      (select(lessonsTable)..where((t) => t.topicId.equals(topicId))).get();

  /// Persist the local file-system [path] for the cached audio of a lesson.
  Future<bool> updateAudioFilePath(int id, String path) async {
    final rowsAffected = await (update(lessonsTable)
          ..where((t) => t.id.equals(id)))
        .write(LessonsTableCompanion(audioFilePath: Value(path)));
    return rowsAffected > 0;
  }
}

// ------------------------------------------------------------------
// QuestionDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [QuestionsTable])
class QuestionDao extends DatabaseAccessor<AppDatabase>
    with _$QuestionDaoMixin {
  QuestionDao(super.db);

  /// Insert a new question and return the generated row id.
  Future<int> insertQuestion(QuestionsTableCompanion question) =>
      into(questionsTable).insert(question);

  /// Return all questions for [lessonId] in their defined lesson order.
  Future<List<Question>> getQuestionsByLessonId(int lessonId) =>
      (select(questionsTable)
            ..where((t) => t.lessonId.equals(lessonId))
            ..orderBy([(t) => OrderingTerm.asc(t.positionInLesson)]))
          .get();

  /// Overwrite editable fields of an existing question.
  Future<bool> updateQuestion(
    int id,
    QuestionsTableCompanion updatedFields,
  ) async {
    final rowsAffected = await (update(questionsTable)
          ..where((t) => t.id.equals(id)))
        .write(updatedFields);
    return rowsAffected > 0;
  }

  /// Delete the question with the given [id] and return the number of rows deleted.
  Future<int> deleteQuestion(int id) =>
      (delete(questionsTable)..where((t) => t.id.equals(id))).go();
}

// ------------------------------------------------------------------
// ProgressDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [ProgressTable])
class ProgressDao extends DatabaseAccessor<AppDatabase>
    with _$ProgressDaoMixin {
  ProgressDao(super.db);

  /// Insert or update the progress record for a (lesson, student) pair.
  ///
  /// Because [ProgressTable] declares a unique key on (lessonId, studentId),
  /// a conflict on that pair will update all remaining columns in-place.
  Future<void> upsertProgress(ProgressTableCompanion progress) =>
      into(progressTable).insertOnConflictUpdate(progress);

  /// Retrieve the progress record for a specific (lesson, student) pair.
  /// Returns null when the student has not started the lesson yet.
  Future<Progress?> getProgress(int lessonId, int studentId) =>
      (select(progressTable)
            ..where(
              (t) =>
                  t.lessonId.equals(lessonId) & t.studentId.equals(studentId),
            ))
          .getSingleOrNull();
}

// ------------------------------------------------------------------
// QuizResultDao
// ------------------------------------------------------------------

@DriftAccessor(tables: [QuizResultsTable])
class QuizResultDao extends DatabaseAccessor<AppDatabase>
    with _$QuizResultDaoMixin {
  QuizResultDao(super.db);

  /// Record a student's answer attempt and return the generated row id.
  Future<int> insertQuizResult(QuizResultsTableCompanion result) =>
      into(quizResultsTable).insert(result);

  /// Return every quiz result for [studentId], most recent first.
  Future<List<QuizResult>> getResultsByStudentId(int studentId) =>
      (select(quizResultsTable)
            ..where((t) => t.studentId.equals(studentId))
            ..orderBy([(t) => OrderingTerm.desc(t.attemptedAt)]))
          .get();
}
