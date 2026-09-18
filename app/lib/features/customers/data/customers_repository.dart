/// Supabase-backed repository for the customer master.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/customer_draft.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'customers_repository.g.dart';

/// Exposes the single [CustomersRepository] used by the customers feature.
@riverpod
CustomersRepository customersRepository(Ref ref) =>
    CustomersRepository(ref.watch(supabaseClientProvider));

/// What a customer list query may filter on.
///
/// Immutable, and mutated only through the `with…` helpers, so a filter change
/// is always a new value rather than an in-place edit that Riverpod could miss.
class CustomersQuery {
  /// Creates a query; the defaults mean "everything, unsorted".
  const CustomersQuery({this.search = '', this.isActive});

  /// Free-text term matched against name, phone and GSTIN.
  ///
  /// Those three are what a counter actually asks for, and the walk-in case is
  /// usually a phone number rather than a name.
  final String search;

  /// Restrict to active or inactive customers; `null` means both.
  final bool? isActive;

  /// Whether anything is actually being filtered out.
  ///
  /// Lets a screen distinguish "there are no customers yet" from "your search
  /// matched nobody", which need different copy and different actions.
  bool get isFiltered => search.isNotEmpty || isActive != null;

  /// A copy with the search term replaced.
  CustomersQuery withSearch(String value) =>
      CustomersQuery(search: value, isActive: isActive);

  /// A copy with the active filter replaced (`null` clears it).
  ///
  /// Named for the same reason as the list controller's setter: the argument is
  /// tri-state, and a positional `withActive(false)` does not say whether it
  /// means "inactive only" or "clear the filter".
  CustomersQuery withActive({required bool? value}) =>
      CustomersQuery(search: search, isActive: value);
}

/// Data access for `customers`.
///
/// Every method takes an explicit `pharmacyId` and filters on it even though
/// RLS would scope the rows anyway: relying on a policy as the filter makes the
/// scope invisible at the call site, and an insert has to carry the column
/// regardless.
///
/// Balances are deliberately absent. What a customer owes is the sum of their
/// ledger entries, which `LedgerRepository` owns for both party types, so this
/// repository reads and writes the master only.
class CustomersRepository {
  /// Creates a repository backed by the shared Supabase client.
  CustomersRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the list screen.
  static const int pageSize = 50;

  /// Columns the free-text search looks at.
  static const List<String> searchColumns = <String>['name', 'phone', 'gstin'];

  /// Loads one page of customers matching [query], ordered by name.
  Future<List<Customer>> list({
    required String pharmacyId,
    required CustomersQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('customers')
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
      return rows.map(Customer.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the customer list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the customer list.',
        cause: error,
      );
    }
  }

  /// Loads a single customer, or `null` when it does not exist (or is not
  /// visible to this tenant).
  Future<Customer?> byId({
    required String pharmacyId,
    required String customerId,
  }) async {
    try {
      final row = await _client
          .from('customers')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', customerId)
          .maybeSingle();
      return row == null ? null : Customer.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that customer.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that customer.',
        cause: error,
      );
    }
  }

  /// Inserts a new customer owned by [pharmacyId].
  Future<Customer> create({
    required String pharmacyId,
    required CustomerDraft draft,
  }) async {
    try {
      final row = await _client
          .from('customers')
          .insert(<String, dynamic>{
            ...draft.toJson(),
            'pharmacy_id': pharmacyId,
          })
          .select()
          .single();
      return Customer.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that customer.',
        uniqueViolationMessage: 'A customer with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that customer.',
        cause: error,
      );
    }
  }

  /// Overwrites the writable columns of an existing customer.
  Future<Customer> update({
    required String pharmacyId,
    required String customerId,
    required CustomerDraft draft,
  }) async {
    try {
      final row = await _client
          .from('customers')
          .update(draft.toJson())
          .eq('pharmacy_id', pharmacyId)
          .eq('id', customerId)
          .select()
          .single();
      return Customer.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that customer.',
        uniqueViolationMessage: 'A customer with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that customer.',
        cause: error,
      );
    }
  }

  /// Enables or disables a customer.
  ///
  /// Deactivation is the supported "delete": a customer that has ever been
  /// billed is referenced by sales and by ledger entries, so removing the row
  /// would either be rejected by the foreign key or detach their history.
  Future<void> setActive({
    required String pharmacyId,
    required String customerId,
    required bool isActive,
  }) async {
    try {
      await _client
          .from('customers')
          .update(<String, dynamic>{'is_active': isActive})
          .eq('pharmacy_id', pharmacyId)
          .eq('id', customerId);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to update that customer.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to update that customer.',
        cause: error,
      );
    }
  }
}
