import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Default deployment of the VisioLearn backend.
///
/// Hosted on Render's free tier, which spins the instance down after ~15
/// minutes of inactivity; the first request after that can take 30-60 seconds.
/// Fire [BackendApiService.warmUp] early (e.g. on the role-selection screen)
/// so the instance is already awake by the time a student joins a class or
/// syncs lessons.
const String kDefaultBackendBaseUrl = 'https://visiolearn-backend.onrender.com';

class BackendApiException implements Exception {
  BackendApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'BackendApiException($statusCode): $message';
}

class BackendSession {
  const BackendSession({
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.email,
  });

  final String baseUrl;
  final String accessToken;
  final String refreshToken;
  final String email;
}

class BackendAuthTokens {
  const BackendAuthTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;
}

class RouteAuditEntry {
  const RouteAuditEntry({
    required this.route,
    required this.method,
    required this.statusCode,
    required this.outcome,
    required this.detail,
  });

  final String route;
  final String method;
  final int statusCode;
  final String outcome;
  final String detail;
}

class RouteAuditResult {
  const RouteAuditResult({
    required this.entries,
    required this.succeeded,
    required this.failed,
    required this.skipped,
  });

  final List<RouteAuditEntry> entries;
  final int succeeded;
  final int failed;
  final int skipped;
}

// ─────────────────────────────────────────────────────────────────────────────
// Linking / registration models
// ─────────────────────────────────────────────────────────────────────────────

/// Result of any of the three registration calls. Different roles populate
/// different optional fields — callers should check [role] before reading
/// role-specific fields such as [teacherCode] or [studentCode].
class BackendRegistrationResult {
  const BackendRegistrationResult({
    required this.userId,
    required this.email,
    required this.fullName,
    required this.role,
    this.classId,
    this.className,
    this.subjectId,
    this.subjectName,
    this.studentCode,
    this.teacherCode,
  });

  final String userId;
  final String email;
  final String fullName;
  final String role;
  final String? classId;
  final String? className;
  final String? subjectId;
  final String? subjectName;
  final String? studentCode;
  final String? teacherCode;

  static String? _str(dynamic v) =>
      (v == null) ? null : v.toString();

  factory BackendRegistrationResult.fromJson(Map<String, dynamic> json) {
    return BackendRegistrationResult(
      userId: json['user_id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      classId: _str(json['class_id']),
      className: _str(json['class_name']),
      subjectId: _str(json['subject_id']),
      subjectName: _str(json['subject_name']),
      studentCode: _str(json['student_code']),
      teacherCode: _str(json['teacher_code']),
    );
  }
}

/// A subject the current account teaches or belongs to (from `/auth/me`).
class BackendSubject {
  const BackendSubject({
    required this.id,
    required this.subjectName,
    required this.classId,
  });

  final String id;
  final String subjectName;
  final String? classId;

  factory BackendSubject.fromJson(Map<String, dynamic> json) => BackendSubject(
        id: json['id']?.toString() ?? '',
        subjectName: json['subject_name']?.toString() ?? '',
        classId: json['class_id']?.toString(),
      );
}

/// The authenticated account's own identity + class/subjects, from
/// `GET /api/v1/auth/me`. This is the single source of truth for restoring a
/// teacher (or student) on a new device — no more reconstructing identity from
/// whatever notes happen to exist.
class BackendMe {
  const BackendMe({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    this.classId,
    this.className,
    this.studentCode,
    this.teacherCode,
    this.subjects = const [],
  });

  final String id;
  final String? email;
  final String fullName;
  final String role;
  final String? classId;
  final String? className;
  final String? studentCode;
  final String? teacherCode;
  final List<BackendSubject> subjects;

  factory BackendMe.fromJson(Map<String, dynamic> json) {
    final rawSubjects = json['subjects'];
    return BackendMe(
      id: json['id']?.toString() ?? '',
      email: json['email']?.toString(),
      fullName: json['full_name']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      classId: json['class_id']?.toString(),
      className: json['class_name']?.toString(),
      studentCode: json['student_code']?.toString(),
      teacherCode: json['teacher_code']?.toString(),
      subjects: rawSubjects is List
          ? rawSubjects
              .whereType<Map<String, dynamic>>()
              .map(BackendSubject.fromJson)
              .toList()
          : const [],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Note / unit / artefact / progress models (cloud content pipeline)
// ─────────────────────────────────────────────────────────────────────────────

/// A lesson note as stored on the backend. [status] drives client polling:
/// `PENDING_PROCESSING` → still being summarised/quizzed by the AI pipeline,
/// `READY` → [BackendUnit]s and [BackendArtefact]s are available,
/// `ERROR` → processing failed; the local copy should remain the source of truth.
class BackendNote {
  const BackendNote({
    required this.id,
    required this.title,
    required this.subject,
    required this.gradeLevel,
    required this.status,
    required this.createdAt,
    this.description,
    this.durationSeconds,
    this.subjectId,
    this.classId,
  });

  final String id;
  final String title;
  final String subject;
  final String gradeLevel;
  final String status;
  final String createdAt;
  final String? description;
  final int? durationSeconds;

  /// Remote `ClassSubject` UUID this note is filed under (present in list
  /// responses) — used to recover a teacher's subject id on cloud login.
  final String? subjectId;

  /// Remote `Class` UUID this note belongs to.
  final String? classId;

  bool get isReady => status.toUpperCase() == 'READY';
  bool get isError => status.toUpperCase() == 'ERROR';
  bool get isProcessing => !isReady && !isError;

  factory BackendNote.fromJson(Map<String, dynamic> json) {
    final duration = json['duration_seconds'];
    return BackendNote(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      subject: json['subject']?.toString() ?? '',
      gradeLevel: json['grade_level']?.toString() ?? '',
      status: json['status']?.toString() ?? 'PENDING_PROCESSING',
      createdAt: json['created_at']?.toString() ?? '',
      description: json['description']?.toString(),
      durationSeconds:
          duration is int ? duration : int.tryParse('$duration'),
      subjectId: json['subject_id']?.toString(),
      classId: json['class_id']?.toString(),
    );
  }
}

/// One AI-generated content chunk ("learning unit") belonging to a note.
/// Units are ordered by [sequenceNumber] and form the cloud equivalent of the
/// app's locally-split lesson segments — they are what gets read aloud.
class BackendUnit {
  const BackendUnit({
    required this.id,
    required this.noteId,
    required this.sequenceNumber,
    required this.contentText,
  });

  final String id;
  final String noteId;
  final int sequenceNumber;
  final String contentText;

  factory BackendUnit.fromJson(Map<String, dynamic> json) {
    final seq = json['sequence_number'];
    return BackendUnit(
      id: json['id']?.toString() ?? '',
      noteId: json['note_id']?.toString() ?? '',
      sequenceNumber: seq is int ? seq : int.tryParse('$seq') ?? 0,
      contentText: json['content_text']?.toString() ?? '',
    );
  }
}

/// One answer choice for an MCQ artefact.
class BackendArtefactOption {
  const BackendArtefactOption({required this.text, required this.isCorrect});

  final String text;
  final bool isCorrect;

  factory BackendArtefactOption.fromJson(Map<String, dynamic> json) {
    return BackendArtefactOption(
      text: json['text']?.toString() ?? '',
      isCorrect: json['is_correct'] == true,
    );
  }
}

/// AI-generated quiz/summary artefact attached to a [BackendUnit].
/// Only `MCQ` artefacts are surfaced as quiz questions today — the same shape
/// the app's local [Question] rows use, so the gesture quiz UI can stay as-is.
class BackendArtefact {
  const BackendArtefact({
    required this.id,
    required this.unitId,
    required this.artefactType,
    required this.questionText,
    required this.options,
    required this.explanation,
  });

  final String id;
  final String unitId;
  final String artefactType;
  final String questionText;
  final List<BackendArtefactOption> options;
  final String explanation;

  bool get isMultipleChoice => artefactType.toUpperCase() == 'MCQ';

  factory BackendArtefact.fromJson(Map<String, dynamic> json) {
    final content = json['content'];
    final contentMap =
        content is Map<String, dynamic> ? content : <String, dynamic>{};
    final rawOptions = contentMap['options'];
    final options = <BackendArtefactOption>[];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is Map<String, dynamic>) {
          options.add(BackendArtefactOption.fromJson(o));
        }
      }
    }
    return BackendArtefact(
      id: json['id']?.toString() ?? '',
      unitId: json['unit_id']?.toString() ?? '',
      artefactType: json['artefact_type']?.toString() ?? '',
      questionText: contentMap['question_text']?.toString() ?? '',
      options: options,
      explanation: contentMap['explanation']?.toString() ?? '',
    );
  }
}

/// Server-side mirror of a student's playback progress for one note.
class BackendProgress {
  const BackendProgress({
    required this.id,
    required this.completed,
    required this.completionPercentage,
    required this.lastPositionSeconds,
  });

  final String id;
  final bool completed;
  final double completionPercentage;
  final int lastPositionSeconds;

  factory BackendProgress.fromJson(Map<String, dynamic> json) {
    final pct = json['completion_percentage'];
    final pos = json['last_position_seconds'];
    return BackendProgress(
      id: json['id']?.toString() ?? '',
      completed: json['completed'] == true,
      completionPercentage:
          pct is num ? pct.toDouble() : double.tryParse('$pct') ?? 0,
      lastPositionSeconds: pos is int ? pos : int.tryParse('$pos') ?? 0,
    );
  }
}

/// A turn-by-turn voice interaction session, mirroring how a sighted app might
/// log clicks — except every "click" here is a spoken command. Starting one
/// when a student begins a lesson lets the backend's analytics see the audio
/// app as a first-class voice client, not just a content viewer.
class BackendVoiceSession {
  const BackendVoiceSession({required this.sessionId});
  final String sessionId;

  factory BackendVoiceSession.fromJson(Map<String, dynamic> json) {
    return BackendVoiceSession(
      sessionId: json['session_id']?.toString() ?? '',
    );
  }
}

class BackendApiService {
  static const _kBaseUrl = 'backend_base_url';
  static const _kAccessToken = 'backend_access_token';
  static const _kRefreshToken = 'backend_refresh_token';
  static const _kEmail = 'backend_email';

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  Uri _uri(String baseUrl, String path, [Map<String, String>? query]) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  bool _isSuccess(int code) => code >= 200 && code < 300;

  String _extractDetail(dynamic data, [String fallback = 'Request failed']) {
    if (data is Map<String, dynamic>) {
      final detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      // FastAPI validation errors (422) carry a LIST of error objects, each
      // with a human-readable `msg`. Without this branch a mistyped class
      // code surfaced as a generic "request failed" instead of the server's
      // actual explanation ("Class code must be in format SC-XXXX…").
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map<String, dynamic>) {
          final msg = first['msg']?.toString() ?? '';
          if (msg.isNotEmpty) {
            return msg.replaceFirst(RegExp(r'^Value error,\s*'), '');
          }
        }
      }
      return fallback;
    }
    return fallback;
  }

  Future<(int statusCode, dynamic body)> _sendJson({
    required String method,
    required String baseUrl,
    required String path,
    Map<String, String>? query,
    String? accessToken,
    Object? body,
  }) async {
    final client = _client();
    try {
      late HttpClientRequest request;
      final uri = _uri(baseUrl, path, query);
      switch (method.toUpperCase()) {
        case 'GET':
          request = await client.getUrl(uri);
          break;
        case 'POST':
          request = await client.postUrl(uri);
          break;
        case 'DELETE':
          request = await client.deleteUrl(uri);
          break;
        default:
          throw BackendApiException('Unsupported method $method');
      }

      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (accessToken != null && accessToken.isNotEmpty) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      // Overall response deadline. The free-tier backend can take 30-60s to
      // cold-start; 90s comfortably covers that while guaranteeing no call
      // ever hangs forever (before this, a request during a cold start could
      // leave a blind student waiting in silence indefinitely).
      final response =
          await request.close().timeout(const Duration(seconds: 90));
      final raw = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      dynamic parsed;
      if (raw.isNotEmpty) {
        try {
          parsed = jsonDecode(raw);
        } on FormatException {
          parsed = raw;
        }
      }
      return (response.statusCode, parsed);
    } on TimeoutException {
      throw BackendApiException(
          'The server is taking too long to respond. It may be waking up — '
          'please try again in a minute.');
    } on SocketException catch (e) {
      throw BackendApiException('Network error: ${e.message}');
    } on HandshakeException {
      throw BackendApiException(
          'TLS handshake failed. Check HTTPS URL/certificates.');
    } finally {
      client.close(force: true);
    }
  }

  /// Best-effort, fire-and-forget wake-up call for a free-tier backend.
  ///
  /// Hits the root endpoint (no DB work, cheapest possible request) and
  /// swallows every failure — being offline must never surface an error from
  /// a warm-up. Returns `true` when the backend answered.
  Future<bool> warmUp({String baseUrl = kDefaultBackendBaseUrl}) async {
    try {
      final (statusCode, _) = await _sendJson(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/',
      ).timeout(const Duration(seconds: 75));
      return _isSuccess(statusCode);
    } catch (_) {
      return false;
    }
  }

  Future<BackendAuthTokens> login({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/auth/login',
      body: {
        'email': email.trim(),
        'password': password,
      },
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Login failed'),
        statusCode: statusCode,
      );
    }

    if (data is! Map<String, dynamic>) {
      throw BackendApiException('Unexpected login response format.',
          statusCode: statusCode);
    }
    final accessToken = data['access_token']?.toString() ?? '';
    final refreshToken = data['refresh_token']?.toString() ?? '';
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw BackendApiException('Backend did not return required tokens.',
          statusCode: statusCode);
    }
    return BackendAuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<BackendAuthTokens> refreshToken({
    required String baseUrl,
    required String refreshToken,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/auth/refresh',
      body: {'refresh_token': refreshToken},
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Token refresh failed'),
        statusCode: statusCode,
      );
    }
    if (data is! Map<String, dynamic>) {
      throw BackendApiException('Unexpected refresh response format.',
          statusCode: statusCode);
    }
    final access = data['access_token']?.toString() ?? '';
    final refresh = data['refresh_token']?.toString() ?? '';
    if (access.isEmpty || refresh.isEmpty) {
      throw BackendApiException('Refresh response missing tokens.',
          statusCode: statusCode);
    }
    return BackendAuthTokens(accessToken: access, refreshToken: refresh);
  }

  Future<int> listMyNotes({
    required String baseUrl,
    required String accessToken,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/notes',
      query: {'skip': '0', 'limit': '1'},
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not fetch notes'),
        statusCode: statusCode,
      );
    }
    if (data is List) return data.length;
    throw BackendApiException('Unexpected notes response payload.');
  }

  Future<RouteAuditResult> runSubjectTeacherRouteAudit({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final entries = <RouteAuditEntry>[];

    void addEntry({
      required String route,
      required String method,
      required int statusCode,
      required String outcome,
      required String detail,
    }) {
      entries.add(RouteAuditEntry(
        route: route,
        method: method,
        statusCode: statusCode,
        outcome: outcome,
        detail: detail,
      ));
    }

    Future<(int, dynamic)> probe({
      required String route,
      required String method,
      required Future<(int, dynamic)> Function() call,
      Set<int> expected = const <int>{},
      bool allowFailure = false,
    }) async {
      try {
        final (status, body) = await call();
        final ok = _isSuccess(status) || expected.contains(status);
        if (ok) {
          addEntry(
            route: route,
            method: method,
            statusCode: status,
            outcome: expected.contains(status) && !_isSuccess(status)
                ? 'expected'
                : 'success',
            detail: _isSuccess(status)
                ? 'ok'
                : 'expected restricted response (${_extractDetail(body)})',
          );
        } else {
          addEntry(
            route: route,
            method: method,
            statusCode: status,
            outcome: allowFailure ? 'skipped' : 'failed',
            detail: _extractDetail(body),
          );
        }
        return (status, body);
      } catch (e) {
        addEntry(
          route: route,
          method: method,
          statusCode: 0,
          outcome: allowFailure ? 'skipped' : 'failed',
          detail: e.toString(),
        );
        return (0, null);
      }
    }

    final (healthStatus, _) = await probe(
      route: '/health',
      method: 'GET',
      call: () => _sendJson(method: 'GET', baseUrl: baseUrl, path: '/health'),
    );
    if (!_isSuccess(healthStatus)) {
      final failed = entries.where((e) => e.outcome == 'failed').length;
      final skipped = entries.where((e) => e.outcome == 'skipped').length;
      final succeeded = entries.length - failed - skipped;
      return RouteAuditResult(
        entries: entries,
        succeeded: succeeded,
        failed: failed,
        skipped: skipped,
      );
    }

    final tokens =
        await login(baseUrl: baseUrl, email: email, password: password);
    await saveSession(
      baseUrl: baseUrl,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      email: email,
    );
    addEntry(
      route: '/api/v1/auth/login',
      method: 'POST',
      statusCode: 200,
      outcome: 'success',
      detail: 'authenticated',
    );

    final (refreshStatus, refreshBody) = await probe(
      route: '/api/v1/auth/refresh',
      method: 'POST',
      call: () => _sendJson(
        method: 'POST',
        baseUrl: baseUrl,
        path: '/api/v1/auth/refresh',
        body: {'refresh_token': tokens.refreshToken},
      ),
    );
    String accessToken = tokens.accessToken;
    String refreshTokenValue = tokens.refreshToken;
    if (_isSuccess(refreshStatus) && refreshBody is Map<String, dynamic>) {
      accessToken = refreshBody['access_token']?.toString() ?? accessToken;
      refreshTokenValue =
          refreshBody['refresh_token']?.toString() ?? refreshTokenValue;
      await saveSession(
        baseUrl: baseUrl,
        accessToken: accessToken,
        refreshToken: refreshTokenValue,
        email: email,
      );
    }

    String? classId;
    String? subjectId;
    String? noteId;
    String? unitId;
    String? studentId;
    String? sessionId;

    final (_, notesBody) = await probe(
      route: '/api/v1/notes',
      method: 'GET',
      call: () => _sendJson(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/api/v1/notes',
        query: {'skip': '0', 'limit': '20'},
        accessToken: accessToken,
      ),
    );
    if (notesBody is List && notesBody.isNotEmpty) {
      final first = notesBody.first;
      if (first is Map<String, dynamic>) {
        classId = first['class_id']?.toString();
        subjectId = first['subject_id']?.toString();
        noteId = first['id']?.toString();
      }
    }

    if (classId != null) {
      await probe(
        route: '/api/v1/classes/$classId',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/classes/$classId',
          accessToken: accessToken,
        ),
      );
      await probe(
        route: '/api/v1/classes/$classId/subjects',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/classes/$classId/subjects',
          accessToken: accessToken,
        ),
      );
      await probe(
        route: '/api/v1/classes/$classId/students',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/classes/$classId/students',
          accessToken: accessToken,
        ),
        expected: const {403},
      );
      await probe(
        route: '/api/v1/classes/$classId/matrix',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/classes/$classId/matrix',
          accessToken: accessToken,
        ),
        expected: const {403},
      );
    } else {
      addEntry(
        route: '/api/v1/classes/*',
        method: 'GET',
        statusCode: 0,
        outcome: 'skipped',
        detail: 'No class_id found from notes',
      );
    }

    if (subjectId != null) {
      final (_, bySubjectBody) = await probe(
        route: '/api/v1/progress/by-subject/$subjectId',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/progress/by-subject/$subjectId',
          accessToken: accessToken,
        ),
      );
      if (bySubjectBody is List && bySubjectBody.isNotEmpty) {
        final first = bySubjectBody.first;
        if (first is Map<String, dynamic>) {
          studentId = first['student_id']?.toString();
        }
      }
    } else {
      addEntry(
        route: '/api/v1/progress/by-subject/{subject_id}',
        method: 'GET',
        statusCode: 0,
        outcome: 'skipped',
        detail: 'No subject_id found from notes',
      );
    }

    await probe(
      route: '/api/v1/progress/me',
      method: 'GET',
      call: () => _sendJson(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/api/v1/progress/me',
        accessToken: accessToken,
      ),
      expected: const {403},
    );
    await probe(
      route: '/api/v1/progress/me/by-subject',
      method: 'GET',
      call: () => _sendJson(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/api/v1/progress/me/by-subject',
        accessToken: accessToken,
      ),
      expected: const {403},
    );
    await probe(
      route: '/api/v1/progress/students',
      method: 'GET',
      call: () => _sendJson(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/api/v1/progress/students',
        accessToken: accessToken,
      ),
      expected: const {403},
    );

    if (noteId != null) {
      await probe(
        route: '/api/v1/notes/$noteId',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/notes/$noteId',
          accessToken: accessToken,
        ),
      );
      final (_, unitsBody) = await probe(
        route: '/api/v1/notes/$noteId/units',
        method: 'GET',
        call: () => _sendJson(
          method: 'GET',
          baseUrl: baseUrl,
          path: '/api/v1/notes/$noteId/units',
          accessToken: accessToken,
        ),
        allowFailure: true,
      );
      if (unitsBody is List && unitsBody.isNotEmpty) {
        final firstUnit = unitsBody.first;
        if (firstUnit is Map<String, dynamic>) {
          unitId = firstUnit['id']?.toString();
        }
      }
      if (unitId != null) {
        await probe(
          route: '/api/v1/notes/$noteId/units/$unitId/artefacts',
          method: 'GET',
          call: () => _sendJson(
            method: 'GET',
            baseUrl: baseUrl,
            path: '/api/v1/notes/$noteId/units/$unitId/artefacts',
            accessToken: accessToken,
          ),
          allowFailure: true,
        );
      }
    } else {
      addEntry(
        route: '/api/v1/notes/{note_id}*',
        method: 'GET',
        statusCode: 0,
        outcome: 'skipped',
        detail: 'No note_id found from /notes',
      );
    }

    if (noteId != null && unitId != null && studentId != null) {
      final (_, startBody) = await probe(
        route: '/api/v1/voice/session/start',
        method: 'POST',
        call: () => _sendJson(
          method: 'POST',
          baseUrl: baseUrl,
          path: '/api/v1/voice/session/start',
          accessToken: accessToken,
          body: {
            'student_id': studentId,
            'note_id': noteId,
            'unit_id': unitId,
          },
        ),
      );
      if (startBody is Map<String, dynamic>) {
        sessionId = startBody['session_id']?.toString();
      }

      if (sessionId != null) {
        await probe(
          route: '/api/v1/voice/session/$sessionId',
          method: 'GET',
          call: () => _sendJson(
            method: 'GET',
            baseUrl: baseUrl,
            path: '/api/v1/voice/session/$sessionId',
            accessToken: accessToken,
          ),
        );
        await probe(
          route: '/api/v1/voice/session/event',
          method: 'POST',
          call: () => _sendJson(
            method: 'POST',
            baseUrl: baseUrl,
            path: '/api/v1/voice/session/event',
            accessToken: accessToken,
            body: {
              'session_id': sessionId,
              'interaction_type': 'repeat',
              'command': 'repeat this section',
              'confidence': 0.9,
              'response': 'Repeating current section.',
            },
          ),
        );
        await probe(
          route: '/api/v1/voice/session/$sessionId/interactions',
          method: 'GET',
          call: () => _sendJson(
            method: 'GET',
            baseUrl: baseUrl,
            path: '/api/v1/voice/session/$sessionId/interactions',
            accessToken: accessToken,
          ),
        );
        await probe(
          route: '/api/v1/voice/session/end',
          method: 'POST',
          call: () => _sendJson(
            method: 'POST',
            baseUrl: baseUrl,
            path: '/api/v1/voice/session/end',
            accessToken: accessToken,
            body: {
              'session_id': sessionId,
              'duration_seconds': 30,
              'questions_answered': 1,
              'total_score': 1.0,
            },
          ),
        );
      }
    } else {
      addEntry(
        route: '/api/v1/voice/session/*',
        method: 'POST/GET',
        statusCode: 0,
        outcome: 'skipped',
        detail: 'Need student_id + note_id + unit_id to run voice route audit',
      );
    }

    await probe(
      route: '/api/v1/auth/logout',
      method: 'POST',
      call: () => _sendJson(
        method: 'POST',
        baseUrl: baseUrl,
        path: '/api/v1/auth/logout',
        accessToken: accessToken,
        body: {'refresh_token': refreshTokenValue},
      ),
      allowFailure: true,
    );

    final failed = entries.where((e) => e.outcome == 'failed').length;
    final skipped = entries.where((e) => e.outcome == 'skipped').length;
    final succeeded = entries.length - failed - skipped;

    return RouteAuditResult(
      entries: entries,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
    );
  }

  String formatAudit(RouteAuditResult result) {
    final buffer = StringBuffer()
      ..writeln('Route audit summary:')
      ..writeln('  success: ${result.succeeded}')
      ..writeln('  failed : ${result.failed}')
      ..writeln('  skipped: ${result.skipped}')
      ..writeln('');
    for (final e in result.entries) {
      buffer.writeln(
        '[${e.outcome.toUpperCase()}] ${e.method} ${e.route} -> ${e.statusCode == 0 ? '-' : e.statusCode} (${e.detail})',
      );
    }
    return buffer.toString();
  }

  Future<BackendSession?> getSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_kBaseUrl);
    final token = prefs.getString(_kAccessToken);
    final refreshToken = prefs.getString(_kRefreshToken);
    final email = prefs.getString(_kEmail);
    if (baseUrl == null ||
        token == null ||
        refreshToken == null ||
        email == null) {
      return null;
    }
    return BackendSession(
      baseUrl: baseUrl,
      accessToken: token,
      refreshToken: refreshToken,
      email: email,
    );
  }

  Future<void> saveSession({
    required String baseUrl,
    required String accessToken,
    required String refreshToken,
    required String email,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kAccessToken, accessToken);
    await prefs.setString(_kRefreshToken, refreshToken);
    await prefs.setString(_kEmail, email);
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kBaseUrl);
    await prefs.remove(_kAccessToken);
    await prefs.remove(_kRefreshToken);
    await prefs.remove(_kEmail);
  }

  Future<String> verifyAndStoreLogin({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final tokens =
        await login(baseUrl: baseUrl, email: email, password: password);
    await listMyNotes(baseUrl: baseUrl, accessToken: tokens.accessToken);
    await saveSession(
      baseUrl: baseUrl,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      email: email,
    );
    debugPrint(
        '[BackendApiService] Connection verified and session saved for $email');
    return tokens.accessToken;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Account-linking registration
  //
  // The backend enforces a strict admin → class_teacher → subject_teacher →
  // student hierarchy, while this app only knows "one teacher = one subject"
  // and "one student per device". `BackendLinkService` chains these calls into
  // a single guided action so neither role ever has to understand the
  // hierarchy — they just answer two or three spoken questions.
  // ───────────────────────────────────────────────────────────────────────────

  /// Step 1 of teacher linking: creates a brand-new class on the backend.
  /// Returns the generated `teacher_code` (to recruit subject teachers) and
  /// `student_code` (to recruit students) inside [BackendRegistrationResult].
  Future<BackendRegistrationResult> registerClassTeacher({
    required String baseUrl,
    required String email,
    required String fullName,
    required String password,
    required String className,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/auth/register/class-teacher',
      body: {
        'email': email.trim(),
        'full_name': fullName.trim(),
        'password': password,
        'class_name': className.trim(),
      },
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not create the class on the backend.'),
        statusCode: statusCode,
      );
    }
    return BackendRegistrationResult.fromJson(data);
  }

  /// Step 2 of teacher linking: registers (or joins) as a subject teacher —
  /// the only role allowed to upload notes. Pass [teacherCode] to join an
  /// existing class (e.g. one the user just created in step 1, or one a
  /// colleague shared), and [subjectName] to create/select the taught subject.
  Future<BackendRegistrationResult> registerSubjectTeacher({
    required String baseUrl,
    required String email,
    required String fullName,
    required String password,
    String? teacherCode,
    String? subjectName,
  }) async {
    final body = <String, dynamic>{
      'email': email.trim(),
      'full_name': fullName.trim(),
      'password': password,
    };
    if (teacherCode != null && teacherCode.trim().isNotEmpty) {
      body['teacher_code'] = teacherCode.trim();
    }
    if (subjectName != null && subjectName.trim().isNotEmpty) {
      body['subject_name'] = subjectName.trim();
    }
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/auth/register/subject-teacher',
      body: body,
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(
            data, 'Could not register the subject teacher account.'),
        statusCode: statusCode,
      );
    }
    return BackendRegistrationResult.fromJson(data);
  }

  /// The authenticated account's own identity, class and subjects. Used to
  /// restore a teacher/student on a new device without depending on notes.
  Future<BackendMe> getMe({
    required String baseUrl,
    required String accessToken,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/auth/me',
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not load your account details.'),
        statusCode: statusCode,
      );
    }
    return BackendMe.fromJson(data);
  }

  /// Creates (or returns the existing) subject [subjectName] inside [classId].
  /// A class teacher calling this becomes the subject's teacher, which is
  /// exactly what a one-teacher class needs to publish notes. Returns the
  /// subject's id.
  Future<String> addSubjectToClass({
    required String baseUrl,
    required String accessToken,
    required String classId,
    required String subjectName,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/classes/$classId/subjects',
      accessToken: accessToken,
      body: {'subject_name': subjectName.trim()},
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not create your subject.'),
        statusCode: statusCode,
      );
    }
    return data['id']?.toString() ?? '';
  }

  /// Registers a student using only the `student_code` their teacher reads
  /// out loud — [email] and [password] are generated locally by
  /// `BackendLinkService` so a blind student never has to type credentials.
  Future<BackendRegistrationResult> registerStudent({
    required String baseUrl,
    required String email,
    required String fullName,
    required String password,
    required String studentCode,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/auth/register/student',
      body: {
        'email': email.trim(),
        'full_name': fullName.trim(),
        'password': password,
        'student_code': studentCode.trim(),
      },
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data,
            'Could not join the class. Double-check the class code with your teacher.'),
        statusCode: statusCode,
      );
    }
    return BackendRegistrationResult.fromJson(data);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Notes / cloud AI pipeline
  // ───────────────────────────────────────────────────────────────────────────

  /// Creates a lesson note from metadata via the JSON `/notes/upload`
  /// endpoint (no file upload). The full lesson text is carried in
  /// [description] — an unlimited `Text` column — so students receive the real
  /// content even though this endpoint does not run a file-processing pipeline.
  /// The created note is marked `READY` immediately. Returns the new note.
  Future<BackendNote> createNote({
    required String baseUrl,
    required String accessToken,
    required String title,
    required String subjectId,
    required String gradeLevel,
    String? description,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/notes/upload',
      accessToken: accessToken,
      body: {
        'title': title,
        'subject_id': subjectId,
        'grade_level': gradeLevel,
        if (description != null) 'description': description,
      },
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not upload the note to your class.'),
        statusCode: statusCode,
      );
    }
    return BackendNote.fromJson(data);
  }

  /// Pushes the phone-generated quiz questions for [noteId] to the backend as
  /// unapproved review items (`POST /notes/{id}/questions`). The teacher then
  /// approves/edits/deletes them in the review screen from any device. Each
  /// entry in [questions] is the endpoint's JSON shape:
  /// `{question_text, options: [{text, is_correct}], explanation}`.
  Future<int> pushNoteQuestions({
    required String baseUrl,
    required String accessToken,
    required String noteId,
    required List<Map<String, dynamic>> questions,
  }) async {
    if (questions.isEmpty) return 0;
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/notes/$noteId/questions',
      accessToken: accessToken,
      body: {'questions': questions},
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not send questions for review.'),
        statusCode: statusCode,
      );
    }
    return data is List ? data.length : 0;
  }

  /// Uploads a raw note file to the backend's AI pipeline (multipart form).
  /// The note starts life as `PENDING_PROCESSING`; poll [getNote] until its
  /// status flips to `READY` (units + quiz artefacts) or `ERROR`.
  ///
  /// [filePath] must point to a real file on disk — the same file the local
  /// `FileExtractionService` already read text out of, so nothing extra is
  /// asked of the teacher.
  Future<BackendNote> uploadNoteWithFile({
    required String baseUrl,
    required String accessToken,
    required String title,
    required String subjectId,
    required String gradeLevel,
    required String filePath,
    String? description,
    int? durationSeconds,
  }) async {
    final uri = _uri(baseUrl, '/api/v1/notes/upload-with-file');
    final request = http.MultipartRequest('POST', uri)
      ..headers[HttpHeaders.acceptHeader] = 'application/json'
      ..headers[HttpHeaders.authorizationHeader] = 'Bearer $accessToken'
      ..fields['title'] = title
      ..fields['subject_id'] = subjectId
      ..fields['grade_level'] = gradeLevel;
    if (description != null && description.trim().isNotEmpty) {
      request.fields['description'] = description.trim();
    }
    if (durationSeconds != null) {
      request.fields['duration_seconds'] = durationSeconds.toString();
    }

    try {
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
    } catch (e) {
      throw BackendApiException('Could not read the file to upload: $e');
    }

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 60));
      final raw = await streamed.stream.bytesToString();
      dynamic parsed;
      if (raw.isNotEmpty) {
        try {
          parsed = jsonDecode(raw);
        } on FormatException {
          parsed = raw;
        }
      }
      if (!_isSuccess(streamed.statusCode) || parsed is! Map<String, dynamic>) {
        throw BackendApiException(
          _extractDetail(parsed, 'Note upload failed.'),
          statusCode: streamed.statusCode,
        );
      }
      return BackendNote.fromJson(parsed);
    } on SocketException catch (e) {
      throw BackendApiException('Network error during upload: ${e.message}');
    }
  }

  /// Fetches a single note — used to poll for `READY`/`ERROR` after upload.
  Future<BackendNote> getNote({
    required String baseUrl,
    required String accessToken,
    required String noteId,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/notes/$noteId',
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not fetch note status.'),
        statusCode: statusCode,
      );
    }
    return BackendNote.fromJson(data);
  }

  /// Lists notes visible to the current account (newest first, per backend).
  Future<List<BackendNote>> listNotes({
    required String baseUrl,
    required String accessToken,
    int skip = 0,
    int limit = 50,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/notes',
      query: {'skip': '$skip', 'limit': '$limit'},
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not list notes.'),
        statusCode: statusCode,
      );
    }
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(BackendNote.fromJson)
        .toList(growable: false);
  }

  /// Fetches the AI-generated content chunks for a `READY` note, in playback
  /// order — the cloud equivalent of the locally-split lesson segments.
  Future<List<BackendUnit>> getUnits({
    required String baseUrl,
    required String accessToken,
    required String noteId,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/notes/$noteId/units',
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not fetch lesson content.'),
        statusCode: statusCode,
      );
    }
    if (data is! List) return const [];
    final units = data
        .whereType<Map<String, dynamic>>()
        .map(BackendUnit.fromJson)
        .toList();
    units.sort((a, b) => a.sequenceNumber.compareTo(b.sequenceNumber));
    return units;
  }

  /// Fetches AI-generated quiz/summary artefacts for one content unit.
  Future<List<BackendArtefact>> getArtefacts({
    required String baseUrl,
    required String accessToken,
    required String noteId,
    required String unitId,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/api/v1/notes/$noteId/units/$unitId/artefacts',
      accessToken: accessToken,
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not fetch quiz questions.'),
        statusCode: statusCode,
      );
    }
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(BackendArtefact.fromJson)
        .toList(growable: false);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Progress sync (students only)
  // ───────────────────────────────────────────────────────────────────────────

  /// Reports playback progress for [noteId] — mirrors the local `ProgressTable`
  /// upsert the study screen already performs, just sent to the cloud too so
  /// the linked teacher/class can see how far a student has gotten.
  Future<BackendProgress> postProgress({
    required String baseUrl,
    required String accessToken,
    required String noteId,
    required int lastPositionSeconds,
    required bool completed,
    double? completionPercentage,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/progress',
      accessToken: accessToken,
      body: {
        'note_id': noteId,
        'last_position_seconds': lastPositionSeconds,
        'completed': completed,
        if (completionPercentage != null)
          'completion_percentage': completionPercentage,
      },
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not sync progress.'),
        statusCode: statusCode,
      );
    }
    return BackendProgress.fromJson(data);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Voice interaction sessions
  //
  // The backend already models spoken commands as first-class events. Logging
  // them turns the app's existing gesture/voice interactions into data the
  // teacher's dashboard can show — without changing how a student uses the app.
  // ───────────────────────────────────────────────────────────────────────────

  Future<BackendVoiceSession> startVoiceSession({
    required String baseUrl,
    required String accessToken,
    required String studentId,
    required String noteId,
    required String unitId,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/voice/session/start',
      accessToken: accessToken,
      body: {'student_id': studentId, 'note_id': noteId, 'unit_id': unitId},
    );
    if (!_isSuccess(statusCode) || data is! Map<String, dynamic>) {
      throw BackendApiException(
        _extractDetail(data, 'Could not start voice session.'),
        statusCode: statusCode,
      );
    }
    return BackendVoiceSession.fromJson(data);
  }

  /// Logs one spoken/gestural interaction (e.g. "repeat", "next", "answer A").
  /// Fire-and-forget from the caller's perspective — failures are swallowed by
  /// `BackendLinkService` wrappers so a flaky connection never interrupts
  /// playback for the student.
  Future<void> sendVoiceEvent({
    required String baseUrl,
    required String accessToken,
    required String sessionId,
    required String interactionType,
    required String command,
    required String response,
    double confidence = 0.9,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/voice/session/event',
      accessToken: accessToken,
      body: {
        'session_id': sessionId,
        'interaction_type': interactionType,
        'command': command,
        'confidence': confidence,
        'response': response,
      },
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not log voice interaction.'),
        statusCode: statusCode,
      );
    }
  }

  Future<void> endVoiceSession({
    required String baseUrl,
    required String accessToken,
    required String sessionId,
    required int durationSeconds,
    required int questionsAnswered,
    required double totalScore,
  }) async {
    final (statusCode, data) = await _sendJson(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/api/v1/voice/session/end',
      accessToken: accessToken,
      body: {
        'session_id': sessionId,
        'duration_seconds': durationSeconds,
        'questions_answered': questionsAnswered,
        'total_score': totalScore,
      },
    );
    if (!_isSuccess(statusCode)) {
      throw BackendApiException(
        _extractDetail(data, 'Could not close voice session.'),
        statusCode: statusCode,
      );
    }
  }
}
