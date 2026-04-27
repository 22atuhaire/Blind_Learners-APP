import 'package:flutter/material.dart';

class StudentStudyScreen extends StatelessWidget {
  final String topicId;
  const StudentStudyScreen({super.key, required this.topicId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEBF2FF),
        title: const Text('Study'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.menu_book_rounded,
              size: 64,
              color: Color(0xFF1A56DB),
            ),
            const SizedBox(height: 16),
            const Text(
              'Student Study Screen',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A56DB),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Topic ID: $topicId',
              style: const TextStyle(
                fontSize: 16,
                color: Color(0xFF4A5568),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
