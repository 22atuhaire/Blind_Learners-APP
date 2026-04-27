import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Value;
import 'package:audioapp/shared/services/providers.dart';
import 'package:audioapp/shared/services/db/app_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Teacher Subject Screen
// ─────────────────────────────────────────────────────────────────────────────

class TeacherSubjectScreen extends ConsumerStatefulWidget {
  final String subjectId;
  const TeacherSubjectScreen({super.key, required this.subjectId});

  @override
  ConsumerState<TeacherSubjectScreen> createState() =>
      _TeacherSubjectScreenState();
}

class _TeacherSubjectScreenState extends ConsumerState<TeacherSubjectScreen> {
  // Parsed once and reused across methods.
  int get _subjectId => int.parse(widget.subjectId);

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topicsAsync = ref.watch(subjectTopicsProvider(_subjectId));

    return Scaffold(
      backgroundColor: const Color(0xFFEBF2FF),
      appBar: AppBar(
        title: const Text('Topics'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to dashboard',
          onPressed: () => context.go('/teacher/dashboard'),
        ),
      ),
      body: topicsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(
          child: Text(
            'Could not load topics',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
        data: (topics) {
          if (topics.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(
                    Icons.list_alt_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No topics yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Tap + to add your first topic',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: topics.length,
            itemBuilder: (context, index) {
              return _TopicTile(
                topic: topics[index],
                onDelete: () => _confirmDeleteTopic(topics[index]),
                onNavigateToQuestions: (lessonId) => context.goNamed(
                  'teacherQuestions',
                  pathParameters: {'lessonId': lessonId.toString()},
                ),
                onNavigateToUpload: (topicId) => context.goNamed(
                  'teacherUpload',
                  pathParameters: {'topicId': topicId.toString()},
                ),
              );
            },
          );
        },
      ),

      // ── FAB ───────────────────────────────────────────────────────────────
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Topic'),
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        elevation: 3,
        onPressed: () => _showAddTopicDialog(_subjectId),
      ),
    );
  }

  // ── Add Topic Dialog ───────────────────────────────────────────────────────

  void _showAddTopicDialog(int subjectId) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Topic'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Topic name',
            hintText: 'e.g. Chapter 3: Cell Structure',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A56DB),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              final db = ref.read(appDatabaseProvider);
              final topics = await db.topicDao.getTopicsBySubjectId(subjectId);

              await db.topicDao.insertTopic(
                TopicsTableCompanion(
                  subjectId: Value(subjectId),
                  name: Value(name),
                  orderIndex: Value(topics.length),
                  createdAt: Value(DateTime.now().millisecondsSinceEpoch),
                ),
              );

              ref.invalidate(subjectTopicsProvider(subjectId));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  // ── Confirm Delete Topic Dialog ────────────────────────────────────────────

  void _confirmDeleteTopic(Topic topic) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Topic'),
        content: Text(
          "Delete topic '${topic.name}'? "
          "This will also remove uploaded notes and questions.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final db = ref.read(appDatabaseProvider);
              await db.topicDao.deleteTopic(topic.id);
              ref.invalidate(subjectTopicsProvider(_subjectId));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Topic Tile Widget
// Uses a FutureBuilder to check whether the topic already has a lesson,
// then renders the appropriate icon, subtitle, and tap destination.
// ─────────────────────────────────────────────────────────────────────────────

class _TopicTile extends StatelessWidget {
  final Topic topic;
  final VoidCallback onDelete;
  final void Function(int lessonId) onNavigateToQuestions;
  final void Function(int topicId) onNavigateToUpload;

  const _TopicTile({
    required this.topic,
    required this.onDelete,
    required this.onNavigateToQuestions,
    required this.onNavigateToUpload,
  });

  @override
  Widget build(BuildContext context) {
    // We intentionally use a ProviderContainer-free approach here:
    // the FutureBuilder reads the db singleton directly so it does not
    // couple this stateless widget to Riverpod.
    return FutureBuilder<List<Lesson>>(
      future: _fetchLessons(context),
      builder: (context, snapshot) {
        final hasLesson = (snapshot.data ?? []).isNotEmpty;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            // ── Leading icon container ──────────────────────────────────
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: hasLesson
                    ? const Color(0xFF16A34A).withOpacity(0.1)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                hasLesson
                    ? Icons.check_circle_outline_rounded
                    : Icons.upload_file_rounded,
                color: hasLesson ? const Color(0xFF16A34A) : Colors.grey,
              ),
            ),
            // ── Title ───────────────────────────────────────────────────
            title: Text(
              topic.name,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            // ── Subtitle ────────────────────────────────────────────────
            subtitle: Text(
              hasLesson
                  ? 'Notes uploaded — tap to manage questions'
                  : 'No notes yet — tap to upload',
              style: TextStyle(
                fontSize: 13,
                color:
                    hasLesson ? const Color(0xFF16A34A) : Colors.grey.shade600,
              ),
            ),
            // ── Delete button ────────────────────────────────────────────
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
              tooltip: 'Delete topic',
              onPressed: onDelete,
            ),
            // ── Tap target ───────────────────────────────────────────────
            onTap: () {
              if (hasLesson) {
                onNavigateToQuestions(snapshot.data!.first.id);
              } else {
                onNavigateToUpload(topic.id);
              }
            },
          ),
        );
      },
    );
  }

  /// Fetches lessons for this topic.  We reach the db via the provider
  /// inherited widget from Riverpod's [ProviderScope] in the tree.
  Future<List<Lesson>> _fetchLessons(BuildContext context) {
    // Traverse the widget tree to find the nearest ProviderScope and read
    // the appDatabaseProvider without making this widget a ConsumerWidget.
    final container = ProviderScope.containerOf(context, listen: false);
    return container
        .read(appDatabaseProvider)
        .lessonDao
        .getLessonsByTopicId(topic.id);
  }
}
