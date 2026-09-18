/// The payment write: cash out to a supplier, or in from a customer.
library;

import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/ledger/application/ledger_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'payment_controller.g.dart';

/// Records a payment, and refreshes the ledger it settles.
///
/// One RPC, so the cash movement and its ledger entry cannot disagree: a payment
/// that recorded the money and failed to post would leave a party looking in debt
/// after they had paid.
///
/// The state carries no value - the interesting result is the ledger row that now
/// exists, which the invalidations below put back on screen.
@riverpod
class PaymentController extends _$PaymentController {
  @override
  Future<void> build() async {}

  /// Records [amount] paid to (or received from) one party.
  Future<void> recordPayment({
    required PartyType partyType,
    required String partyId,
    required double amount,
    required PaymentMode mode,
    String? referenceNo,
    DateTime? paymentDate,
    String? notes,
  }) async {
    state = const AsyncLoading<void>();
    try {
      await ref
          .read(ledgerRepositoryProvider)
          .recordPayment(
            partyType: partyType,
            partyId: partyId,
            amount: amount,
            mode: mode,
            referenceNo: referenceNo,
            paymentDate: paymentDate,
            notes: notes,
          );
      state = const AsyncData<void>(null);
      // The two reads that a payment changes. The party's *own* detail screen is
      // reloaded by whoever opened this sheet, which keeps the dependency one way.
      ref
        ..invalidate(ledgerEntriesControllerProvider)
        ..invalidate(partyLedgerBalanceProvider);
    } on Object catch (error, stackTrace) {
      state = AsyncError<void>(error, stackTrace);
      rethrow;
    }
  }
}
