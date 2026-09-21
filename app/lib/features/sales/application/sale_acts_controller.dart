/// The two acts a posted bill allows, for the screen that shows one.
///
/// Each is a REQUEST for anybody but the owner (Phase 6.5c chunk 5d): the server writes nothing and
/// answers `staged`, so the screen says where the work went instead of showing a bill that looks
/// changed. The returned [WriteOutcome] is what tells the two apart - never the viewer's role, which
/// would show the owner a "waiting" message for an act that had already landed.
library;

import 'package:app/data/models/sale.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_acts_controller.g.dart';

/// Performs the two sale acts and refreshes the bill that landed.
///
/// `state` holds the sale most recently written, or `null` when the act was staged: a staged act
/// moved nothing, so there is nothing to hold and nothing to refresh - a re-read would show the
/// unchanged bill and read as an act that had happened.
@riverpod
class SaleActsController extends _$SaleActsController {
  @override
  Future<Sale?> build() async => null;

  /// Cancels a posted bill, or asks the owner to.
  Future<WriteOutcome<Sale>> cancel({required String saleId, String? reason}) =>
      _act(
        saleId: saleId,
        write: (repository) =>
            repository.cancel(saleId: saleId, reason: reason),
      );

  /// Corrects a posted bill's printed identity, or asks the owner to.
  Future<WriteOutcome<Sale>> editIdentity({
    required String saleId,
    String? patientName,
    String? patientMobile,
    String? patientAddress,
    String? doctorName,
    String? hospitalReference,
  }) => _act(
    saleId: saleId,
    write: (repository) => repository.editIdentity(
      saleId: saleId,
      patientName: patientName,
      patientMobile: patientMobile,
      patientAddress: patientAddress,
      doctorName: doctorName,
      hospitalReference: hospitalReference,
    ),
  );

  /// Runs one act, publishes what landed and refreshes the bill's detail.
  Future<WriteOutcome<Sale>> _act({
    required String saleId,
    required Future<WriteOutcome<Sale>> Function(SalesRepository) write,
  }) async {
    state = const AsyncLoading<Sale?>();
    try {
      final outcome = await write(ref.read(salesRepositoryProvider));
      state = AsyncData<Sale?>(outcome.document);

      if (!outcome.isStaged) {
        // The bill itself changed - its status or its printed identity - so the detail screen is
        // re-read. A staged act changed nothing, which is why it does not get here.
        ref.invalidate(saleDetailProvider(saleId));
      }

      return outcome;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Sale?>(error, stackTrace);
      rethrow;
    }
  }
}
