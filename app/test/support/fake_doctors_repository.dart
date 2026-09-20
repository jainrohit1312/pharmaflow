/// Shared test doubles for the prescriber master.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/doctor.dart';
import 'package:app/features/sales/data/doctors_repository.dart';

/// Builds a doctor with only the fields a test cares about.
Doctor buildDoctor(
  String name, {
  String? id,
  String? specialization,
  bool isActive = true,
}) => Doctor(
  id: id ?? 'id-$name',
  pharmacyId: 'ph-1',
  name: name,
  specialization: specialization,
  isActive: isActive,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [DoctorsRepository].
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing, so
/// the fake never needs a Supabase client.
class FakeDoctorsRepository implements DoctorsRepository {
  /// Creates a fake holding [doctors], already in name order.
  FakeDoctorsRepository({List<Doctor> doctors = const <Doctor>[]})
    : doctors = List<Doctor>.of(doctors);

  /// The prescribers the master holds.
  List<Doctor> doctors;

  /// The searches the picker asked for, in order.
  final List<String> searchedTerms = <String>[];

  /// When set, the next call throws it.
  Exception? errorToThrow;

  @override
  Future<List<Doctor>> list({
    required String pharmacyId,
    String search = '',
    bool includeInactive = false,
    int limit = DoctorsRepository.pageSize,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    searchedTerms.add(search);
    final needle = search.trim().toLowerCase();
    return doctors
        .where((doctor) => includeInactive || doctor.isActive)
        .where(
          (doctor) =>
              needle.isEmpty || doctor.name.toLowerCase().contains(needle),
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
