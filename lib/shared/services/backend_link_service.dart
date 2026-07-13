import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_question_service.dart';
import 'backend_api_service.dart';
import 'db/app_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Backend Link Service
//
// WHY THIS EXISTS
// ----------------
// The backend enforces a strict hierarchy: admin → class_teacher (owns a
// class, gets a `teacher_code` and `student_code` to recruit people) →
// subject_teacher (joins a class with a `teacher_code`, the only role allowed
// to upload notes) → student (joins with a `student_code`).
//
// The Flutter app, by contrast, was built around a flat "one teacher = one
// subject" PIN profile and a single student per device — it has no concept of
// classes, codes, or multi-step onboarding, because none of that matters for
// a visually-impaired user navigating by touch and voice.
//
// This service is the bridge: it hides the backend's multi-step hierarchy
// behind ONE guided action per role, persists the resulting session and the
// local↔remote ID mappings (so uploads/progress can reference the right
// backend records), and never asks a blind student to type anything they
// can't speak. Students only ever need to *hear* and *repeat* a short code.
// ─────────────────────────────────────────────────────────────────────────────

/// Persisted record of a teacher's backend link: which local [Teacher] row
/// (by id) maps to which backend account/session/subject.
class TeacherLinkInfo {
  const TeacherLinkInfo({
    required this.baseUrl,
    required this.email,
    required this.password,
    required this.accessToken,
    required this.refreshToken,
    required this.classId,
    required this.subjectId,
    required this.teacherCode,
    required this.studentCode,
  });

  final String baseUrl;
  final String email;

  /// Stored locally (never displayed) so the token can be silently refreshed
  /// or re-obtained after it expires — the recoverable credential behind
  /// Option A teacher accounts.
  final String password;
  final String accessToken;
  final String refreshToken;
  final String? classId;
  final String? subjectId;
  final String? teacherCode;
  final String? studentCode;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'email': email,
        'password': password,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'classId': classId,
        'subjectId': subjectId,
        'teacherCode': teacherCode,
        'studentCode': studentCode,
      };

  factory TeacherLinkInfo.fromJson(Map<String, dynamic> json) {
    return TeacherLinkInfo(
      baseUrl: json['baseUrl']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      accessToken: json['accessToken']?.toString() ?? '',
      refreshToken: json['refreshToken']?.toString() ?? '',
      classId: json['classId']?.toString(),
      subjectId: json['subjectId']?.toString(),
      teacherCode: json['teacherCode']?.toString(),
      studentCode: json['studentCode']?.toString(),
    );
  }

  TeacherLinkInfo copyWith({
    String? accessToken,
    String? refreshToken,
    String? subjectId,
  }) {
    return TeacherLinkInfo(
      baseUrl: baseUrl,
      email: email,
      password: password,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      classId: classId,
      subjectId: subjectId ?? this.subjectId,
      teacherCode: teacherCode,
      studentCode: studentCode,
    );
  }
}

/// Persisted record of a student's backend link.
class StudentLinkInfo {
  const StudentLinkInfo({
    required this.baseUrl,
    required this.email,
    required this.password,
    required this.accessToken,
    required this.refreshToken,
    required this.classId,
    required this.studentCode,
    required this.remoteStudentId,
  });

  final String baseUrl;
  final String email;

  /// Stored locally (never spoken aloud) purely so the app can silently
  /// re-authenticate after a token expires — the student never types it.
  final String password;
  final String accessToken;
  final String refreshToken;
  final String? classId;
  final String studentCode;

  /// The backend's UUID for this student account — required by the
  /// `/api/v1/voice/session/*` routes, which key on it directly (distinct
  /// from the local integer [Student.id]).
  final String remoteStudentId;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'email': email,
        'password': password,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'classId': classId,
        'studentCode': studentCode,
        'remoteStudentId': remoteStudentId,
      };

  factory StudentLinkInfo.fromJson(Map<String, dynamic> json) {
    return StudentLinkInfo(
      baseUrl: json['baseUrl']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      accessToken: json['accessToken']?.toString() ?? '',
      refreshToken: json['refreshToken']?.toString() ?? '',
      classId: json['classId']?.toString(),
      studentCode: json['studentCode']?.toString() ?? '',
      remoteStudentId: json['remoteStudentId']?.toString() ?? '',
    );
  }

  StudentLinkInfo copyWith({String? accessToken, String? refreshToken}) {
    return StudentLinkInfo(
      baseUrl: baseUrl,
      email: email,
      password: password,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      classId: classId,
      studentCode: studentCode,
      remoteStudentId: remoteStudentId,
    );
  }
}

class BackendLinkService {
  BackendLinkService(this._api);

  final BackendApiService _api;

  /// Link records hold the account password (needed for silent re-login), so
  /// they belong in the platform keystore, not plain SharedPreferences. Older
  /// installs that saved links in SharedPreferences are migrated on first
  /// read — see [_readLinkJson].
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const _kTeacherLinkPrefix = 'backend_link_teacher_';
  static const _kStudentLinkPrefix = 'backend_link_student_';
  static const _kSignedInTeacher = 'signed_in_teacher_id';
  static const _kSubjectMap =
      'backend_map_subject'; // local subject id -> remote subject id
  static const _kNoteMap =
      'backend_map_note'; // local lesson id -> remote note id
  static const _kUnitMap =
      'backend_map_unit'; // local lesson id -> remote unit id

  // ───────────────────────────────────────────────────────────────────────────
  // Teacher linking
  // ───────────────────────────────────────────────────────────────────────────

  /// Reads a link record from secure storage, transparently migrating any
  /// record an older build left in SharedPreferences (then wiping the
  /// plaintext copy). Returns the raw JSON string or null.
  Future<String?> _readLinkJson(String key) async {
    try {
      final secureValue = await _secure.read(key: key);
      if (secureValue != null && secureValue.isNotEmpty) return secureValue;
    } catch (_) {
      // Secure storage unavailable (rare, e.g. corrupted keystore) — fall
      // back to SharedPreferences below rather than losing the account link.
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(key);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _secure.write(key: key, value: legacy);
        await prefs.remove(key);
      } catch (_) {/* keep the prefs copy if migration fails */}
      return legacy;
    }
    return null;
  }

  Future<void> _writeLinkJson(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
      // Make sure no stale plaintext copy lingers from an older build.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {
      // Last resort so the link is not lost entirely on keystore failure.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  Future<void> _deleteLinkJson(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<TeacherLinkInfo?> getTeacherLink(int teacherId) async {
    final raw = await _readLinkJson('$_kTeacherLinkPrefix$teacherId');
    if (raw == null) return null;
    try {
      return TeacherLinkInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTeacherLink(int teacherId, TeacherLinkInfo info) async {
    await _writeLinkJson(
        '$_kTeacherLinkPrefix$teacherId', jsonEncode(info.toJson()));
  }

  Future<void> forgetTeacherLink(int teacherId) async {
    await _deleteLinkJson('$_kTeacherLinkPrefix$teacherId');
  }

  // ── "Stay signed in" session ────────────────────────────────────────────
  // Which local teacher row is the signed-in account on this device. Set on
  // sign-up / sign-in, read on launch to go straight to the dashboard, and
  // cleared on sign-out.

  Future<void> setSignedInTeacher(int teacherId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSignedInTeacher, teacherId);
  }

  Future<int?> getSignedInTeacherId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kSignedInTeacher);
  }

  Future<void> clearSignedInTeacher() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSignedInTeacher);
  }

  /// Best-effort display name from an email local-part, since the backend has
  /// no profile-fetch endpoint: "joseph.mendes@x" -> "Joseph Mendes". The
  /// account's real identity is the email; this is only the on-device name.
  static String _nameFromEmail(String email) {
    final local = email.split('@').first.trim();
    if (local.isEmpty) return 'Teacher';
    return local
        .replaceAll(RegExp(r'[._]+'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : ''))
        .join(' ');
  }

  /// Guided teacher onboarding in ONE call, one real account.
  ///
  /// Default path (no [joinTeacherCode]): registers the teacher as the
  /// **class teacher** of a brand-new class named [className] — the account is
  /// created with their REAL email, so it is recoverable on any device — then
  /// creates the subject [subjectName] inside that class (the class teacher
  /// becomes its subject teacher, which is all they need to upload notes).
  ///
  /// Join path ([joinTeacherCode] set): the teacher joins an EXISTING class a
  /// colleague set up, registering as a `subject_teacher` of [subjectName].
  ///
  /// This replaces the old two-account hack (a `+class`-tagged class-teacher
  /// account plus a separate subject-teacher account), which existed only
  /// because uploads once required the subject-teacher role. The backend now
  /// lets a class teacher upload to their own class, so one account is enough.
  ///
  /// Returns the persisted [TeacherLinkInfo], including the `studentCode` and
  /// `teacherCode` the teacher reads out to students and colleagues.
  Future<TeacherLinkInfo> linkTeacherAccount({
    required int localTeacherId,
    required String baseUrl,
    required String fullName,
    required String email,
    required String password,
    required String subjectName,
    String? className,
    String? joinTeacherCode,
  }) async {
    final joining =
        joinTeacherCode != null && joinTeacherCode.trim().isNotEmpty;

    if (joining) {
      // Subject teacher joining a colleague's class.
      final result = await _api.registerSubjectTeacher(
        baseUrl: baseUrl,
        email: email,
        fullName: fullName,
        password: password,
        teacherCode: joinTeacherCode.trim(),
        subjectName: subjectName,
      );
      final tokens =
          await _api.login(baseUrl: baseUrl, email: email, password: password);
      final info = TeacherLinkInfo(
        baseUrl: baseUrl,
        email: email,
        password: password,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        classId: result.classId,
        subjectId: result.subjectId,
        teacherCode: joinTeacherCode.trim(),
        studentCode: null,
      );
      await _saveTeacherLink(localTeacherId, info);
      return info;
    }

    // Class teacher creating their own class.
    final classResult = await _api.registerClassTeacher(
      baseUrl: baseUrl,
      email: email,
      fullName: fullName,
      password: password,
      className: (className == null || className.trim().isEmpty)
          ? '$subjectName Class'
          : className.trim(),
    );

    final tokens =
        await _api.login(baseUrl: baseUrl, email: email, password: password);

    // Create the subject they teach inside their class, so uploads have a
    // subject to file under from the very first lesson.
    String? subjectId;
    if (classResult.classId != null) {
      try {
        subjectId = await _api.addSubjectToClass(
          baseUrl: baseUrl,
          accessToken: tokens.accessToken,
          classId: classResult.classId!,
          subjectName: subjectName,
        );
      } catch (_) {
        // Non-fatal: the account + class exist; the subject can be created on
        // first upload. Leave subjectId null rather than fail onboarding.
      }
    }

    final info = TeacherLinkInfo(
      baseUrl: baseUrl,
      email: email,
      password: password,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      classId: classResult.classId,
      subjectId: subjectId,
      teacherCode: classResult.teacherCode,
      studentCode: classResult.studentCode,
    );
    await _saveTeacherLink(localTeacherId, info);
    return info;
  }

  /// Returns `true` when [jwt]'s `exp` claim is more than a minute away —
  /// i.e. the token can be used as-is without any network round-trip.
  ///
  /// This check is what keeps voice interactions snappy: before it existed,
  /// EVERY fire-and-forget analytics call (each spoken command!) performed a
  /// full token-refresh request first, doubling traffic to a backend that can
  /// take tens of seconds to wake from its free-tier cold start.
  static bool _tokenStillValid(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic>) return false;
      final exp = payload['exp'];
      if (exp is! num) return false;
      final expiry =
          DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
      return expiry.difference(DateTime.now().toUtc()) >
          const Duration(seconds: 60);
    } catch (_) {
      return false;
    }
  }

  /// Returns a usable access token for [teacherId], silently refreshing it if
  /// the stored one has expired. Returns `null` if the teacher isn't linked.
  Future<String?> ensureTeacherToken(int teacherId) async {
    final link = await getTeacherLink(teacherId);
    if (link == null) return null;
    // Fast path: token demonstrably still valid — skip the network entirely.
    if (_tokenStillValid(link.accessToken)) return link.accessToken;
    try {
      final refreshed = await _api.refreshToken(
          baseUrl: link.baseUrl, refreshToken: link.refreshToken);
      final updated = link.copyWith(
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.refreshToken,
      );
      await _saveTeacherLink(teacherId, updated);
      return updated.accessToken;
    } on BackendApiException catch (_) {
      // Refresh failed (expired/rotated) — fall back to a full re-login with
      // the locally-stored real credentials, the same way the student flow
      // recovers. Older links saved without a password simply can't recover.
      if (link.password.isEmpty) return null;
      try {
        final tokens = await _api.login(
          baseUrl: link.baseUrl,
          email: link.email,
          password: link.password,
        );
        final updated = link.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        await _saveTeacherLink(teacherId, updated);
        return updated.accessToken;
      } catch (_) {
        return null;
      }
    }
  }

  /// Account recovery: logs a teacher into their cloud account with the real
  /// email + password they set, then rebuilds their profile and notes on this
  /// device. This is what lets a teacher account survive an app reinstall or a
  /// move to a new phone — the credentials are ones the teacher knows, so they
  /// can always get back in and find their work.
  ///
  /// Identity (real name, class, subject, class codes) comes from
  /// `GET /auth/me`, so restore works even for a teacher who hasn't uploaded a
  /// single note yet. Their notes are then materialised locally (topics +
  /// lessons, quiz regenerated from the text). Throws [BackendApiException] on
  /// a failed login so the caller can explain why.
  Future<Teacher> loginAndRestoreTeacher({
    required AppDatabase db,
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final tokens = await _api.login(
      baseUrl: baseUrl,
      email: email.trim(),
      password: password,
    );

    // Authoritative identity: name, class, subjects, codes — no dependency on
    // notes existing.
    BackendMe? me;
    try {
      me = await _api.getMe(baseUrl: baseUrl, accessToken: tokens.accessToken);
    } catch (_) {
      me = null; // older backend without /me — fall back to note scraping
    }

    List<BackendNote> notes;
    try {
      notes = await _api.listNotes(
          baseUrl: baseUrl, accessToken: tokens.accessToken);
    } catch (_) {
      notes = const [];
    }

    String? subjectId = me != null && me.subjects.isNotEmpty
        ? me.subjects.first.id
        : null;
    String? classId = me?.classId;
    var cleanSubject = me != null && me.subjects.isNotEmpty
        ? me.subjects.first.subjectName
        : 'My Subject';

    // Fallback for a backend without /me: recover ids/subject from notes.
    if (subjectId == null || classId == null) {
      for (final note in notes) {
        if (note.subjectId != null && note.subjectId!.isNotEmpty) {
          subjectId ??= note.subjectId;
          classId ??= note.classId;
          if (note.subject.trim().isNotEmpty) {
            cleanSubject = note.subject.trim();
          }
          break;
        }
      }
    }

    // Real name from /me; only fall back to the email guess if unavailable.
    final cleanName = (me != null && me.fullName.trim().isNotEmpty)
        ? me.fullName.trim()
        : _nameFromEmail(email);
    var createdAt = DateTime.now().millisecondsSinceEpoch;

    final teacherId = await db.teacherDao.insertTeacher(
      TeachersTableCompanion(
        name: Value(cleanName),
        pinHash: const Value(''),
        subjectName: Value(cleanSubject),
        createdAt: Value(createdAt),
      ),
    );

    await _saveTeacherLink(
      teacherId,
      TeacherLinkInfo(
        baseUrl: baseUrl,
        email: email.trim(),
        password: password,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        classId: classId,
        subjectId: subjectId,
        teacherCode: me?.teacherCode,
        studentCode: me?.studentCode,
      ),
    );

    // Always give the restored teacher a local subject to work under — even
    // with zero notes yet — so they land on a usable dashboard and can upload
    // straight away. Their notes (if any) are then materialised into it.
    {
      final localSubjectId = await db.subjectDao.insertSubject(
        SubjectsTableCompanion(
          teacherId: Value(teacherId),
          name: Value(cleanSubject),
          createdAt: Value(createdAt),
        ),
      );
      var order = 0;
      for (final note in notes) {
        final lessonText = (note.description?.trim().isNotEmpty == true)
            ? note.description!.trim()
            : note.title.trim();
        if (lessonText.isEmpty) continue;
        final topicId = await db.topicDao.insertTopic(
          TopicsTableCompanion(
            subjectId: Value(localSubjectId),
            name: Value(
                note.title.trim().isEmpty ? 'Lesson' : note.title.trim()),
            orderIndex: Value(order++),
            createdAt: Value(createdAt),
          ),
        );
        final lessonId = await db.lessonDao.insertLesson(
          LessonsTableCompanion(
            topicId: Value(topicId),
            rawText: Value(lessonText),
            createdAt: Value(createdAt++),
          ),
        );
        await setRemoteNoteId(lessonId, note.id);
        var pos = 0;
        for (final q in AiQuestionService().generateQuestions(lessonText)) {
          await db.questionDao.insertQuestion(
            QuestionsTableCompanion(
              lessonId: Value(lessonId),
              questionText: Value(q.questionText),
              optionA: Value(q.optionA),
              optionB: Value(q.optionB),
              optionC: Value(q.optionC),
              optionD: Value(q.optionD),
              correctOption: Value(q.correctOption),
              explanation: Value(q.explanation),
              positionInLesson: Value(pos++),
              source: const Value('cloud'),
            ),
          );
        }
      }
    }

    final teacher = await db.teacherDao.getTeacherById(teacherId);
    if (teacher == null) {
      throw BackendApiException('Could not rebuild your local profile.');
    }
    return teacher;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Student linking
  // ───────────────────────────────────────────────────────────────────────────

  Future<StudentLinkInfo?> getStudentLink(int studentId) async {
    final raw = await _readLinkJson('$_kStudentLinkPrefix$studentId');
    if (raw == null) return null;
    try {
      return StudentLinkInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveStudentLink(int studentId, StudentLinkInfo info) async {
    await _writeLinkJson(
        '$_kStudentLinkPrefix$studentId', jsonEncode(info.toJson()));
  }

  Future<void> forgetStudentLink(int studentId) async {
    await _deleteLinkJson('$_kStudentLinkPrefix$studentId');
  }

  /// Guided student onboarding: the student speaks only their name and the
  /// short class code their teacher reads aloud (`student_code`, shape
  /// `SC-XXXX`). Email and password are generated locally — meeting the
  /// backend's password policy — and stored only on-device, never spoken,
  /// never typed. This keeps "audio/voice first" true even for account setup.
  Future<StudentLinkInfo> linkStudentAccount({
    required int localStudentId,
    required String baseUrl,
    required String fullName,
    required String studentCode,
  }) async {
    final email = _generateStudentEmail(localStudentId);
    final password = _generateStrongPassword();

    final result = await _api.registerStudent(
      baseUrl: baseUrl,
      email: email,
      fullName: fullName.trim().isEmpty ? 'Student' : fullName.trim(),
      password: password,
      studentCode: studentCode,
    );

    final tokens = await _api.login(
      baseUrl: baseUrl,
      email: result.email,
      password: password,
    );

    final info = StudentLinkInfo(
      baseUrl: baseUrl,
      email: result.email,
      password: password,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      classId: result.classId,
      studentCode: result.studentCode ?? studentCode,
      remoteStudentId: result.userId,
    );
    await _saveStudentLink(localStudentId, info);
    return info;
  }

  /// Returns a usable access token for [studentId], silently refreshing (or
  /// re-logging in with the locally-stored generated password) if needed.
  /// Returns `null` if the student isn't linked.
  Future<String?> ensureStudentToken(int studentId) async {
    final link = await getStudentLink(studentId);
    if (link == null) return null;
    // Fast path: token demonstrably still valid — skip the network entirely.
    if (_tokenStillValid(link.accessToken)) return link.accessToken;
    try {
      final refreshed = await _api.refreshToken(
          baseUrl: link.baseUrl, refreshToken: link.refreshToken);
      final updated = link.copyWith(
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.refreshToken,
      );
      await _saveStudentLink(studentId, updated);
      return updated.accessToken;
    } on BackendApiException catch (_) {
      try {
        final tokens = await _api.login(
          baseUrl: link.baseUrl,
          email: link.email,
          password: link.password,
        );
        final updated = link.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        await _saveStudentLink(studentId, updated);
        return updated.accessToken;
      } catch (_) {
        return null;
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Local ↔ remote ID mappings
  //
  // Stored as flat JSON maps in SharedPreferences rather than new Drift
  // columns — this avoids any schema migration / build_runner regeneration,
  // which the project's current toolchain setup makes risky to attempt blind.
  // ───────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _readMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {/* fall through */}
    return {};
  }

  Future<void> _writeMap(String key, Map<String, dynamic> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(map));
  }

  Future<String?> getRemoteSubjectId(int localSubjectId) async {
    final map = await _readMap(_kSubjectMap);
    return map['$localSubjectId']?.toString();
  }

  Future<void> setRemoteSubjectId(int localSubjectId, String remoteId) async {
    final map = await _readMap(_kSubjectMap);
    map['$localSubjectId'] = remoteId;
    await _writeMap(_kSubjectMap, map);
  }

  Future<String?> getRemoteNoteId(int localLessonId) async {
    final map = await _readMap(_kNoteMap);
    return map['$localLessonId']?.toString();
  }

  Future<void> setRemoteNoteId(int localLessonId, String remoteId) async {
    final map = await _readMap(_kNoteMap);
    map['$localLessonId'] = remoteId;
    await _writeMap(_kNoteMap, map);
  }

  Future<String?> getRemoteUnitId(int localLessonId) async {
    final map = await _readMap(_kUnitMap);
    return map['$localLessonId']?.toString();
  }

  Future<void> setRemoteUnitId(int localLessonId, String remoteId) async {
    final map = await _readMap(_kUnitMap);
    map['$localLessonId'] = remoteId;
    await _writeMap(_kUnitMap, map);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Teacher → cloud note upload
  //
  // The other half of the teacher→student bridge: a teacher uploading on one
  // device must reach a student on another. The local-first save already
  // happened; this pushes the same lesson to the backend so students who
  // joined the class sync it. The lesson text rides in the note's `description`
  // (an unlimited Text column the student sync already falls back to), and the
  // quiz is regenerated on each student's device — so no server-side AI
  // pipeline or file processing is required for content to flow end-to-end.
  // ───────────────────────────────────────────────────────────────────────────

  /// Pushes a teacher's saved lesson to the backend so students in the same
  /// class receive it on their own devices. Requires the teacher to be linked
  /// as a subject teacher (so there is a remote subject to file it under).
  /// Returns the remote note id, or `null` when the teacher isn't linked or
  /// anything fails — purely additive over the already-completed local save.
  ///
  /// When [questions] is provided, the same phone-generated quiz is also sent
  /// to the backend as unapproved review items, so the teacher can
  /// approve/edit them in the review screen — the cloud's quality gate over
  /// the on-device generator.
  Future<String?> uploadTeacherNote({
    required int localTeacherId,
    required int localLessonId,
    required String title,
    required String gradeLevel,
    required String lessonText,
    List<AiGeneratedQuestion> questions = const [],
  }) async {
    try {
      final link = await getTeacherLink(localTeacherId);
      if (link == null) return null;
      final subjectId = link.subjectId;
      if (subjectId == null || subjectId.isEmpty) return null;

      final token = await ensureTeacherToken(localTeacherId);
      if (token == null) return null;

      final note = await _api.createNote(
        baseUrl: link.baseUrl,
        accessToken: token,
        title: title.trim().isEmpty ? 'Lesson' : title.trim(),
        subjectId: subjectId,
        gradeLevel: gradeLevel.trim().isEmpty ? 'General' : gradeLevel.trim(),
        description: lessonText,
      );
      await setRemoteNoteId(localLessonId, note.id);

      if (questions.isNotEmpty) {
        try {
          await _api.pushNoteQuestions(
            baseUrl: link.baseUrl,
            accessToken: token,
            noteId: note.id,
            questions: [
              for (final q in questions)
                {
                  'question_text': q.questionText,
                  'options': [
                    {'text': q.optionA, 'is_correct': q.correctOption == 'A'},
                    {'text': q.optionB, 'is_correct': q.correctOption == 'B'},
                    {'text': q.optionC, 'is_correct': q.correctOption == 'C'},
                    if (q.optionD.trim().isNotEmpty)
                      {
                        'text': q.optionD,
                        'is_correct': q.correctOption == 'D'
                      },
                  ],
                  'explanation': q.explanation,
                },
            ],
          );
        } catch (_) {
          // The note itself made it up — losing the review copies of the
          // questions must not undo that. Students regenerate locally anyway.
        }
      }
      return note.id;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Student → cloud progress reporting
  // ───────────────────────────────────────────────────────────────────────────

  /// Reports that a student finished (or progressed through) a lesson, so the
  /// teacher's class dashboard reflects reality. Only works for cloud-synced
  /// lessons (a purely local lesson has no remote note to report against).
  /// Fire-and-forget: every failure is swallowed — progress reporting must
  /// never interrupt or slow the learning flow.
  Future<void> reportLessonProgress({
    required int localStudentId,
    required int localLessonId,
    required bool completed,
    double? completionPercentage,
    int positionSeconds = 0,
  }) async {
    try {
      final link = await getStudentLink(localStudentId);
      if (link == null) return;

      final noteId = await getRemoteNoteId(localLessonId);
      if (noteId == null) return;

      final token = await ensureStudentToken(localStudentId);
      if (token == null) return;

      await _api.postProgress(
        baseUrl: link.baseUrl,
        accessToken: token,
        noteId: noteId,
        lastPositionSeconds: positionSeconds,
        completed: completed,
        completionPercentage:
            completionPercentage ?? (completed ? 100.0 : null),
      );
    } catch (_) {
      // Non-blocking.
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Cloud → local content sync (students)
  //
  // The local SQLite database is per-device: a teacher's uploads never reach
  // a student's database on their own just because both apps "talk to the
  // same backend" — the student's gesture+voice UI only ever reads its own
  // local Subject/Topic/Lesson/Question rows. This is the other half of the
  // bridge: once a student is linked to a class, pull every `READY` note the
  // backend has for that class and materialise it as ordinary local rows, so
  // the existing UI "just works" regardless of which device the teacher
  // uploaded from. Already-synced notes are tracked by remote id and skipped
  // on subsequent calls — cheap to call often (e.g. every time the learning
  // hub opens), and silently a no-op when offline or nothing is new.
  // ───────────────────────────────────────────────────────────────────────────

  static const _kCloudTeacherId = 'cloud_placeholder_teacher_id';
  static const _kCloudNoteMap =
      'cloud_synced_notes'; // remote note id -> local lesson id
  static const _kCloudSubjectMap =
      'cloud_synced_subjects'; // "teacherId:subject" -> local subject id

  /// Finds or creates the single local placeholder [Teacher] row that owns
  /// every cloud-synced [Subject]. Required because [SubjectsTable.teacherId]
  /// is a foreign key and cloud content has no local teacher of its own — it
  /// is filed under one shared "Cloud Class" placeholder instead, which the
  /// student never has to know exists.
  Future<int> _ensureCloudPlaceholderTeacher(AppDatabase db) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_kCloudTeacherId);
    if (stored != null) {
      final existing = await db.teacherDao.getTeacherById(stored);
      if (existing != null) return existing.id;
    }

    final byMarker =
        await db.teacherDao.findTeacherBySubjectName('Cloud Class');
    if (byMarker != null) {
      await prefs.setInt(_kCloudTeacherId, byMarker.id);
      return byMarker.id;
    }

    final id = await db.teacherDao.insertTeacher(
      TeachersTableCompanion(
        name: const Value('Your Class'),
        pinHash: const Value(''),
        subjectName: const Value('Cloud Class'),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await prefs.setInt(_kCloudTeacherId, id);
    return id;
  }

  Future<int> _ensureCloudSubject({
    required AppDatabase db,
    required int placeholderTeacherId,
    required String subjectName,
  }) async {
    final name = subjectName.trim().isEmpty ? 'General' : subjectName.trim();
    final key = '$placeholderTeacherId:${name.toLowerCase()}';
    final map = await _readMap(_kCloudSubjectMap);

    final mappedId = int.tryParse(map[key]?.toString() ?? '');
    if (mappedId != null) {
      final existing = await db.subjectDao.getSubjectById(mappedId);
      if (existing != null) return existing.id;
    }

    // Recover from a lost mapping by matching on name among this
    // placeholder's own subjects before creating a duplicate.
    final subjects =
        await db.subjectDao.getSubjectsByTeacherId(placeholderTeacherId);
    for (final s in subjects) {
      if (s.name.toLowerCase() == name.toLowerCase()) {
        map[key] = s.id;
        await _writeMap(_kCloudSubjectMap, map);
        return s.id;
      }
    }

    final id = await db.subjectDao.insertSubject(
      SubjectsTableCompanion(
        teacherId: Value(placeholderTeacherId),
        name: Value(name),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    map[key] = id;
    await _writeMap(_kCloudSubjectMap, map);
    return id;
  }

  /// Pulls every `READY` note the linked student's class has on the backend
  /// and turns new ones into local Subject → Topic → Lesson → Question rows
  /// (MCQ artefacts only, marked `source: 'cloud'`). Returns how many new
  /// lessons were added, so the caller can decide whether to refresh the UI
  /// or announce "new lessons available" — zero always means "nothing to do",
  /// never an error, since every failure path is swallowed silently.
  Future<int> syncCloudContentForStudent({
    required int localStudentId,
    required AppDatabase db,
  }) async {
    final link = await getStudentLink(localStudentId);
    if (link == null) return 0;

    final token = await ensureStudentToken(localStudentId);
    if (token == null) return 0;

    try {
      final notes =
          await _api.listNotes(baseUrl: link.baseUrl, accessToken: token);
      if (notes.isEmpty) return 0;

      final syncedMap = await _readMap(_kCloudNoteMap);
      final placeholderTeacherId = await _ensureCloudPlaceholderTeacher(db);
      var added = 0;
      var createdAtCursor = DateTime.now().millisecondsSinceEpoch;

      for (final note in notes) {
        if (!note.isReady) continue;
        if (syncedMap.containsKey(note.id)) continue;

        final subjectId = await _ensureCloudSubject(
          db: db,
          placeholderTeacherId: placeholderTeacherId,
          subjectName: note.subject,
        );

        final existingTopics =
            await db.topicDao.getTopicsBySubjectId(subjectId);
        Topic? topic;
        for (final t in existingTopics) {
          if (t.name.toLowerCase() == note.title.trim().toLowerCase()) {
            topic = t;
            break;
          }
        }
        if (topic == null) {
          final topicId = await db.topicDao.insertTopic(
            TopicsTableCompanion(
              subjectId: Value(subjectId),
              name: Value(
                  note.title.trim().isEmpty ? 'Lesson' : note.title.trim()),
              orderIndex: Value(existingTopics.length),
              createdAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
          topic = await db.topicDao.getTopicById(topicId);
        }
        if (topic == null) continue;

        List<BackendUnit> units;
        try {
          units = await _api.getUnits(
            baseUrl: link.baseUrl,
            accessToken: token,
            noteId: note.id,
          );
        } catch (_) {
          units = const [];
        }

        final lessonText = units.isEmpty
            ? (note.description?.trim().isNotEmpty == true
                ? note.description!.trim()
                : note.title.trim())
            : units
                .map((u) => u.contentText.trim())
                .where((t) => t.isNotEmpty)
                .join('\n\n');
        if (lessonText.trim().isEmpty) continue;

        final lessonId = await db.lessonDao.insertLesson(
          LessonsTableCompanion(
            topicId: Value(topic.id),
            rawText: Value(lessonText.trim()),
            createdAt: Value(createdAtCursor++),
          ),
        );

        // Remember the remote note (and its first unit) so voice sessions for
        // this lesson can be started later — the `/api/v1/voice/session/*`
        // routes key on note_id + unit_id, neither of which exist locally.
        await setRemoteNoteId(lessonId, note.id);
        if (units.isNotEmpty) {
          await setRemoteUnitId(lessonId, units.first.id);
        }

        const letters = ['A', 'B', 'C', 'D'];
        var position = 0;
        // Fetch every unit's artefacts in parallel instead of one-by-one —
        // on a high-latency mobile connection the sequential version made a
        // 10-unit lesson take 10× a single round-trip before it appeared.
        final artefactsPerUnit = await Future.wait(
          units.map((unit) async {
            try {
              return await _api.getArtefacts(
                baseUrl: link.baseUrl,
                accessToken: token,
                noteId: note.id,
                unitId: unit.id,
              );
            } catch (_) {
              return const <BackendArtefact>[];
            }
          }),
        );
        for (final artefacts in artefactsPerUnit) {
          for (final artefact in artefacts) {
            if (!artefact.isMultipleChoice || artefact.options.length < 2) {
              continue;
            }
            String? optionAt(int i) =>
                i < artefact.options.length ? artefact.options[i].text : null;
            final correctIndex =
                artefact.options.indexWhere((o) => o.isCorrect);

            await db.questionDao.insertQuestion(
              QuestionsTableCompanion(
                lessonId: Value(lessonId),
                questionText: Value(artefact.questionText),
                optionA: Value(optionAt(0) ?? ''),
                optionB: Value(optionAt(1) ?? ''),
                optionC: Value(optionAt(2) ?? ''),
                optionD: Value(optionAt(3)),
                correctOption: Value(
                  correctIndex >= 0 && correctIndex < letters.length
                      ? letters[correctIndex]
                      : 'A',
                ),
                explanation: Value(artefact.explanation),
                positionInLesson: Value(position++),
                source: const Value('cloud'),
              ),
            );
          }
        }

        // Notes whose text rode in via the description (no cloud AI pipeline)
        // arrive without quiz artefacts. Regenerate the quiz locally from the
        // lesson text using the same offline generator teachers use, so every
        // cloud lesson still comes with questions.
        if (position == 0) {
          for (final q in AiQuestionService().generateQuestions(lessonText)) {
            await db.questionDao.insertQuestion(
              QuestionsTableCompanion(
                lessonId: Value(lessonId),
                questionText: Value(q.questionText),
                optionA: Value(q.optionA),
                optionB: Value(q.optionB),
                optionC: Value(q.optionC),
                optionD: Value(q.optionD),
                correctOption: Value(q.correctOption),
                explanation: Value(q.explanation),
                positionInLesson: Value(position++),
                source: const Value('cloud'),
              ),
            );
          }
        }

        syncedMap[note.id] = lessonId;
        added += 1;
      }

      if (added > 0) {
        await _writeMap(_kCloudNoteMap, syncedMap);
      }
      return added;
    } on BackendApiException catch (_) {
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Voice interaction sessions
  //
  // Thin wrappers around BackendApiService's voice/session/* calls that
  // resolve everything a screen would otherwise need to look up itself: the
  // student's link/token and the remote note/unit ids for a local lesson.
  // Every method swallows its own errors and returns null/void on failure so
  // a flaky connection or an unsynced (local-only) lesson never interrupts
  // the learning flow — voice session logging is purely additive analytics.
  // ───────────────────────────────────────────────────────────────────────────

  /// Starts a voice session for [localLessonId] if (and only if) it is a
  /// cloud-synced lesson with known remote note/unit ids and the student is
  /// linked to a class. Returns the backend session id, or `null` if a
  /// session could not be started for any reason.
  Future<String?> startVoiceSessionForLesson({
    required int localStudentId,
    required int localLessonId,
  }) async {
    try {
      final link = await getStudentLink(localStudentId);
      if (link == null) return null;

      final token = await ensureStudentToken(localStudentId);
      if (token == null) return null;

      final noteId = await getRemoteNoteId(localLessonId);
      final unitId = await getRemoteUnitId(localLessonId);
      if (noteId == null || unitId == null) return null;

      final session = await _api.startVoiceSession(
        baseUrl: link.baseUrl,
        accessToken: token,
        studentId: link.remoteStudentId,
        noteId: noteId,
        unitId: unitId,
      );
      return session.sessionId;
    } catch (_) {
      return null;
    }
  }

  /// Logs one spoken/gestural interaction against an active voice session.
  /// Failures are swallowed — this is fire-and-forget analytics.
  Future<void> logVoiceEvent({
    required int localStudentId,
    required String sessionId,
    required String interactionType,
    required String command,
    required String response,
    double confidence = 0.9,
  }) async {
    try {
      final link = await getStudentLink(localStudentId);
      if (link == null) return;

      final token = await ensureStudentToken(localStudentId);
      if (token == null) return;

      await _api.sendVoiceEvent(
        baseUrl: link.baseUrl,
        accessToken: token,
        sessionId: sessionId,
        interactionType: interactionType,
        command: command,
        response: response,
        confidence: confidence,
      );
    } catch (_) {
      // Non-blocking — never interrupts playback for the student.
    }
  }

  /// Closes a voice session previously opened with [startVoiceSessionForLesson].
  /// Failures are swallowed.
  Future<void> endVoiceSessionForLesson({
    required int localStudentId,
    required String sessionId,
    required int durationSeconds,
    required int questionsAnswered,
    required double totalScore,
  }) async {
    try {
      final link = await getStudentLink(localStudentId);
      if (link == null) return;

      final token = await ensureStudentToken(localStudentId);
      if (token == null) return;

      await _api.endVoiceSession(
        baseUrl: link.baseUrl,
        accessToken: token,
        sessionId: sessionId,
        durationSeconds: durationSeconds,
        questionsAnswered: questionsAnswered,
        totalScore: totalScore,
      );
    } catch (_) {
      // Non-blocking.
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Credential generation helpers (students only — teachers supply their own)
  // ───────────────────────────────────────────────────────────────────────────

  static final Random _random = Random.secure();

  /// `student<id>-<6 random alphanumerics>@device.visiolearn.app` — unique, never
  /// shown to the student, exists purely so the backend has an email to key on.
  String _generateStudentEmail(int localStudentId) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix =
        List.generate(6, (_) => chars[_random.nextInt(chars.length)]).join();
    return 'student$localStudentId-$suffix@device.visiolearn.app';
  }

  /// Meets the backend's password policy (8+ chars, upper, lower, digit,
  /// special) by construction, then shuffles so the structure isn't guessable.
  String _generateStrongPassword() {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnpqrstuvwxyz';
    const digits = '23456789';
    const special = '!@#%^&*';

    String pick(String pool, int n) =>
        List.generate(n, (_) => pool[_random.nextInt(pool.length)]).join();

    final chars = [
      ...pick(upper, 3).split(''),
      ...pick(lower, 5).split(''),
      ...pick(digits, 3).split(''),
      ...pick(special, 2).split(''),
    ];
    chars.shuffle(_random);
    return chars.join();
  }
}
