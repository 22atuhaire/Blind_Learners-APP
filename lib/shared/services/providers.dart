import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/app_database.dart';
import 'tts_service.dart';
import 'stt_service.dart';
import 'pin_service.dart';
import 'file_extraction_service.dart';
import 'ai_question_service.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Database
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the single, long-lived [AppDatabase] instance for the app.
///
/// Marked [keepAlive] by using a plain top-level [Provider] (never disposed by
/// Riverpod's auto-dispose mechanism).  All DAOs are accessed through the
/// instance exposed here — never construct [AppDatabase] directly.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => AppDatabase(),
  name: 'appDatabaseProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// Text-to-Speech
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the global [TtsService] instance.
///
/// The service is created once and reused for the lifetime of the app.
/// Consumers should await [ttsInitProvider] before calling any speak methods
/// to ensure the engine is fully configured.
final ttsServiceProvider = Provider<TtsService>(
  (ref) => TtsService(),
  name: 'ttsServiceProvider',
);

/// Initialises the [TtsService] and exposes the result as a [FutureProvider].
///
/// Watch this provider (or use `ref.read(ttsInitProvider.future)`) at app
/// start-up to block speech calls until the TTS engine is ready:
///
/// ```audioapp/lib/shared/services/providers.dart#L1-1
/// ref.watch(ttsInitProvider).when(
///   data: (_)    => MyWidget(),
///   loading: ()  => const SplashScreen(),
///   error: (e,_) => ErrorScreen(message: e.toString()),
/// );
/// ```
final ttsInitProvider = FutureProvider<void>(
  (ref) async {
    final tts = ref.watch(ttsServiceProvider);
    await tts.initialize();
  },
  name: 'ttsInitProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// Speech-to-Text
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the global [SttService] instance.
///
/// The service is a clean abstraction over the STT back-end.  In Phase 1 it
/// uses an internal [StreamController] so the full interface is available
/// without an external package dependency.  When the real `speech_to_text`
/// package is added in Phase 2, only [SttService] internals change — every
/// consumer of this provider stays untouched.
///
/// Call [SttService.initialize] before invoking [SttService.startListening].
/// A convenience [FutureProvider] can be added here (mirroring [ttsInitProvider])
/// once real STT initialisation becomes meaningful.
final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(),
  name: 'sttServiceProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// PIN Service
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the global [PinService] instance for hashing and verifying PINs.
///
/// Consumers must call [PinService.isValidPin] before [PinService.hashPin] to
/// ensure only well-formed 4-digit PINs are ever persisted.
final pinServiceProvider = Provider<PinService>(
  (ref) => PinService(),
  name: 'pinServiceProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// File Extraction Service
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the global [FileExtractionService] instance.
///
/// Supports `.pdf` (via `pdfx`) and `.docx` (via `archive` + `xml`) formats.
/// Always returns plain text — never throws to the caller.
final fileExtractionServiceProvider = Provider<FileExtractionService>(
  (ref) => FileExtractionService(),
  name: 'fileExtractionServiceProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// AI Question Service
// ──────────────────────────────────────────────────────────────────────────────

/// Provides the global [AiQuestionService] instance.
///
/// Question generation is fully offline and deterministic — the same lesson
/// text always produces the same questions in the same order.
final aiQuestionServiceProvider = Provider<AiQuestionService>(
  (ref) => AiQuestionService(),
  name: 'aiQuestionServiceProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// Current Teacher (session state)
// ──────────────────────────────────────────────────────────────────────────────

/// Holds the [Teacher] row for the currently logged-in teacher.
///
/// Set to a non-null value on successful PIN login; reset to `null` on logout.
/// All teacher-scoped providers watch this to re-evaluate automatically when
/// the active teacher changes.
///
/// Example:
/// ```
/// ref.read(currentTeacherProvider.notifier).state = authenticatedTeacher;
/// ```
final currentTeacherProvider = StateProvider<Teacher?>(
  (ref) => null,
  name: 'currentTeacherProvider',
);

// ──────────────────────────────────────────────────────────────────────────────
// Subjects for the current teacher
// ──────────────────────────────────────────────────────────────────────────────

/// Reactively fetches the list of [Subject] rows belonging to the currently
/// logged-in teacher.
///
/// Returns an empty list when no teacher is logged in.  Automatically
/// invalidates whenever [currentTeacherProvider] changes (e.g. after login or
/// logout).
final teacherSubjectsProvider =
    FutureProvider.autoDispose<List<Subject>>((ref) async {
  final teacher = ref.watch(currentTeacherProvider);
  if (teacher == null) return [];
  final db = ref.watch(appDatabaseProvider);
  return db.subjectDao.getSubjectsByTeacherId(teacher.id);
});

// ──────────────────────────────────────────────────────────────────────────────
// Topics for a subject  (family by subjectId)
// ──────────────────────────────────────────────────────────────────────────────

/// Fetches all [Topic] rows for [subjectId], ordered by [Topic.orderIndex].
///
/// Automatically disposed when the last listener unsubscribes.  Re-fetches
/// whenever the provider is rebuilt (e.g. after a topic is added or reordered).
///
/// Usage:
/// ```
/// ref.watch(subjectTopicsProvider(subject.id))
/// ```
final subjectTopicsProvider =
    FutureProvider.autoDispose.family<List<Topic>, int>(
  (ref, subjectId) async {
    final db = ref.watch(appDatabaseProvider);
    return db.topicDao.getTopicsBySubjectId(subjectId);
  },
);

// ──────────────────────────────────────────────────────────────────────────────
// Lesson for a topic  (family by topicId)
// ──────────────────────────────────────────────────────────────────────────────

/// Fetches the first [Lesson] row attached to [topicId], or `null` when the
/// topic has no lesson yet.
///
/// Each topic is designed to hold exactly one lesson in Phase 1/2; the `.first`
/// convention will be revisited if multi-lesson topics are introduced later.
///
/// Usage:
/// ```
/// ref.watch(topicLessonProvider(topic.id))
/// ```
final topicLessonProvider = FutureProvider.autoDispose.family<Lesson?, int>(
  (ref, topicId) async {
    final db = ref.watch(appDatabaseProvider);
    final lessons = await db.lessonDao.getLessonsByTopicId(topicId);
    return lessons.isEmpty ? null : lessons.first;
  },
);

// ──────────────────────────────────────────────────────────────────────────────
// Questions for a lesson  (family by lessonId)
// ──────────────────────────────────────────────────────────────────────────────

/// Fetches all [Question] rows for [lessonId], ordered by
/// [Question.positionInLesson].
///
/// Returns an empty list when the lesson has no questions yet (e.g. before the
/// teacher runs AI generation or manually adds questions).
///
/// Usage:
/// ```
/// ref.watch(lessonQuestionsProvider(lesson.id))
/// ```
final lessonQuestionsProvider =
    FutureProvider.autoDispose.family<List<Question>, int>(
  (ref, lessonId) async {
    final db = ref.watch(appDatabaseProvider);
    return db.questionDao.getQuestionsByLessonId(lessonId);
  },
);
