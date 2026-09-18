/// Create, edit and status changes for purchase documents.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_form_controller.g.dart';

/// A purchase document together with its lines.
///
/// The two are always wanted together - a form seeds from them, a detail screen
/// renders them - and loading them as one value keeps the screens from having to
/// coordinate two async states that must agree.
class PurchaseWithLines {
  /// Creates the pair.
  const PurchaseWithLines({required this.purchase, required this.items});

  /// The document header.
  final Purchase purchase;

  /// Its lines, in insertion order.
  final List<PurchaseItem> items;

  /// Whether the document can still be edited.
  bool get isEditable => purchase.status.isEditable;

  /// Whether every line carries the batch details a receipt needs.
  bool get isReceivable =>
      items.isNotEmpty && items.every((item) => item.isReceivable);
}

/// The purchase a form or receipt is working on, or `null` when it is gone.
@riverpod
Future<PurchaseWithLines?> purchaseWithLines(Ref ref, String purchaseId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final repository = ref.watch(purchasesRepositoryProvider);

  final purchase = await repository.byId(
    pharmacyId: pharmacyId,
    purchaseId: purchaseId,
  );
  if (purchase == null) {
    return null;
  }

  // Sequential rather than concurrent: `Future.wait` over a record would surface
  // a `ParallelWaitError` instead of the friendly AppException each of these
  // throws, and screens map errors through that.
  final items = await repository.itemsFor(
    pharmacyId: pharmacyId,
    purchaseId: purchaseId,
  );
  return PurchaseWithLines(purchase: purchase, items: items);
}

/// Performs purchase writes that post nothing to stock or the ledger.
///
/// Receiving a document is deliberately not here: it writes batches, lines and
/// the status together, and lives in `GrnController`. Method names are
/// `<verb><Entity>` because Riverpod's generated base class already defines
/// `update`.
@riverpod
class PurchaseFormController extends _$PurchaseFormController {
  @override
  Future<Purchase?> build() async => null;

  /// Creates a purchase in `draft` and stores it in `state`.
  Future<Purchase> createPurchase({
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
  }) => _write(() async {
    final split = await ref.read(
      purchaseTaxSplitProvider(header.supplierId).future,
    );
    return ref
        .read(purchasesRepositoryProvider)
        .create(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          header: header,
          lines: lines,
          split: split,
        );
  });

  /// Rewrites a document that has not been received, and stores it in `state`.
  Future<Purchase> updatePurchase({
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
  }) => _write(() async {
    final split = await ref.read(
      purchaseTaxSplitProvider(header.supplierId).future,
    );
    return ref
        .read(purchasesRepositoryProvider)
        .updateDraft(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          purchaseId: purchaseId,
          header: header,
          lines: lines,
          split: split,
        );
  });

  /// Moves a document between `draft`, `ordered` and `cancelled`.
  Future<Purchase> setStatus({
    required String purchaseId,
    required PurchaseStatus status,
  }) => _write(
    () => ref
        .read(purchasesRepositoryProvider)
        .setStatus(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          purchaseId: purchaseId,
          status: status,
        ),
  );

  /// Runs a write, mapping its outcome onto `state`.
  Future<Purchase> _write(Future<Purchase> Function() write) async {
    state = const AsyncLoading<Purchase?>();
    try {
      final saved = await write();
      state = AsyncData<Purchase?>(saved);
      return saved;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Purchase?>(error, stackTrace);
      rethrow;
    }
  }
}
