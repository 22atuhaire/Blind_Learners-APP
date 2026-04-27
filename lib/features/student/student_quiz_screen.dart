import 'package:flutter/material.dart';

class StudentQuizScreen extends StatelessWidget {
  final String lessonId;

  const StudentQuizScreen({super.key, required this.lessonId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      body: Center(
        child: Text(
          'Student Quiz Screen\nlesson: $lessonId',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A56DB),
          ),
        ),
      ),
    );
  }
}
