/// The chips that switch expiry bucket, with the window each one covers.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/features/inventory/application/expiry_dashboard_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shelf-life window an expiry bucket covers, spelled out.
///
/// A bucket's own label is a judgement ("Critical"), not a threshold, and this
/// screen is where the 30 and 90 day lines have to be visible: the bucket is
/// assigned by the database against its own today, so naming the window is how
/// the user can tell what the chip is counting.
String expiryWindowLabel(ExpiryStatus status) => switch (status) {
  ExpiryStatus.expired => 'Already past the expiry date',
  ExpiryStatus.critical => 'Expiring within 30 days',
  ExpiryStatus.warning => 'Expiring within 90 days',
  ExpiryStatus.safe => 'More than 90 days of shelf life',
};

/// Bucket chips, each carrying how many batches sit behind it.
///
/// The count is on the chip on purpose: a bucket nobody can size without opening
/// it makes the user click through all three to find the one that matters.
class ExpiryBucketBar extends ConsumerWidget {
  /// Creates a bucket bar.
  const ExpiryBucketBar({required this.batchCounts, super.key});

  /// How many batches sit in each bucket.
  final Map<ExpiryStatus, int> batchCounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(expiryBucketControllerProvider);
    final buckets = ref.read(expiryBucketControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final bucket in expiringBuckets) ...<Widget>[
                  ChoiceChip(
                    label: Text(
                      '${bucket.label} (${batchCounts[bucket] ?? 0})',
                    ),
                    selected: selected == bucket,
                    onSelected: (picked) => buckets.select(bucket),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            expiryWindowLabel(selected),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
