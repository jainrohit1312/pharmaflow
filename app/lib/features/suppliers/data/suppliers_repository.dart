/// Supabase-backed repository for the supplier master.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/models/supplier_draft.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'suppliers_repository.g.dart';

/// Exposes the single [SuppliersRepository] used by the suppliers feature.
@riverpod
SuppliersRepository suppliersRepository(Ref ref) =>
    SuppliersRepository(ref.watch(supabaseClientProvider));

/// What a supplier list query may filter on.
///
/// Immutable, and mutated only through the `with…` helpers, so a filter change
/// is always a new value rather than an in-place edit that Riverpod could miss.
class SuppliersQuery {
  /// Creates a query; the defaults mean "everything, unsorted".
  const SuppliersQuery({this.search = '', this.isActive});

  /// Free-text term matched against name, GSTIN and phone.
  final String search;

  /// Restrict to active or inactive suppliers; `null` means both.
  final bool? isActive;

  /// Whether anything is actually being filtered out.
  ///
  /// Lets a screen distinguish "there are no suppliers yet" from "your search
  /// matched nothing", which need different copy and different actions.
  bool get isFiltered => search.isNotEmpty || isActive != null;

  /// A copy with the search term replaced.
  SuppliersQuery withSearch(String value) =>
      SuppliersQuery(search: value, isActive: isActive);

  /// A copy with the active filter replaced (`null` clears it).
  ///
  /// Named for the same reason as the list controller's setter: the argument is
  /// tri-state, and a positional `withActive(false)` does not say whether it
  /// means "inactive only" or "clear the filter".
  SuppliersQuery withActive({required bool? value}) =>
      SuppliersQuery(search: search, isActive: value);
}

/// Data access for `suppliers`.
///
/// Every method takes an explicit `pharmacyId` and filters on it even though
/// RLS would scope the rows anyway: relying on a policy as the filter makes the
/// scope invisible at the call site, and an insert has to carry the column
/// regardless.
class SuppliersRepository {
  /// Creates a repository backed by the shared Supabase client.
  SuppliersRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the list screen.
  static const int pageSize = 50;

  /// Columns the free-text search looks at.
  static const List<String> searchColumns = <String>['name', 'gstin', 'phone'];

  /// Loads one page of suppliers matching [query], ordered by name.
  Future<List<Supplier>> list({
    required String pharmacyId,
    required SuppliersQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('suppliers')
          .select()
          .eq('pharmacy_id', pharmacyId);

      final search = buildIlikeOrFilter(
        columns: searchColumns,
        term: query.search,
      );
      if (search != null) {
        request = request.or(search);
      }
      final isActive = query.isActive;
      if (isActive != null) {
        request = request.eq('is_active', isActive);
      }

      final rows = await request
          .order('name')
          .range(offset, offset + limit - 1);
      return rows.map(Supplier.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the supplier list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the supplier list.',
        cause: error,
      );
    }
  }

  /// Loads a single supplier, or `null` when it does not exist (or is not
  /// visible to this tenant).
  Future<Supplier?> byId({
    required String pharmacyId,
    required String supplierId,
  }) async {
    try {
      final row = await _client
          .from('suppliers')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', supplierId)
          .maybeSingle();
      return row == null ? null : Supplier.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that supplier.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that supplier.',
        cause: error,
      );
    }
  }

  /// Inserts a new supplier owned by [pharmacyId].
  Future<Supplier> create({
    required String pharmacyId,
    required SupplierDraft draft,
  }) async {
    try {
      final row = await _client
          .from('suppliers')
          .insert(<String, dynamic>{
            ...draft.toJson(),
            'pharmacy_id': pharmacyId,
          })
          .select()
          .single();
      return Supplier.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that supplier.',
        uniqueViolationMessage: 'A supplier with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that supplier.',
        cause: error,
      );
    }
  }

  /// Overwrites the writable columns of an existing supplier.
  Future<Supplier> update({
    required String pharmacyId,
    required String supplierId,
    required SupplierDraft draft,
  }) async {
    try {
      final row = await _client
          .from('suppliers')
          .update(draft.toJson())
          .eq('pharmacy_id', pharmacyId)
          .eq('id', supplierId)
          .select()
          .single();
      return Supplier.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that supplier.',
        uniqueViolationMessage: 'A supplier with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that supplier.',
        cause: error,
      );
    }
  }

  /// Enables or disables a supplier.
  ///
  /// Deactivation is the supported "delete": a supplier that has ever been
  /// purchased from is referenced by history, so removing the row would detach
  /// its purchase orders and ledger entries.
  Future<void> setActive({
    required String pharmacyId,
    required String supplierId,
    required bool isActive,
  }) async {
    try {
      await _client
          .from('suppliers')
          .update(<String, dynamic>{'is_active': isActive})
          .eq('pharmacy_id', pharmacyId)
          .eq('id', supplierId);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to update that supplier.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to update that supplier.',
        cause: error,
      );
    }
  }
}
