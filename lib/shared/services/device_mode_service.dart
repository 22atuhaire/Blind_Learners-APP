import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether this install runs on a student's **personal** phone or a
/// **shared** school phone.
///
/// Why this exists: a blind student on their own phone should never be asked
/// for a PIN — it is pure friction with no benefit, since the device has one
/// owner. On a shared school phone (e.g. a few handsets among many pupils) a
/// PIN is what keeps each student's progress separate. One stored choice lets
/// the login flow do the right thing automatically on every launch.
///
/// The value is set once (by voice, or by tapping a button with a teacher's
/// help) and then read silently forever after.
class DeviceModeService {
  static const String _key = 'device_mode';

  /// Personal phone: no PIN gate, straight into learning.
  static const String personal = 'personal';

  /// Shared school phone: keep the spoken-PIN gate so pupils stay separate.
  static const String shared = 'shared';

  /// Returns the saved mode (`'personal'` / `'shared'`), or `null` when the
  /// choice has not been made yet.
  Future<String?> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  /// Persists the chosen [mode]. Pass [personal] or [shared].
  Future<void> setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode);
  }

  /// Convenience: `true` only when the mode is explicitly personal.
  Future<bool> isPersonal() async => (await getMode()) == personal;
}
