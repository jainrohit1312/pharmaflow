/// The two alerts that sit beside the inbox.
///
/// Two providers rather than one, because they are two questions with two answers
/// that can fail separately (D-047): "what is running out" and "what is about to
/// expire" are different RPCs, and a screen where one failure blanks the other
/// section would be hiding half of what it knows. Each is independently retryable.
///
/// Neither is polled and neither is cached across screens: an alert is a question
/// about stock *now*, and the answer is re-read when the screen is opened. Nothing
/// derives them in Dart, which is I-1's fix (D-047).
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'alert_providers.g.dart';

/// What is below its reorder level, worst first.
///
/// The whole answer, not just the rows: the report states how big the set was (migration
/// 00050), and the screen is the place that says whether it is showing all of it.
@riverpod
Future<AlertPage<LowStockProduct>> lowStockAlerts(Ref ref) =>
    ref.watch(notificationsRepositoryProvider).lowStock();

/// What has stock left and expires inside the horizon, soonest first.
@riverpod
Future<AlertPage<ExpiringBatch>> expiringAlerts(Ref ref) =>
    ref.watch(notificationsRepositoryProvider).expiring();
