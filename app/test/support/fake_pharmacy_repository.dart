/// Shared test double for the pharmacy tenant row.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/pharmacy.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';

/// Builds a pharmacy with only the fields a test cares about.
Pharmacy buildPharmacy({
  String id = 'ph-1',
  String name = 'Arihant Pharmacy',
  String? state,
  double? packageMarkupPercent,
}) => Pharmacy(
  id: id,
  name: name,
  state: state,
  packageMarkupPercent: packageMarkupPercent,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [PharmacyRepository].
///
/// `packageMarkupPercent` is what a package sale is priced from (D-070), so the
/// fake's default - like the column's - is **null**: nobody has configured it.
class FakePharmacyRepository implements PharmacyRepository {
  /// Creates a fake answering with [pharmacy].
  FakePharmacyRepository({this.pharmacy});

  /// The row every read answers with, or `null` when it cannot be read.
  Pharmacy? pharmacy;

  /// When set, the next call throws it.
  Exception? errorToThrow;

  @override
  Future<Pharmacy?> byId(String pharmacyId) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return pharmacy;
  }

  @override
  Future<String?> stateFor(String pharmacyId) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return pharmacy?.state;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
