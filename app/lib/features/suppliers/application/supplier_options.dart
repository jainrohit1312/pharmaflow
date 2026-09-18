/// Supplier lookup for pickers outside the supplier master.
library;

import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'supplier_options.g.dart';

/// How many suppliers a picker loads at once.
///
/// A dropdown cannot search, so it wants the whole list rather than a page of
/// it; 500 is far past what a single pharmacy buys from. Past that the fix is a
/// searchable picker (as the product picker already is), not a larger number.
const int supplierOptionsLimit = 500;

/// Every supplier of the pharmacy, ordered by name, for pickers and lookups.
///
/// Deliberately separate from `suppliersListController`: that one carries the
/// list screen's filter state and its paging, and a dropdown inside a purchase
/// form must not inherit - or disturb - either.
///
/// Includes inactive suppliers, because history references them: a purchase
/// raised before a distributor was deactivated must still show who it came
/// from, and a form editing that purchase must still be able to display the
/// supplier already on it. Callers offering a *new* choice filter to `isActive`
/// themselves.
///
/// Consumers that only want a name to draw should read `.value` and fall back to
/// an empty list rather than propagating a failure: losing a supplier's name is
/// a degraded label, while failing the screen that shows it would be worse.
@riverpod
Future<List<Supplier>> supplierOptions(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(suppliersRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: const SuppliersQuery(),
        limit: supplierOptionsLimit,
      );
}
