/// Opening (or finding) the episode an IPD bill posts to.
///
/// A controller rather than a call from the screen, for the same reason the
/// checkout is one: it writes, it can fail in a way the operator has to be told
/// about, and the result belongs on the cart rather than in a widget's state.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'admission_controller.g.dart';

/// Finds or opens the episode a patient is being billed against.
///
/// One call to the server, which is what makes it safe to press twice: the
/// hospital's number names at most one episode for a patient, so a repeat returns
/// the row the first press created instead of opening a second one (migration
/// 00034's `save_admission`).
@riverpod
class AdmissionController extends _$AdmissionController {
  @override
  Future<Admission?> build() async => null;

  /// Finds or creates the episode [admissionNo] names for [patientId], and pins it
  /// to the cart.
  ///
  /// [doctorName] travels with it so the episode records the treating doctor the
  /// counter already typed, which is the same person the bill will name.
  Future<Admission> open({
    required String patientId,
    required String admissionNo,
    String? ward,
    String? bed,
    String? doctorId,
    String? doctorName,
    DateTime? admittedOn,
  }) async {
    if (patientId.trim().isEmpty) {
      throw const ValidationException(
        message: 'Choose the patient this admission belongs to.',
      );
    }
    if (admissionNo.trim().isEmpty) {
      throw const ValidationException(
        message: 'Type the hospital\u2019s admission number for this episode.',
      );
    }

    state = const AsyncLoading<Admission?>();
    try {
      final admission = await ref
          .read(patientsRepositoryProvider)
          .saveAdmission(
            patientId: patientId,
            admissionNo: admissionNo,
            ward: ward,
            bed: bed,
            doctorId: doctorId,
            doctorName: doctorName,
            admittedOn: admittedOn,
          );
      ref.read(posControllerProvider.notifier).setAdmission(admission);
      state = AsyncData<Admission?>(admission);
      return admission;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Admission?>(error, stackTrace);
      rethrow;
    }
  }
}
