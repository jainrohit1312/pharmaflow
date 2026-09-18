/// Unit tests for [Validators].
///
/// These tests are deliberately pure: no code generation, no Supabase, and no
/// widget tree, so the file can run on its own with `flutter test`.
library;

import 'package:app/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validators.email', () {
    test('accepts a well-formed address', () {
      expect(Validators.email('owner@pharmaflow.app'), isNull);
    });

    test('accepts a short but complete address', () {
      expect(Validators.email('a@b.co'), isNull);
    });

    test('rejects a value without an @', () {
      expect(Validators.email('owner.pharmaflow.app'), isNotNull);
    });

    test('rejects a value without a domain', () {
      expect(Validators.email('owner@'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.email(''), isNotNull);
    });

    test('rejects null', () {
      expect(Validators.email(null), isNotNull);
    });
  });

  group('Validators.password', () {
    test('accepts a long password with mixed characters', () {
      expect(Validators.password('Pharmacy#2026'), isNull);
    });

    test('rejects a password that is too short', () {
      expect(Validators.password('short'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.password(''), isNotNull);
    });

    test('rejects null', () {
      expect(Validators.password(null), isNotNull);
    });
  });

  group('Validators.phone', () {
    test('accepts a 10-digit Indian mobile number', () {
      expect(Validators.phone('9876543210'), isNull);
    });

    test('accepts a number starting with 6', () {
      expect(Validators.phone('6000000000'), isNull);
    });

    test('rejects a number that is too short', () {
      expect(Validators.phone('98765432'), isNotNull);
    });

    test('rejects a number that is too long', () {
      expect(Validators.phone('98765432101'), isNotNull);
    });

    test('rejects non-digits', () {
      expect(Validators.phone('abcdefghij'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.phone(''), isNotNull);
    });

    test('rejects null', () {
      expect(Validators.phone(null), isNotNull);
    });
  });

  group('Validators.gstin', () {
    test('accepts a well-formed 15-character GSTIN', () {
      expect(Validators.gstin('27ABCDE1234F1Z5'), isNull);
    });

    test('rejects a GSTIN that is too short', () {
      expect(Validators.gstin('27ABCDE1234F1Z'), isNotNull);
    });

    test('rejects a GSTIN that is too long', () {
      expect(Validators.gstin('27ABCDE1234F1Z50'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.gstin(''), isNotNull);
    });

    test('rejects null', () {
      expect(Validators.gstin(null), isNotNull);
    });
  });

  group('Validators.confirmPassword', () {
    test('accepts a matching confirmation', () {
      const original = 'Pharmacy#2026';
      expect(Validators.confirmPassword(original, original), isNull);
    });

    test('rejects a mismatching confirmation', () {
      const original = 'Pharmacy#2026';
      const confirmation = 'Pharmacy#2027';
      expect(Validators.confirmPassword(confirmation, original), isNotNull);
    });

    test('rejects an empty confirmation', () {
      expect(Validators.confirmPassword('', 'Pharmacy#2026'), isNotNull);
    });

    test('rejects a null confirmation', () {
      expect(Validators.confirmPassword(null, 'Pharmacy#2026'), isNotNull);
    });
  });
}
