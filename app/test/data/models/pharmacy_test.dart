/// Unit tests for [Pharmacy] — the package markup a package sale needs (D-070).
library;

import 'package:app/data/models/pharmacy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `pharmacies` row with only the fields a test cares about.
Pharmacy _pharmacy({double? packageMarkupPercent, String? hospitalId}) =>
    Pharmacy.fromJson(<String, dynamic>{
      'id': 'ph-1',
      'name': 'Arihant Pharmacy',
      'created_at': '2026-09-18T00:00:00.000Z',
      'updated_at': '2026-09-18T00:00:00.000Z',
      if (packageMarkupPercent != null)
        'package_markup_percent': packageMarkupPercent,
      if (hospitalId != null) 'hospital_id': hospitalId,
    });

void main() {
  group('Pharmacy.fromJson', () {
    test('decodes a configured package markup', () {
      expect(_pharmacy(packageMarkupPercent: 20).packageMarkupPercent, 20);
    });

    test('an unconfigured markup is null, which is not zero', () {
      // The column is nullable with no default on purpose: a package sale is refused
      // while it is null rather than priced at an invented percentage, and a
      // configured 0 is a real deal rather than a missing one (D-068, D-070).
      expect(_pharmacy().packageMarkupPercent, isNull);
      expect(_pharmacy(packageMarkupPercent: 0).packageMarkupPercent, 0);
    });

    test('decodes the hospital the pharmacy sits in, or leaves it unset', () {
      expect(_pharmacy(hospitalId: 'hospital-1').hospitalId, 'hospital-1');
      expect(
        _pharmacy().hospitalId,
        isNull,
        reason: 'Phase 7a lands before the mapping is seeded',
      );
    });
  });
}
