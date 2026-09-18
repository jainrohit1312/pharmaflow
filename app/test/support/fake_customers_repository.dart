/// Shared test doubles for the customer feature.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/data/customers_repository.dart';

/// Builds a customer with only the fields a test cares about.
Customer buildCustomer(
  String name, {
  String? phone,
  String? email,
  String? address,
  String? gstin,
  double openingBalance = 0,
  int loyaltyPoints = 0,
  bool isActive = true,
}) => Customer(
  id: 'id-$name',
  pharmacyId: 'ph-1',
  name: name,
  phone: phone,
  email: email,
  address: address,
  gstin: gstin,
  openingBalance: openingBalance,
  loyaltyPoints: loyaltyPoints,
  isActive: isActive,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [CustomersRepository] that applies the query the way one page of
/// the real one would.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeCustomersRepository implements CustomersRepository {
  /// Creates a fake holding [customers], already in display order.
  FakeCustomersRepository({required this.customers});

  /// The rows the fake knows about.
  final List<Customer> customers;

  /// Offsets the controller asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// The last query the controller sent.
  CustomersQuery? lastQuery;

  /// When true the next `list` call throws.
  bool failNextList = false;

  @override
  Future<List<Customer>> list({
    required String pharmacyId,
    required CustomersQuery query,
    int limit = CustomersRepository.pageSize,
    int offset = 0,
  }) async {
    lastQuery = query;
    requestedOffsets.add(offset);
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }

    // Filters the way the real query does: the term is matched against every
    // one of `CustomersRepository.searchColumns`, which is what makes a phone
    // number searchable.
    final term = query.search.toLowerCase();
    final matching = customers.where((customer) {
      final matchesTerm =
          term.isEmpty ||
          <String?>[
            customer.name,
            customer.phone,
            customer.gstin,
          ].any((field) => field?.toLowerCase().contains(term) ?? false);
      final matchesActive =
          query.isActive == null || customer.isActive == query.isActive;
      return matchesTerm && matchesActive;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
