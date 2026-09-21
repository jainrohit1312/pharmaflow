/// One sale, its lines, and the names of what it sold.
library;

import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_detail_controller.g.dart';

/// A sale with everything a detail screen - and a printed bill - draws.
///
/// The document comes from `sale_document()` (migration `20260920000039`) rather than
/// from a read of `sales` plus a read of `sale_items`, because a receipt has to print
/// **which pack each line came out of and when it expires**, and `sale_items` records
/// `batch_id` alone. One read, one tenant guard, and the client never joins
/// `sale_items` to `product_batches` itself (D-079).
///
/// The product names come with it because the function returns the stored rows and
/// nothing else: `sale_items` holds a product id and a schedule snapshot, not a name,
/// so a screen showing what was sold has to resolve names from somewhere. Loading them
/// once here, for the whole document, is what keeps the invoice from making one request
/// per line.
///
/// Unlike a purchase line, a sale line keeps no copy of the printed invoice text
/// either - there is no `product_name_raw` on `sale_items` - so the catalogue name is
/// the only name there is, and the invoice is rendered in whatever the product is
/// called today.
class SaleDetailData {
  /// Creates a detail.
  ///
  /// [items] is derived from [lines] once, here, rather than being a getter: the
  /// screen reaches for it a dozen times in one build (its length, each element, its
  /// emptiness), and a getter would rebuild the list on every one of those reads.
  SaleDetailData({
    required this.sale,
    required this.lines,
    required this.productNames,
    this.patientCode,
  }) : items = List<SaleItem>.unmodifiable(<SaleItem>[
         for (final line in lines) line.item,
       ]);

  /// The sale document itself.
  final Sale sale;

  /// Its lines, in insertion order, each with the batch it came out of.
  final List<SaleDocumentLine> lines;

  /// Product names by id.
  final Map<String, String> productNames;

  /// The patient's code, or `null` when the pharmacy has none for this bill's party.
  ///
  /// `null` on a package sale - whose party is the hospital's account row - and for a
  /// customer registered before Phase 7a until `save_patient()` first touches them. A
  /// receipt prints a dash there rather than a fabricated code (D-079).
  final String? patientCode;

  /// The stored lines, without their batch detail.
  final List<SaleItem> items;

  /// What was sold on one line.
  String nameOf(SaleItem item) =>
      productNames[item.productId] ?? 'Unnamed product';

  /// Whether any line needs the statutory register's attention.
  bool get hasControlledItems => items.any((item) => item.isControlled);
}

/// The sale named by [saleId], or `null` when it is gone.
@riverpod
Future<SaleDetailData?> saleDetail(Ref ref, String saleId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final sales = ref.watch(salesRepositoryProvider);

  // One read for the document and its lines together: `sale_document()` is
  // tenant-scoped and answers `null` for a sale that is not in this pharmacy, which is
  // the same answer the screen already gave a missing bill.
  final document = await sales.saleDocument(saleId: saleId);
  if (document == null) {
    return null;
  }

  // A second read, and a different question: the function returns the stored rows, and
  // a row carries a product id rather than a name. Sequential rather than concurrent
  // because `Future.wait` over a record would surface a `ParallelWaitError` instead of
  // the friendly AppException each of these throws, and screens map errors through that.
  final names = await ref
      .watch(productsRepositoryProvider)
      .namesFor(
        pharmacyId: pharmacyId,
        productIds: document.lines
            .map((line) => line.item.productId)
            .whereType<String>()
            .toSet()
            .toList(growable: false),
      );

  return SaleDetailData(
    sale: document.sale,
    lines: document.lines,
    productNames: names,
    patientCode: document.patientCode,
  );
}
