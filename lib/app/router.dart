import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/splash_screen.dart';
import '../features/auth/role_selection_screen.dart';
import '../features/teacher/teacher_pin_screen.dart';
import '../features/teacher/teacher_dashboard_screen.dart';
import '../features/teacher/teacher_subject_screen.dart';
import '../features/teacher/teacher_upload_screen.dart';
import '../features/teacher/teacher_questions_screen.dart';
import '../features/student/student_pin_screen.dart';
import '../features/student/student_home_screen.dart';
import '../features/student/student_study_screen.dart';
import '../features/student/student_quiz_screen.dart';

final routerProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/role',
    debugLogDiagnostics: false,
    routes: [
      GoRoute(
        name: 'splash',
        path: '/',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        name: 'roleSelection',
        path: '/role',
        builder: (context, state) => const RoleSelectionScreen(),
      ),

      // ── Teacher routes ────────────────────────────────────────────────────
      GoRoute(
        name: 'teacherPin',
        path: '/teacher/pin',
        builder: (context, state) => const TeacherPinScreen(),
      ),
      GoRoute(
        name: 'teacherDashboard',
        path: '/teacher/dashboard',
        builder: (context, state) => const TeacherDashboardScreen(),
      ),
      GoRoute(
        name: 'teacherSubject',
        path: '/teacher/subject/:subjectId',
        builder: (context, state) {
          final subjectId = state.pathParameters['subjectId']!;
          return TeacherSubjectScreen(subjectId: subjectId);
        },
      ),
      GoRoute(
        name: 'teacherUpload',
        path: '/teacher/upload/:topicId',
        builder: (context, state) {
          final topicId = state.pathParameters['topicId']!;
          return TeacherUploadScreen(topicId: topicId);
        },
      ),
      GoRoute(
        name: 'teacherQuestions',
        path: '/teacher/questions/:lessonId',
        builder: (context, state) {
          final lessonId = state.pathParameters['lessonId']!;
          return TeacherQuestionsScreen(lessonId: lessonId);
        },
      ),

      // ── Student routes ────────────────────────────────────────────────────
      GoRoute(
        name: 'studentPin',
        path: '/student/pin',
        builder: (context, state) => const StudentPinScreen(),
      ),
      GoRoute(
        name: 'studentHome',
        path: '/student/home',
        builder: (context, state) => const StudentHomeScreen(),
      ),
      GoRoute(
        name: 'studentStudy',
        path: '/student/study/:topicId',
        builder: (context, state) {
          final topicId = state.pathParameters['topicId']!;
          return StudentStudyScreen(topicId: topicId);
        },
      ),
      GoRoute(
        name: 'studentQuiz',
        path: '/student/quiz/:lessonId',
        builder: (context, state) {
          final lessonId = state.pathParameters['lessonId']!;
          return StudentQuizScreen(lessonId: lessonId);
        },
      ),
    ],
  ),
  name: 'routerProvider',
);
