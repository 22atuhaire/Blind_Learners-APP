import 'dart:convert';

import 'package:http/http.dart' as http;

/// One option of a question under review.
class ReviewOption {
  ReviewOption({required this.text, required this.isCorrect});

  String text;
  bool isCorrect;

  factory ReviewOption.fromJson(Map<String, dynamic> j) => ReviewOption(
        text: j['text']?.toString() ?? '',
        isCorrect: j['is_correct'] == true,
      );

  Map<String, dynamic> toJson() => {'text': text, 'is_correct': isCorrect};
}

/// One server-generated MCQ a teacher is reviewing before students see it.
class ReviewQuestion {
  ReviewQuestion({
    required this.id,
    required this.questionText,
    required this.options,
    required this.explanation,
    required this.approved,
  });

  final String id;
  String questionText;
  List<ReviewOption> options;
  String explanation;
  bool approved;

  factory ReviewQuestion.fromJson(Map<String, dynamic> j) => ReviewQuestion(
        id: j['id'].toString(),
        questionText: j['question_text']?.toString() ?? '',
        options: ((j['options'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ReviewOption.fromJson)
            .toList(),
        explanation: j['explanation']?.toString() ?? '',
        approved: j['approved'] == true,
      );
}

/// Talks to the backend's teacher question-review endpoints. Self-contained
/// (uses `http` directly) so it stays decoupled from the large API service.
class TeacherReviewService {
  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  bool _ok(int code) => code >= 200 && code < 300;

  /// Lists every MCQ in [noteId] (approved and not) for review.
  Future<List<ReviewQuestion>> listQuestions({
    required String baseUrl,
    required String token,
    required String noteId,
  }) async {
    final res = await http
        .get(
          Uri.parse('$baseUrl/api/v1/notes/$noteId/questions'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) {
      throw Exception('Could not load questions (${res.statusCode}).');
    }
    final data = jsonDecode(res.body);
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(ReviewQuestion.fromJson)
        .toList();
  }

  /// Approves (or un-approves) one question.
  Future<void> setApproved({
    required String baseUrl,
    required String token,
    required String id,
    bool approved = true,
  }) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/v1/questions/$id/approve'),
          headers: _headers(token),
          body: jsonEncode({'approved': approved}),
        )
        .timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) {
      throw Exception('Approve failed (${res.statusCode}).');
    }
  }

  /// Saves edited wording / options / explanation.
  Future<void> updateQuestion({
    required String baseUrl,
    required String token,
    required String id,
    required String questionText,
    required List<ReviewOption> options,
    required String explanation,
  }) async {
    final res = await http
        .patch(
          Uri.parse('$baseUrl/api/v1/questions/$id'),
          headers: _headers(token),
          body: jsonEncode({
            'question_text': questionText,
            'options': options.map((o) => o.toJson()).toList(),
            'explanation': explanation,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) {
      throw Exception('Update failed (${res.statusCode}).');
    }
  }

  /// Deletes a bad question.
  Future<void> deleteQuestion({
    required String baseUrl,
    required String token,
    required String id,
  }) async {
    final res = await http
        .delete(
          Uri.parse('$baseUrl/api/v1/questions/$id'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) {
      throw Exception('Delete failed (${res.statusCode}).');
    }
  }
}
