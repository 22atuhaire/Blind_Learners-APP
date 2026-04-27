import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';

void main() {
  runApp(
    const ProviderScope(
      child: AudioApp(),
    ),
  );
}

class AudioApp extends ConsumerWidget {
  const AudioApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Audio Learning Platform',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A56DB),
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
