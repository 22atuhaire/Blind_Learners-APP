import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../shared/services/providers.dart';

/// Class-teacher view of every student's completion across every subject in the
/// class. Reads the backend's /api/v1/classes/{id}/matrix endpoint. This is the
/// payoff of the class code: pupils who joined with it show up here with their
/// progress.
class TeacherClassProgressScreen extends ConsumerStatefulWidget {
  const TeacherClassProgressScreen({super.key});

  @override
  ConsumerState<TeacherClassProgressScreen> createState() =>
      _TeacherClassProgressScreenState();
}

class _TeacherClassProgressScreenState
    extends ConsumerState<TeacherClassProgressScreen> {
  bool _loading = true;
  String? _error;
  String _className = '';
  List<Map<String, dynamic>> _subjects = [];
  List<Map<String, dynamic>> _students = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final teacher = ref.read(currentTeacherProvider);
      if (teacher == null) throw Exception('Please sign in as a teacher first.');

      final link = ref.read(backendLinkServiceProvider);
      final teacherLink = await link.getTeacherLink(teacher.id);
      final token = await link.ensureTeacherToken(teacher.id);

      if (teacherLink == null || token == null || teacherLink.classId == null) {
        throw Exception(
          'No class found for your account. Only a class teacher with a '
          'published class can see student progress here.',
        );
      }

      final res = await http.get(
        Uri.parse(
            '${teacherLink.baseUrl}/api/v1/classes/${teacherLink.classId}/matrix'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 30));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Could not load progress (${res.statusCode}).');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        _className = data['class_name']?.toString() ?? 'Class';
        _subjects = ((data['subjects'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _students = ((data['students'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  int _completion(Map<String, dynamic> student, String subjectId) {
    final byId = student['progress_by_subject'];
    if (byId is! Map) return 0;
    final entry = byId[subjectId];
    if (entry is! Map) return 0;
    final pct = entry['completion_percentage'];
    if (pct is num) return pct.round();
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_loading ? 'Class progress' : '$_className progress'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _students.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No students have joined this class yet. Share your '
                          'student code so pupils can join.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              const DataColumn(label: Text('Student')),
                              for (final s in _subjects)
                                DataColumn(
                                    label: Text(s['name']?.toString() ?? '')),
                            ],
                            rows: [
                              for (final st in _students)
                                DataRow(cells: [
                                  DataCell(Text(
                                      st['full_name']?.toString() ??
                                          st['email']?.toString() ??
                                          'Student')),
                                  for (final s in _subjects)
                                    DataCell(Text(
                                        '${_completion(st, s['id']?.toString() ?? '')}%')),
                                ]),
                            ],
                          ),
                        ),
                      ),
                    ),
    );
  }
}
