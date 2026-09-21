/// Applying money the pharmacy already holds to the bills it settles.
library;

import 'package:app/features/balances/application/balances.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'deposit_application_controller.g.dart';

/// Applies a receipt's held remainder, and refreshes what moved.
///
/// `allocate_payment()` writes **only** allocation rows: no `payments` row and no `ledger_entries`
/// row, because the money arrived when the receipt was taken (D-075, D-081). So nothing here writes
/// a receipt, and the only figures that change are the ones that describe where the money sits.
@riverpod
class DepositApplicationController extends _$DepositApplicationController {
  @override
  Future<void> build() async {}

  /// Applies [paymentId]'s held money to the documents [targets] name.
  ///
  /// **The client proposes; the server disposes.** Each slice is capped by what its bill still owes
  /// **under a row lock**, and the total by what the receipt still holds, so a refusal here is the
  /// authority rather than a bug - and two operators cannot both settle the same bill.
  Future<void> apply({
    required String customerId,
    required String paymentId,
    required List<PaymentAllocationTarget> targets,
  }) async {
    state = const AsyncLoading<void>();
    try {
      await ref
          .read(balancesRepositoryProvider)
          .applyDeposit(paymentId: paymentId, targets: targets);

      // What the money was applied TO, and what it came FROM: the patient's account, the bills it
      // can still settle, and the receipts still holding something.
      ref
        ..invalidate(patientAccountProvider(customerId))
        ..invalidate(openBillsProvider(customerId))
        ..invalidate(depositReceiptsProvider(customerId));

      // And the documents it settled, because what settled a bill is shown inside the bill. An
      // allocation names exactly one target, so each is one case and never both.
      for (final target in targets) {
        if (target.saleId case final saleId?) {
          ref.invalidate(saleAllocationsProvider(saleId));
        } else if (target.admissionId case final admissionId?) {
          ref.invalidate(admissionAccountProvider(admissionId));
        }
      }

      state = const AsyncData<void>(null);
    } on Object catch (error, stackTrace) {
      state = AsyncError<void>(error, stackTrace);
      rethrow;
    }
  }
}
