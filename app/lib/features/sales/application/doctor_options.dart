/// The prescribers a sale may name.
///
/// An option list rather than a controller: a bill names a prescriber (D-072), the
/// list is a directory of the doctors who write for this pharmacy, and a typed name
/// with no master row is accepted anyway - so this only ever *offers*.
library;

import 'package:app/data/models/doctor.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/sales/data/doctors_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'doctor_options.g.dart';

/// The pharmacy's active prescribers, ordered by name.
///
/// Read leniently by the screen (`.value` with an empty fallback): losing the
/// suggestions costs the counter a convenience, while failing the bill it is
/// halfway through would cost it the sale.
@riverpod
Future<List<Doctor>> doctorOptions(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref.watch(doctorsRepositoryProvider).list(pharmacyId: pharmacyId);
}
