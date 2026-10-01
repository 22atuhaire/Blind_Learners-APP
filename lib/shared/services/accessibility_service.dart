import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Screen-reader awareness for AudioLearner.
///
/// ## Why this exists
///
/// This app was built voice-first: it speaks with its own TTS engine and is
/// driven by custom gestures (swipe, double-tap, long-press, two-finger tap).
/// That design assumes the app owns the screen.
///
/// A blind student does not switch TalkBack on to use one app — TalkBack is
/// already on, permanently, because it is how they use the phone at all. And
/// TalkBack takes over touch input: it consumes swipes for its own
/// element-to-element navigation and turns a double-tap into "activate the
/// focused item". Our gesture handlers then never fire, while TalkBack's voice
/// talks over our TTS. Two voices, no working gestures — worst for exactly the
/// student the app is for.
///
/// So the app runs in one of two modes, decided by the platform:
///
/// * **Screen-reader mode** — TalkBack (or VoiceOver) is driving. We stay
///   quiet for interface chrome and let TalkBack read properly labelled
///   controls, we stop the always-on microphone loop, and every action is
///   reachable as a real focusable button. We still speak *lesson and quiz
///   content*, because reading a whole lesson aloud with pacing, speed control
///   and resume is the product — TalkBack would only read what is focused.
///
/// * **Voice-first mode** — no screen reader. The original spoken loop and
///   gesture set take over, unchanged.
///
/// Nothing here asks the student to change their phone settings. The app
/// adapts to them, which is the whole point.
class AccessibilityMode {
  const AccessibilityMode({required this.screenReaderEnabled});

  /// True when TalkBack, VoiceOver or another assistive reader is active.
  final bool screenReaderEnabled;

  /// The app should speak its own interface announcements (screen names,
  /// instructions, prompts). False under a screen reader, which announces
  /// focused widgets itself — doubling it up produces overlapping speech.
  bool get shouldSpeakChrome => !screenReaderEnabled;

  /// The app should keep the microphone open listening for commands.
  ///
  /// Disabled under a screen reader: TalkBack speaks constantly as the student
  /// explores by touch, the microphone hears it, and the recogniser feeds the
  /// app its own interface as commands. The explicit "Ask a question" control
  /// still opens the microphone on demand.
  bool get shouldAutoListen => !screenReaderEnabled;

  /// Show the on-screen control panel of real, labelled buttons.
  ///
  /// Always available to sighted helpers, but essential under a screen reader,
  /// where the custom gestures cannot be relied on.
  bool get needsExplicitControls => screenReaderEnabled;

  /// Lesson and quiz *content* is spoken in both modes — it is the product.
  bool get shouldSpeakContent => true;

  static AccessibilityMode of(BuildContext context) => AccessibilityMode(
        screenReaderEnabled: MediaQuery.maybeOf(context)?.accessibleNavigation ??
            false,
      );

  /// Reads the flag without a [BuildContext] — usable from initState or a
  /// service. Prefer [of] inside build methods so the UI rebuilds when the
  /// student toggles TalkBack mid-session.
  static bool get isScreenReaderActive =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
          .accessibleNavigation;

  /// Speaks [message] through the screen reader without moving focus.
  ///
  /// Used for events that have no widget to focus — "Correct", "Question 3 of
  /// 5", "4 new lessons ready". Without this a TalkBack user gets silence at
  /// exactly the moments that matter, because nothing they touched changed.
  static void announce(String message, {bool assertive = true}) {
    if (message.trim().isEmpty) return;
    // `SemanticsService.announce` is deprecated in favour of
    // `sendAnnouncement`, which takes a view so it can support multiple
    // windows. This app is single-window Android, the deprecated call still
    // works, and it is the API supported across the Flutter versions the
    // team builds with — so it is kept deliberately rather than churned.
    //
    // To migrate: check the signature in your SDK with
    //   flutter doctor -v              (find the SDK path)
    //   grep -n "sendAnnouncement" <sdk>/packages/flutter/lib/src/semantics/semantics_service.dart
    // then swap the call below. Behaviour is otherwise identical.
    // ignore: deprecated_member_use
    SemanticsService.announce(
      message,
      TextDirection.ltr,
      assertiveness: assertive ? Assertiveness.assertive : Assertiveness.polite,
    );
  }
}

/// A large, clearly labelled action button for the accessible control panel.
///
/// Minimum 56dp of height and a real [Semantics] button role, so TalkBack
/// announces "<label>, button" and activates it with the standard double-tap
/// its users already know — no app-specific gesture to learn.
class AccessibleActionButton extends StatelessWidget {
  const AccessibleActionButton({
    super.key,
    required this.label,
    required this.hint,
    required this.icon,
    required this.onPressed,
    this.background = const Color(0xFF032A5F),
    this.foreground = Colors.white,
  });

  final String label;

  /// Spoken after the label to explain the outcome ("plays the next topic").
  final String hint;
  final IconData icon;
  final VoidCallback onPressed;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      hint: hint,
      child: ExcludeSemantics(
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Container(
              constraints: const BoxConstraints(minHeight: 56, minWidth: 96),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: foreground, size: 22),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
