/// Shared test doubles for the supplier features.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/supplier.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';

/// Builds a supplier with only the fields a test cares about.
Supplier buildSupplier(
  String name, {
  bool isActive = true,
  String? gstin,
  String? phone,
}) => Supplier(
  id: 'id-$name',
  pharmacyId: 'ph-1',
  name: name,
  isActive: isActive,
  gstin: gstin,
  phone: phone,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [SuppliersRepository] that applies the query the way one page
/// of the real one would.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeSuppliersRepository implements SuppliersRepository {
  /// Creates a fake holding [suppliers], already in display order.
  FakeSuppliersRepository({required this.suppliers});

  /// The rows the fake knows about.
  final List<Supplier> suppliers;

  /// Offsets the controller asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// The last query the controller sent.
  SuppliersQuery? lastQuery;

  /// When true the next `list` call throws.
  bool failNextList = false;

  @override
  Future<List<Supplier>> list({
    required String pharmacyId,
    required SuppliersQuery query,
    int limit = SuppliersRepository.pageSize,
    int offset = 0,
  }) async {
    lastQuery = query;
    requestedOffsets.add(offset);
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }

    final term = query.search.toLowerCase();
    final matching = suppliers.where((supplier) {
      final matchesTerm = term.isEmpty || _searchable(supplier).contains(term);
      final matchesActive =
          query.isActive == null || supplier.isActive == query.isActive;
      return matchesTerm && matchesActive;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// The fields the real search matches on, lower-cased.
String _searchable(Supplier supplier) => <String>[
  supplier.name,
  if (supplier.gstin != null) supplier.gstin!,
  if (supplier.phone != null) supplier.phone!,
].join(' ').toLowerCase();
