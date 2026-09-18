/// Which expiry bucket the dashboard is showing, and what is in it.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'expiry_dashboard_controller.g.dart';

/// The buckets the expiry dashboard reports on, most urgent first.
///
/// Deliberately only the three that need a decision. A batch with more than 90
/// days of shelf life is not an alert, and listing it would bury the ones that
/// are - which is the whole job of this screen.
const List<ExpiryStatus> expiringBuckets = <ExpiryStatus>[
  ExpiryStatus.expired,
  ExpiryStatus.critical,
  ExpiryStatus.warning,
];

/// The bucket the dashboard is currently showing.
///
/// Kept alive so returning from a product (or from the calendar) does not reset
/// which bucket the user was working through. Opens on `critical` - the one that
/// is still worth acting on, where `expired` is already a write-off.
@Riverpod(keepAlive: true)
class ExpiryBucketController extends _$ExpiryBucketController {
  @override
  ExpiryStatus build() => ExpiryStatus.critical;

  /// Shows another bucket.
  void select(ExpiryStatus status) {
    if (state == status) {
      return;
    }
    state = status;
  }
}

/// What the expiry dashboard draws: the selected bucket's rows, and how much is
/// behind each bucket.
///
/// The counts cover all three buckets while the rows cover one, because a chip
/// that cannot say how much is behind it makes the user click through every
/// bucket to find out.
class ExpiryBoard {
  /// Creates a board.
  const ExpiryBoard({required this.rows, required this.batchCounts});

  /// The selected bucket's rows, soonest expiry first.
  final List<ExpiryBatch> rows;

  /// How many batches sit in each bucket, expired included.
  final Map<ExpiryStatus, int> batchCounts;

  /// How many batches are in [status].
  int countOf(ExpiryStatus status) => batchCounts[status] ?? 0;
}

/// The batches that need an expiry decision, by bucket.
@riverpod
class ExpiryBoardController extends _$ExpiryBoardController {
  @override
  Future<ExpiryBoard> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final bucket = ref.watch(expiryBucketControllerProvider);
    final repository = ref.watch(inventoryRepositoryProvider);

    // One read for all three buckets: the counts need them anyway, and a bucket
    // is inherently small (batches within 90 days of expiring), so a fetch per
    // chip would be three round trips to answer one question.
    final batches = await repository.expiringBatches(
      pharmacyId: pharmacyId,
      statuses: expiringBuckets.toSet(),
    );
    // `batch_status` names a product by id only; the names come from the
    // repository that owns them.
    final names = await ref
        .watch(productsRepositoryProvider)
        .namesFor(
          pharmacyId: pharmacyId,
          productIds: batches
              .map((batch) => batch.productId)
              .toSet()
              .toList(growable: false),
        );

    final counts = <ExpiryStatus, int>{
      for (final status in expiringBuckets)
        status: batches.where((batch) => batch.expiryStatus == status).length,
    };

    return ExpiryBoard(
      rows: batches
          .where((batch) => batch.expiryStatus == bucket)
          .map(
            (batch) => ExpiryBatch(
              batch: batch,
              // The foreign key makes this total, so the fallback is only a
              // guard against a name read that came back short.
              productName: names[batch.productId] ?? 'Unknown product',
            ),
          )
          .toList(growable: false),
      batchCounts: counts,
    );
  }
}
