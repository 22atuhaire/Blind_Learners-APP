# VisioLearn — Audio Learning App (`audioapp`)

A **voice-first, gesture-driven** mobile learning app for **visually impaired students in Ugandan schools**. The app is **offline-first**: everything a student needs to learn lives in a local database and works with no network. An optional cloud bridge lets teachers' uploaded notes flow in when a connection is available.

This is the Flutter client. The server lives in [`../VisioLearn-Backend`](../VisioLearn-Backend).

## Who uses it

- **Students** navigate entirely by **voice and touch gestures** — no reading required. They move through Subjects → Topics → Lesson audio → Quiz, all spoken aloud.
- **Teachers** sign in with a PIN, create subjects/topics, upload lesson notes (PDF / Word / text), and the app auto-generates quiz questions offline.

## How students interact

Every screen announces itself, then opens a short listening window. Voice is primary; gestures are an always-available fallback.

| Context | Gesture | Voice |
| --- | --- | --- |
| Subjects / Topics | swipe → next, swipe ← previous, double-tap open | "next", "previous", "open" |
| Lesson | double-tap play/pause, swipe ↑ replay, swipe ↓ quiz, **hold = slower** | "play", "pause", "repeat", "quiz", "slower" / "faster" |
| Quiz | swipe ←/→ change answer, double-tap select | "answer two", "option three", or just "three" |
| Anywhere | — | "home", "repeat" |

Reading speed is adjustable in six steps and **persists across restarts**.

## Architecture

- **State / DI:** [Riverpod](https://riverpod.dev) — all services and queries are providers ([`lib/shared/services/providers.dart`](lib/shared/services/providers.dart)).
- **Local database:** [Drift](https://drift.simonbinder.eu) over SQLite ([`lib/shared/services/db/app_database.dart`](lib/shared/services/db/app_database.dart)) — Teachers, Students, Subjects, Topics, Lessons, Questions, Progress, QuizResults.
- **Routing:** `go_router` ([`lib/app/router.dart`](lib/app/router.dart)).
- **Audio:** `flutter_tts` (text-to-speech) + `speech_to_text` (recognition), wrapped in [`TtsService`](lib/shared/services/tts_service.dart) / [`SttService`](lib/shared/services/stt_service.dart).
- **Offline content:** [`FileExtractionService`](lib/shared/services/file_extraction_service.dart) pulls text from PDF/DOCX/TXT; [`AiQuestionService`](lib/shared/services/ai_question_service.dart) generates MCQs from that text deterministically (no network, no ML model).
- **Cloud bridge (optional):** [`BackendApiService`](lib/shared/services/backend_api_service.dart) + [`BackendLinkService`](lib/shared/services/backend_link_service.dart) hide the backend's `class_teacher → subject_teacher → student` hierarchy behind one spoken "join your class" flow (students only speak their name and a class code). All cloud paths fail silently so a flaky connection never blocks the local-first flow.

```text
lib/
  app/router.dart                 # routes
  features/
    auth/                         # splash, role selection, student/teacher PIN
    student/student_learning_hub_screen.dart   # the voice/gesture learning loop
    teacher/                      # dashboard, subject, upload, questions
  shared/services/                # tts, stt, pin, backend, ai, extraction, db
```

## Running

Requires the Flutter SDK (`>=3.0.0 <4.0.0`).

```bash
flutter pub get
flutter run                       # on a connected Android device/emulator
```

If you change any Drift table or DAO, regenerate the database code:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Tests

Pure-Dart unit tests for the offline services (no device needed):

```bash
flutter test
flutter analyze
```

## Backend

The cloud features target the VisioLearn FastAPI backend (default `https://visiolearn-backend.onrender.com`, configurable in [`backend_api_service.dart`](lib/shared/services/backend_api_service.dart)). It is hosted on a free tier that cold-starts after idle, so the app warms it up early and caps every sync. See [`../VisioLearn-Backend/README.md`](../VisioLearn-Backend/README.md).
