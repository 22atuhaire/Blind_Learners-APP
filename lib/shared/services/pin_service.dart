import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Handles all PIN-related operations for the AudioApp platform.
///
/// PINs are always 4 digits. They are never stored in plain text — only their
/// salted SHA-256 digest is persisted (in [TeachersTable.pinHash] or
/// [StudentsTable.pinHash]).
///
/// Usage:
/// ```
/// final service = PinService();
///
/// // On registration:
/// final hash = service.hashPin('1234');
/// await db.teacherDao.insertTeacher(TeachersTableCompanion(pinHash: Value(hash), ...));
///
/// // On login:
/// final ok = service.verifyPin(enteredPin, teacher.pinHash);
/// ```
class PinService {
  // ──────────────────────────────────────────────────────────────────────────
  // Constants
  // ──────────────────────────────────────────────────────────────────────────

  /// App-level salt prepended to every PIN before hashing.
  ///
  /// Changing this value will invalidate all stored hashes — do not alter it
  /// after the app ships.
  static const String _salt = 'audioapp_uganda_2026';

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Returns the salted SHA-256 hex digest of [pin].
  ///
  /// The raw value stored in the database is:
  ///   `sha256("audioapp_uganda_2026:<pin>")`
  ///
  /// [pin] should be a 4-digit string, but this method does not validate it —
  /// call [isValidPin] first if you need that guarantee.
  String hashPin(String pin) {
    final salted = '$_salt:$pin';
    final bytes = utf8.encode(salted);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Returns `true` when [rawPin] hashes to the same digest as [storedHash].
  ///
  /// Use this during login to compare what the user typed against what is
  /// persisted in the database.
  ///
  /// Example:
  /// ```
  /// if (!pinService.verifyPin(enteredPin, teacher.pinHash)) {
  ///   // wrong PIN — reject the login attempt
  /// }
  /// ```
  bool verifyPin(String rawPin, String storedHash) {
    return hashPin(rawPin) == storedHash;
  }

  /// Returns `true` when [pin] is a string of exactly four ASCII digits.
  ///
  /// Validates before hashing or persisting so that the app never stores a
  /// hash of a malformed PIN.
  ///
  /// Valid:   `'0000'`, `'1234'`, `'9999'`
  /// Invalid: `''`, `'123'`, `'12345'`, `'ab12'`, `' 123'`
  bool isValidPin(String pin) {
    return RegExp(r'^\d{4}$').hasMatch(pin);
  }
}
