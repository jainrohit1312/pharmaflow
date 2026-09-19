/// Shared test doubles for the notifications feature.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:app/data/models/notification_log.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';

/// A notification with only the fields a test cares about.
AppNotification buildAppNotification({
  String id = 'notification-1',
  String userId = 'user-1',
  String type = 'message',
  String? title = 'Your order is ready',
  String message = 'Come to the counter and collect it.',
  NotificationChannel channel = NotificationChannel.inApp,
  Map<String, dynamic> data = const <String, dynamic>{},
  DateTime? readAt,
  String? pharmacyId = 'pharmacy-1',
}) => AppNotification(
  id: id,
  userId: userId,
  pharmacyId: pharmacyId,
  type: type,
  title: title,
  message: message,
  channel: channel,
  data: data,
  readAt: readAt,
  createdAt: DateTime(2026, 9, 19, 10),
  updatedAt: DateTime(2026, 9, 19, 10),
);

/// A low-stock alert with only the numbers a test cares about.
LowStockProduct buildLowStockProduct({
  String productId = 'product-1',
  String name = 'Dolo 650',
  int totalQty = 6,
  int minStockLevel = 10,
  int shortfall = 4,
  String? genericName,
  String? packSize = '15s',
}) => LowStockProduct(
  productId: productId,
  name: name,
  genericName: genericName,
  packSize: packSize,
  totalQty: totalQty,
  minStockLevel: minStockLevel,
  shortfall: shortfall,
);

/// An expiry alert with only the numbers a test cares about.
ExpiringBatch buildExpiringBatch({
  String batchId = 'batch-1',
  String productId = 'product-1',
  String productName = 'Dolo 650',
  String batchNo = 'A-1',
  DateTime? expiryDate,
  int daysLeft = 5,
  int qty = 4,
  String? packSize = '15s',
}) => ExpiringBatch(
  batchId: batchId,
  productId: productId,
  productName: productName,
  packSize: packSize,
  batchNo: batchNo,
  expiryDate: expiryDate ?? DateTime(2026, 9, 24),
  daysLeft: daysLeft,
  qty: qty,
);

/// An in-memory [NotificationsRepository] for the screen and controller tests.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a Supabase
/// client - which is the whole point, because a real `SupabaseClient` cannot be
/// constructed without an initialised backend.
///
/// Each of the three reads has its **own** failure flag, because the screen's whole
/// design is that one section failing must not blank the other two, and a single
/// flag could not express that.
class FakeNotificationsRepository implements NotificationsRepository {
  /// Creates a fake with nothing in the inbox and no alerts.
  FakeNotificationsRepository({
    List<AppNotification>? notifications,
    List<LowStockProduct>? lowStockProducts,
    List<ExpiringBatch>? expiringBatches,
  }) : notifications = notifications ?? <AppNotification>[],
       lowStockProducts = lowStockProducts ?? <LowStockProduct>[],
       expiringBatches = expiringBatches ?? <ExpiringBatch>[];

  /// What the inbox holds.
  List<AppNotification> notifications;

  /// What the low-stock RPC answers.
  List<LowStockProduct> lowStockProducts;

  /// What the expiry RPC answers.
  List<ExpiringBatch> expiringBatches;

  /// When set, `list` throws it until the test clears it.
  ///
  /// Persistent rather than one-shot on purpose: a route can be built more than
  /// once before the first frame settles, so a failure that cleared itself would be
  /// retried into a success before a test could look at the error state.
  Exception? listError;

  /// When set, `lowStock` throws it until the test clears it.
  Exception? lowStockError;

  /// When set, `expiring` throws it until the test clears it.
  Exception? expiringError;

  /// When set, `markRead` throws it until the test clears it.
  Exception? markReadError;

  /// Every id handed to `markRead`, in order.
  final List<String> markReadRequests = <String>[];

  /// How many times the inbox was read.
  ///
  /// A retry is a re-read, so a test that asserts the count went up is asserting
  /// that the retry did something rather than that the button exists.
  int listReads = 0;

  @override
  Future<List<AppNotification>> list() async {
    listReads += 1;

    final error = listError;
    if (error != null) {
      throw error;
    }
    return notifications;
  }

  @override
  Future<void> markRead(String id) async {
    markReadRequests.add(id);

    final error = markReadError;
    if (error != null) {
      throw error;
    }
    notifications = <AppNotification>[
      for (final notification in notifications)
        notification.id == id
            ? notification.copyWith(readAt: DateTime(2026, 9, 19, 11))
            : notification,
    ];
  }

  @override
  Future<List<LowStockProduct>> lowStock({
    int limit = NotificationsRepository.alertLimit,
  }) async {
    final error = lowStockError;
    if (error != null) {
      throw error;
    }
    return lowStockProducts;
  }

  @override
  Future<List<ExpiringBatch>> expiring({
    int days = NotificationsRepository.expiryHorizonDays,
    int limit = NotificationsRepository.alertLimit,
  }) async {
    final error = expiringError;
    if (error != null) {
      throw error;
    }
    return expiringBatches;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
