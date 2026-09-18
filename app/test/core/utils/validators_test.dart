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

  group('Validators.emailIfPresent', () {
    test('accepts a blank value', () {
      expect(Validators.emailIfPresent(''), isNull);
      expect(Validators.emailIfPresent('   '), isNull);
    });

    test('accepts null', () {
      expect(Validators.emailIfPresent(null), isNull);
    });

    test('still validates a value that was entered', () {
      expect(Validators.emailIfPresent('owner@pharmaflow.app'), isNull);
      expect(Validators.emailIfPresent('owner@'), isNotNull);
    });
  });

  group('Validators.gstinIfPresent', () {
    test('accepts a blank value', () {
      expect(Validators.gstinIfPresent(''), isNull);
    });

    test('accepts whitespace only', () {
      expect(Validators.gstinIfPresent('   '), isNull);
    });

    test('accepts null', () {
      expect(Validators.gstinIfPresent(null), isNull);
    });

    test('still validates a value that was entered', () {
      expect(Validators.gstinIfPresent('27ABCDE1234F1Z5'), isNull);
      expect(Validators.gstinIfPresent('nonsense'), isNotNull);
    });
  });

  group('Validators.drugLicenseIfPresent', () {
    test('accepts a blank value', () {
      expect(Validators.drugLicenseIfPresent(''), isNull);
    });

    test('accepts null', () {
      expect(Validators.drugLicenseIfPresent(null), isNull);
    });

    test('accepts the common 20B/21B shapes', () {
      expect(Validators.drugLicenseIfPresent('20B/12345/67890'), isNull);
      expect(Validators.drugLicenseIfPresent('MH-PH-123456'), isNull);
      expect(Validators.drugLicenseIfPresent('21B:1234'), isNull);
    });

    test('lower case is accepted because licences are stored upper case', () {
      expect(Validators.drugLicenseIfPresent('20b/12345'), isNull);
    });

    test('rejects spaces', () {
      expect(Validators.drugLicenseIfPresent('20B 12345'), isNotNull);
    });

    test('rejects a value longer than 30 characters', () {
      expect(
        Validators.drugLicenseIfPresent(List<String>.filled(31, 'A').join()),
        isNotNull,
      );
    });
  });

  group('Validators.phoneIfPresent', () {
    test('accepts a blank value', () {
      expect(Validators.phoneIfPresent(''), isNull);
    });

    test('still rejects a malformed number', () {
      expect(Validators.phoneIfPresent('12345'), isNotNull);
    });
  });

  group('Validators.pincodeIfPresent', () {
    test('accepts a blank value', () {
      expect(Validators.pincodeIfPresent(''), isNull);
    });

    test('accepts a 6-digit PIN code', () {
      expect(Validators.pincodeIfPresent('400001'), isNull);
    });

    test('rejects a PIN code starting with 0', () {
      expect(Validators.pincodeIfPresent('012345'), isNotNull);
    });

    test('rejects the wrong number of digits', () {
      expect(Validators.pincodeIfPresent('40000'), isNotNull);
    });
  });

  group('Validators.nonNegativeInt', () {
    test('accepts zero', () {
      expect(Validators.nonNegativeInt('0'), isNull);
    });

    test('accepts a positive whole number', () {
      expect(Validators.nonNegativeInt('30'), isNull);
    });

    test('rejects a negative number', () {
      expect(Validators.nonNegativeInt('-1'), isNotNull);
    });

    test('rejects a decimal', () {
      expect(Validators.nonNegativeInt('1.5'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.nonNegativeInt(''), isNotNull);
    });

    test('rejects null', () {
      expect(Validators.nonNegativeInt(null), isNotNull);
    });
  });

  group('Validators.nonNegativeDecimal', () {
    test('accepts zero and decimals', () {
      expect(Validators.nonNegativeDecimal('0'), isNull);
      expect(Validators.nonNegativeDecimal('1234.56'), isNull);
    });

    test('rejects a negative amount', () {
      expect(Validators.nonNegativeDecimal('-0.01'), isNotNull);
    });

    test('rejects text', () {
      expect(Validators.nonNegativeDecimal('ten'), isNotNull);
    });

    test('rejects an empty value', () {
      expect(Validators.nonNegativeDecimal(''), isNotNull);
    });
  });
}
