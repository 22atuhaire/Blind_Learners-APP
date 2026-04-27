import 'package:flutter/material.dart';

class StudentPinScreen extends StatelessWidget {
  const StudentPinScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFEBF2FF),
      body: Center(
        child: Text(
          'Student Pin Screen',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A56DB),
          ),
        ),
      ),
    );
  }
}
