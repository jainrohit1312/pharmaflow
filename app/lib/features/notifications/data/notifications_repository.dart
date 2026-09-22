/// The in-app inbox, and the two alerts that sit beside it.
///
/// One repository for the screen's three reads, because they are one screen's worth
/// of work and splitting them would mean three providers the widget has to keep in
/// step. Three things are deliberate:
///
///   - **Nothing here filters by tenant, and one thing deliberately filters by
///     nothing at all.** `notifications` is *user-addressed*: its RLS policies are
///     `user_id = auth.uid()`, not `pharmacy_id = get_my_pharmacy_id()` (migration
///     00012), so the caller can only ever read their own rows and a client-side
///     tenant filter would be a second, weaker copy of a rule the database already
///     enforces (D-015 governs tenant tables; this is not one).
///   - **The alerts are read from the RPCs, never re-derived here** (D-047). They
///     answer `{meta, rows}` and take the tenant from `get_my_pharmacy_id()` on the
///     server, so nothing in this file knows a pharmacy id. The envelope's own totals
///     travel with the rows (`AlertPage`), because a screen that cannot say whether its
///     list is the whole of it is a screen that quietly truncates.
///   - **`read_at` carries the device's clock**, because PostgREST cannot call
///     `now()` and a database function for one timestamp would be a migration for
///     nothing. Nothing reads the value except "is it null", so the drift cannot be
///     observed - and the next read is the arbiter if the write did not land.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'notifications_repository.g.dart';

/// The repository the inbox screen and the dashboard card read through.
@riverpod
NotificationsRepository notificationsRepository(Ref ref) =>
    NotificationsRepository(ref.watch(supabaseClientProvider));

/// Reads a user's in-app inbox, marks its rows read, and asks the two alert RPCs.
class NotificationsRepository {
  /// Creates the repository over the caller-scoped Supabase client.
  NotificationsRepository(this._client);

  final sb.SupabaseClient _client;

  /// The inbox table (migration 00008).
  static const String table = 'notifications';

  /// How many inbox rows are read. An inbox is not a ledger: the newest hundred
  /// is well past anything a person scrolls, and the count the dashboard shows is
  /// over the same page.
  static const int inboxLimit = 100;

  /// How many alerts each RPC is asked for.
  static const int alertLimit = 50;

  /// The expiry horizon the screen shows. The RPC's own default, named here
  /// because the sentence the screen writes for an empty section quotes it.
  static const int expiryHorizonDays = 90;

  /// The caller's own notifications, newest first.
  Future<List<AppNotification>> list() async {
    try {
      final rows = await _client
          .from(table)
          .select()
          .order('created_at', ascending: false)
          .limit(inboxLimit);

      return rows.map(AppNotification.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read your notifications.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to read your notifications.',
        cause: error,
      );
    }
  }

  /// Marks one notification read, as of now on this device.
  ///
  /// No row count is checked: the id came from the list this screen just read, the
  /// update policy is the caller's own rows, and a silent no-op would be corrected
  /// by the next read rather than hidden by it.
  Future<void> markRead(String id) async {
    try {
      await _client
          .from(table)
          .update(<String, dynamic>{
            'read_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', id);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to mark that notification read.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to mark that notification read.',
        cause: error,
      );
    }
  }

  /// What is below its reorder level, worst first (`low_stock_products`).
  ///
  /// The answer is an [AlertPage] rather than a list because the report states how big the
  /// whole set was (migration 00050): the screen asks for [alertLimit] rows, and a page that
  /// is short of the total is a page - which a plain list could not say.
  Future<AlertPage<LowStockProduct>> lowStock({
    int limit = alertLimit,
  }) => _page(
    'low_stock_products',
    <String, dynamic>{'p_limit': limit},
    failure: 'Unable to check which products are low.',
    shape: 'The stock alert came back in a shape this app does not understand.',
    decode: lowStockPageFrom,
  );

  /// What has stock left and expires inside [days] (`expiring_batches`).
  Future<AlertPage<ExpiringBatch>> expiring({
    int days = expiryHorizonDays,
    int limit = alertLimit,
  }) => _page(
    'expiring_batches',
    <String, dynamic>{'p_days': days, 'p_limit': limit},
    failure: 'Unable to check what is expiring.',
    shape:
        'The expiry alert came back in a shape this app does not understand.',
    decode: expiringBatchesPageFrom,
  );

  /// One alert RPC and its envelope, with both failures classified.
  ///
  /// The shape check is not the decoder's: an answer that is not the `{meta, rows}` the
  /// report promises must not read as "nothing is low on stock", because that is the one
  /// wrong answer a pharmacy would act on. It is a failure, and the screen says so.
  Future<AlertPage<T>> _page<T>(
    String function,
    Map<String, dynamic> params, {
    required String failure,
    required String shape,
    required AlertPage<T>? Function(Object?) decode,
  }) async {
    final data = await _call(function, params, failure: failure);
    final page = decode(data);
    if (page == null) {
      throw ServerException(message: shape);
    }
    return page;
  }

  /// One alert RPC, with its failures classified.
  Future<Object?> _call(
    String function,
    Map<String, dynamic> params, {
    required String failure,
  }) async {
    try {
      return await _client.rpc<dynamic>(function, params: params);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(error, fallbackMessage: failure);
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(message: failure, cause: error);
    }
  }
}
