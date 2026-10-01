import 'package:audioapp/shared/services/pin_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [PinService] — pure Dart (SHA-256), no platform channels,
/// so they run under `flutter test` with no device or mocks.
void main() {
  late PinService pinService;

  setUp(() => pinService = PinService());

  group('isValidPin', () {
    test('accepts exactly four digits', () {
      expect(pinService.isValidPin('0000'), isTrue);
      expect(pinService.isValidPin('1234'), isTrue);
      expect(pinService.isValidPin('9999'), isTrue);
    });

    test('rejects malformed PINs', () {
      expect(pinService.isValidPin(''), isFalse);
      expect(pinService.isValidPin('123'), isFalse);
      expect(pinService.isValidPin('12345'), isFalse);
      expect(pinService.isValidPin('ab12'), isFalse);
      expect(pinService.isValidPin(' 123'), isFalse);
    });
  });

  group('hashPin', () {
    test('is deterministic for the same PIN', () {
      expect(pinService.hashPin('1234'), pinService.hashPin('1234'));
    });

    test('differs for different PINs', () {
      expect(pinService.hashPin('1234'), isNot(pinService.hashPin('4321')));
    });

    test('never stores the raw PIN in the digest', () {
      expect(pinService.hashPin('1234'), isNot(contains('1234')));
    });

    test('produces a 64-character lowercase SHA-256 hex digest', () {
      final hash = pinService.hashPin('1234');
      expect(hash.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });
  });

  group('verifyPin', () {
    test('accepts the correct PIN against its hash', () {
      final hash = pinService.hashPin('1234');
      expect(pinService.verifyPin('1234', hash), isTrue);
    });

    test('rejects an incorrect PIN', () {
      final hash = pinService.hashPin('1234');
      expect(pinService.verifyPin('0000', hash), isFalse);
    });
  });
}
