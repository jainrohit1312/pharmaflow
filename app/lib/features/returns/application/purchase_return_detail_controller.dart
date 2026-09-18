/// One purchase return, its lines, and the invoice it credits.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/purchase_return_item.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_return_detail_controller.g.dart';

/// A return with everything a detail screen draws.
///
/// The source purchase and its lines are loaded here rather than by the screen for
/// the same reason the return's own lines are: a return is only meaningful next to
/// the invoice it credits, and the screen should not have to coordinate four async
/// states that have to agree.
///
/// The invoice lines are what the credit note is named from. A
/// `purchase_return_item` carries a product id and a batch, not a name, and the
/// invoice's own text is both cheaper to reach (one read for the whole document)
/// and more correct on a credit note than a catalogue name.
class PurchaseReturnDetail {
  /// Creates a detail.
  const PurchaseReturnDetail({
    required this.purchaseReturn,
    required this.items,
    required this.sourceItems,
    this.sourcePurchase,
  });

  /// The return document itself.
  final PurchaseReturn purchaseReturn;

  /// Its lines, in insertion order.
  final List<PurchaseReturnItem> items;

  /// The invoice lines the return was raised against, in insertion order.
  final List<PurchaseItem> sourceItems;

  /// The purchase it was raised against.
  final Purchase? sourcePurchase;

  /// The name the invoice printed for one return line, or `null` when the
  /// invoice line is gone.
  String? nameOf(PurchaseReturnItem item) {
    for (final source in sourceItems) {
      if (source.id == item.purchaseItemId) {
        final raw = source.productNameRaw?.trim();
        return raw == null || raw.isEmpty ? null : raw;
      }
    }
    return null;
  }
}

/// The return named by [returnId], or `null` when it is gone.
@riverpod
Future<PurchaseReturnDetail?> purchaseReturnDetail(
  Ref ref,
  String returnId,
) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final returns = ref.watch(purchaseReturnsRepositoryProvider);
  final purchases = ref.watch(purchasesRepositoryProvider);

  final purchaseReturn = await returns.byId(
    pharmacyId: pharmacyId,
    returnId: returnId,
  );
  if (purchaseReturn == null) {
    return null;
  }

  // Sequential rather than concurrent: `Future.wait` over a record would surface
  // a `ParallelWaitError` instead of the friendly AppException each of these
  // throws, and screens map errors through that.
  final items = await returns.itemsFor(
    pharmacyId: pharmacyId,
    returnId: returnId,
  );
  final source = await purchases.byId(
    pharmacyId: pharmacyId,
    purchaseId: purchaseReturn.purchaseId,
  );
  final sourceItems = await purchases.itemsFor(
    pharmacyId: pharmacyId,
    purchaseId: purchaseReturn.purchaseId,
  );

  return PurchaseReturnDetail(
    purchaseReturn: purchaseReturn,
    items: items,
    sourceItems: sourceItems,
    sourcePurchase: source,
  );
}
