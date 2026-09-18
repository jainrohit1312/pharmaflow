/// Customer lookup for pickers and name lookups outside the customer master.
library;

import 'package:app/data/models/customer.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'customer_options.g.dart';

/// How many customers a picker loads at once.
///
/// The same trade-off as `supplierOptionsLimit`: a walk-in counter sale names no
/// customer at all, so the list only has to cover the accounts a pharmacy keeps,
/// which is a directory rather than a crowd. Past it the fix is a searchable
/// picker, not a larger number.
const int customerOptionsLimit = 500;

/// Every customer of the pharmacy, ordered by name, for pickers and lookups.
///
/// Deliberately separate from `customersListController`: that one carries the
/// list screen's filter state and its paging, and the counter must not inherit -
/// or disturb - either.
///
/// Includes inactive customers, because history references them: a sale made
/// before an account was deactivated must still show who it was for. Callers
/// offering a *new* choice filter to `isActive` themselves.
///
/// Consumers that only want a name should read `.value` and fall back to an empty
/// list rather than propagating a failure: losing a customer's name is a degraded
/// label, while failing the screen that shows it would be worse.
@riverpod
Future<List<Customer>> customerOptions(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(customersRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: const CustomersQuery(),
        limit: customerOptionsLimit,
      );
}
