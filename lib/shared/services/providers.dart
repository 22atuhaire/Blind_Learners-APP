import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/app_database.dart';
import 'tts_service.dart';
import 'stt_service.dart';
import 'device_mode_service.dart';
import 'pin_service.dart';
import 'file_extraction_service.dart';
import 'ai_question_service.dart';
import 'backend_api_service.dart';
import 'backend_link_service.dart';
import 'progress_summary_service.dart';

// Database
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => AppDatabase(),
  name: 'appDatabaseProvider',
);

// Text-to-Speech
final ttsServiceProvider = Provider<TtsService>(
  (ref) => TtsService(),
  name: 'ttsServiceProvider',
);

/// Initialises the [TtsService]. Watch (or read .future) at start-up to block
/// speech calls until the engine is ready.
final ttsInitProvider = FutureProvider<void>(
  (ref) async {
    final tts = ref.watch(ttsServiceProvider);
    await tts.initialize();
  },
  name: 'ttsInitProvider',
);

// Speech-to-Text
final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(),
  name: 'sttServiceProvider',
);

// Device Mode (personal vs shared phone)
/// Remembers whether this install is on a student's personal phone (no PIN) or
/// a shared school phone (PIN kept). Read silently on every launch.
final deviceModeServiceProvider = Provider<DeviceModeService>(
  (ref) => DeviceModeService(),
  name: 'deviceModeServiceProvider',
);

// PIN Service
final pinServiceProvider = Provider<PinService>(
  (ref) => PinService(),
  name: 'pinServiceProvider',
);

// File Extraction Service
final fileExtractionServiceProvider = Provider<FileExtractionService>(
  (ref) => FileExtractionService(),
  name: 'fileExtractionServiceProvider',
);

// AI Question Service (offline fallback generator)
final aiQuestionServiceProvider = Provider<AiQuestionService>(
  (ref) => AiQuestionService(),
  name: 'aiQuestionServiceProvider',
);

// Backend API Service
final backendApiServiceProvider = Provider<BackendApiService>(
  (ref) => BackendApiService(),
  name: 'backendApiServiceProvider',
);

// Backend account-linking bridge
final backendLinkServiceProvider = Provider<BackendLinkService>(
  (ref) => BackendLinkService(ref.watch(backendApiServiceProvider)),
  name: 'backendLinkServiceProvider',
);

// Progress Summary Service
final progressSummaryServiceProvider = Provider<ProgressSummaryService>(
  (ref) => ProgressSummaryService(ref.watch(appDatabaseProvider)),
  name: 'progressSummaryServiceProvider',
);

// Current Teacher (session state)
/// Holds the [Teacher] row for the currently logged-in teacher; null on logout.
final currentTeacherProvider = StateProvider<Teacher?>(
  (ref) => null,
  name: 'currentTeacherProvider',
);

// Subjects for the current teacher
final teacherSubjectsProvider =
    FutureProvider.autoDispose<List<Subject>>((ref) async {
  final teacher = ref.watch(currentTeacherProvider);
  if (teacher == null) return [];
  final db = ref.watch(appDatabaseProvider);
  return db.subjectDao.getSubjectsByTeacherId(teacher.id);
});

/// All subjects in the database, ordered alphabetically (student-facing list).
final allSubjectsProvider =
    FutureProvider.autoDispose<List<Subject>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  return db.subjectDao.getAllSubjects();
});

// Topics for a subject (family by subjectId)
final subjectTopicsProvider =
    FutureProvider.autoDispose.family<List<Topic>, int>(
  (ref, subjectId) async {
    final db = ref.watch(appDatabaseProvider);
    return db.topicDao.getTopicsBySubjectId(subjectId);
  },
);

// Lesson for a topic (family by topicId)
final topicLessonProvider = FutureProvider.autoDispose.family<Lesson?, int>(
  (ref, topicId) async {
    final db = ref.watch(appDatabaseProvider);
    final lessons = await db.lessonDao.getLessonsByTopicId(topicId);
    return lessons.isEmpty ? null : lessons.first;
  },
);

// Questions for a lesson (family by lessonId)
final lessonQuestionsProvider =
    FutureProvider.autoDispose.family<List<Question>, int>(
  (ref, lessonId) async {
    final db = ref.watch(appDatabaseProvider);
    return db.questionDao.getQuestionsByLessonId(lessonId);
  },
);
