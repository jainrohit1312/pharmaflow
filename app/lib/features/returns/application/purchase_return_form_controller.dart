/// Filters, received purchases and the return write.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/returns/application/purchase_returns_list_controller.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_return_form_controller.g.dart';

/// How many received purchases a return form offers to choose from.
///
/// The same trade-off as `supplierOptionsLimit`: the picker answers "which
/// invoice are these goods from", and an invoice old enough to fall past this
/// bound is unlikely to be the one being returned today. Past it, the fix is the
/// searchable picker the products already have.
const int returnablePurchaseLimit = 200;

/// Purchases a return may be raised against: received ones, newest first.
///
/// Only `received` documents: a draft has no batches and nothing has moved, and
/// `stock_update_on_purchase_return()` would have no batch to decrement - so
/// offering one would only produce a refusal at the end of the form.
@riverpod
Future<List<Purchase>> returnablePurchases(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(purchasesRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: const PurchasesQuery(status: PurchaseStatus.received),
        limit: returnablePurchaseLimit,
      );
}

/// The lines of one received purchase, with how much of each can go back.
@riverpod
Future<List<ReturnableLine>> returnableLines(Ref ref, String purchaseId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(purchaseReturnsRepositoryProvider)
      .returnableFor(pharmacyId: pharmacyId, purchaseId: purchaseId);
}

/// Creates a purchase return, and refreshes the list it will appear in.
///
/// The inventory views are deliberately not invalidated here. They are
/// auto-dispose providers that refetch when their screen is next built, and the
/// two screens that can be open while a return is written - this form and the
/// return it opens afterwards - are not among their watchers. The one place that
/// does invalidate them is the stock adjustment, which is written *from* the
/// inventory screen.
@riverpod
class PurchaseReturnFormController extends _$PurchaseReturnFormController {
  @override
  Future<PurchaseReturn?> build() async => null;

  /// Records a return of [quantities] units, keyed by purchase-item id.
  ///
  /// The quantities are all the client decides: the amounts, the supplier and the
  /// batch come from the invoice line, and the limit is re-derived by the
  /// repository from the invoice line, the returns already raised against it and
  /// the batch balance - so a stale form cannot talk the write into a larger
  /// credit than the invoice supports.
  Future<PurchaseReturn> createReturn({
    required String purchaseId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    String? reason,
  }) async {
    state = const AsyncLoading<PurchaseReturn?>();
    try {
      final saved = await ref
          .read(purchaseReturnsRepositoryProvider)
          .create(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            purchaseId: purchaseId,
            returnDate: returnDate,
            quantities: quantities,
            reason: reason,
          );
      state = AsyncData<PurchaseReturn?>(saved);
      ref.invalidate(purchaseReturnsListControllerProvider);
      return saved;
    } on Object catch (error, stackTrace) {
      state = AsyncError<PurchaseReturn?>(error, stackTrace);
      rethrow;
    }
  }
}
