/// A batch paired with the product name `batch_status` does not carry.
library;

import 'package:app/data/models/batch_status.dart';

/// One expiry row: the batch, and what it is a batch *of*.
///
/// `batch_status` is `product_batches` plus the expiry bucket, so it names a
/// product by id only. The expiry screens show many products at once - unlike
/// the product detail screen, which already knows the one name it is showing -
/// so the name is looked up once per screen and travels with the row.
class ExpiryBatch {
  /// Creates an expiry row.
  const ExpiryBatch({required this.batch, required this.productName});

  /// The batch itself, expiry bucket included.
  final BatchStatus batch;

  /// What the batch is of.
  final String productName;

  /// Units on hand in this batch.
  int get qty => batch.qty;

  /// What those units would have sold for at MRP.
  ///
  /// MRP rather than cost: `batch_status` carries no landed cost (the column was
  /// added to `product_batches` after this view was created, and a view's `b.*`
  /// is expanded when it is created), and D-012 makes `qty x purchase_rate`
  /// wrong on any batch that took in scheme stock. MRP is the one figure on the
  /// row that needs no cost basis, and it is exactly what `product_stock` means
  /// by `stock_value_at_mrp` - so the two screens agree.
  double get valueAtMrp => qty * batch.mrp;
}
