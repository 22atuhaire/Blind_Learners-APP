import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Simple PIN storage with salted SHA-256 hashing stored in secure storage.
///
/// Notes: for a production system prefer a well-audited password/hash
/// library (PBKDF2/Argon2) — this implementation is intentionally small for
/// the demo app and uses multiple SHA-256 iterations to slow down brute force.
class PinAuthService {
  static const _storageKey = 'student_pin_hash';
  final FlutterSecureStorage _secureStorage;
  final int _iterations;

  PinAuthService({FlutterSecureStorage? secureStorage, int iterations = 10000})
      : _secureStorage = secureStorage ?? FlutterSecureStorage(),
        _iterations = iterations;

  Future<bool> hasPin() async {
    final v = await _secureStorage.read(key: _storageKey);
    return v != null && v.isNotEmpty;
  }

  Future<void> clearPin() async => _secureStorage.delete(key: _storageKey);

  Future<void> savePin(String pin) async {
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt, _iterations);
    final payload = jsonEncode({'salt': salt, 'hash': hash, 'iters': _iterations});
    await _secureStorage.write(key: _storageKey, value: payload);
  }

  Future<bool> verifyPin(String pin) async {
    final raw = await _secureStorage.read(key: _storageKey);
    if (raw == null) return false;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final salt = data['salt'] as String;
      final stored = data['hash'] as String;
      final iters = (data['iters'] as int?) ?? _iterations;
      final computed = _hashPin(pin, salt, iters);
      return constantTimeEquality(stored, computed);
    } catch (e) {
      debugPrint('PinAuthService.verifyPin: decode error $e');
      return false;
    }
  }

  // Lightweight salt generator.
  String _generateSalt([int len = 16]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(len, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }

  // Iterated SHA-256: start with salt+pin and hash repeatedly.
  String _hashPin(String pin, String salt, int iterations) {
    var bytes = utf8.encode(salt + pin);
    Digest digest = sha256.convert(bytes);
    for (var i = 1; i < iterations; i++) {
      // feed previous digest bytes back into the hash
      digest = sha256.convert(digest.bytes);
    }
    return base64UrlEncode(digest.bytes);
  }

  // Prevent timing attacks by comparing in constant time.
  bool constantTimeEquality(String a, String b) {
    if (a.length != b.length) return false;
    var res = 0;
    for (var i = 0; i < a.length; i++) {
      res |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return res == 0;
  }
}
