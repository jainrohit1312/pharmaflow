/// Create, edit and deactivate for the customer master.
library;

import 'package:app/data/models/customer.dart';
import 'package:app/data/models/customer_draft.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'customers_form_controller.g.dart';

/// The customer a form is editing, or `null` when no such customer is visible.
///
/// Separate from the detail controller on purpose: the edit form needs the
/// customer's own columns and nothing else, and reusing the detail provider would
/// drag a ledger query behind a form field.
@riverpod
Future<Customer?> customerForEdit(Ref ref, String customerId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(customersRepositoryProvider)
      .byId(pharmacyId: pharmacyId, customerId: customerId);
}

/// Performs customer writes for the create and edit screens.
///
/// `state` holds the customer most recently saved, so a screen can react to a
/// successful save through `ref.listen` without the method's return value being
/// threaded through the widget. A failed write publishes an [AsyncError] and
/// rethrows, matching how `AuthController` reports failures: the state drives
/// the SnackBar, the rethrow keeps the awaiting button handler honest.
///
/// The method names are deliberately specific (`createCustomer`, not `create`).
/// Riverpod's generated base class already defines `update` and `setState`-style
/// helpers, and a method that shadows one of those is either a compile error or
/// a silent change of meaning when the framework grows another.
@riverpod
class CustomersFormController extends _$CustomersFormController {
  @override
  Future<Customer?> build() async => null;

  /// Creates a customer and stores it in `state`.
  Future<Customer> createCustomer(CustomerDraft draft) => _write(
    () async => ref
        .read(customersRepositoryProvider)
        .create(pharmacyId: ref.read(requirePharmacyIdProvider), draft: draft),
  );

  /// Overwrites a customer and stores it in `state`.
  Future<Customer> updateCustomer({
    required String customerId,
    required CustomerDraft draft,
  }) => _write(
    () async => ref
        .read(customersRepositoryProvider)
        .update(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          customerId: customerId,
          draft: draft,
        ),
  );

  /// Enables or disables a customer and stores its new state.
  ///
  /// Returns the re-read customer, or `null` when the write landed but the row
  /// could not be read back. That is not a failure: the write either succeeded
  /// or threw, and reporting a successful deactivation as an error because a
  /// follow-up read came back empty would send the user to fix something that
  /// is already correct.
  Future<Customer?> setCustomerActive({
    required String customerId,
    required bool isActive,
  }) async {
    final pharmacyId = ref.read(requirePharmacyIdProvider);
    final repository = ref.read(customersRepositoryProvider);

    state = const AsyncLoading<Customer?>();
    try {
      await repository.setActive(
        pharmacyId: pharmacyId,
        customerId: customerId,
        isActive: isActive,
      );
      final updated = await repository.byId(
        pharmacyId: pharmacyId,
        customerId: customerId,
      );
      state = AsyncData<Customer?>(updated);
      return updated;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Customer?>(error, stackTrace);
      rethrow;
    }
  }

  /// Runs a write, mapping its outcome onto `state`.
  Future<Customer> _write(Future<Customer> Function() write) async {
    state = const AsyncLoading<Customer?>();
    try {
      final saved = await write();
      return _publish(saved);
    } on Object catch (error, stackTrace) {
      state = AsyncError<Customer?>(error, stackTrace);
      rethrow;
    }
  }

  /// Publishes a successful write and returns its customer.
  Customer _publish(Customer customer) {
    state = AsyncData<Customer?>(customer);
    return customer;
  }
}
