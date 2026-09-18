/// Create, edit and deactivate for the supplier master.
library;

import 'package:app/data/models/supplier.dart';
import 'package:app/data/models/supplier_draft.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'suppliers_form_controller.g.dart';

/// The supplier a form is editing, or `null` when no such supplier is visible.
///
/// Separate from the detail controller on purpose: the edit form needs the
/// supplier's own columns and nothing else, and reusing the detail provider
/// would drag a ledger read behind a form field.
@riverpod
Future<Supplier?> supplierForEdit(Ref ref, String supplierId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(suppliersRepositoryProvider)
      .byId(pharmacyId: pharmacyId, supplierId: supplierId);
}

/// Performs supplier writes for the create and edit screens.
///
/// `state` holds the supplier most recently saved, so a screen can react to a
/// successful save through `ref.listen` without the method's return value being
/// threaded through the widget. A failed write publishes an [AsyncError] and
/// rethrows, matching how `AuthController` reports failures: the state drives
/// the SnackBar, the rethrow keeps the awaiting button handler honest.
///
/// The method names are deliberately specific (`createSupplier`, not `create`).
/// Riverpod's generated base class already defines `update` and the
/// `setState`-style helpers, so a method that shadows one of those is either a
/// compile error or a silent change of meaning when the framework grows
/// another.
@riverpod
class SuppliersFormController extends _$SuppliersFormController {
  @override
  Future<Supplier?> build() async => null;

  /// Creates a supplier and stores it in `state`.
  Future<Supplier> createSupplier(SupplierDraft draft) => _write(
    () async => ref
        .read(suppliersRepositoryProvider)
        .create(pharmacyId: ref.read(requirePharmacyIdProvider), draft: draft),
  );

  /// Overwrites a supplier and stores it in `state`.
  Future<Supplier> updateSupplier({
    required String supplierId,
    required SupplierDraft draft,
  }) => _write(
    () async => ref
        .read(suppliersRepositoryProvider)
        .update(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          supplierId: supplierId,
          draft: draft,
        ),
  );

  /// Enables or disables a supplier and stores its new state.
  ///
  /// Returns the re-read supplier, or `null` when the write landed but the row
  /// could not be read back. That is not a failure: the write either succeeded
  /// or threw, and reporting a successful deactivation as an error because a
  /// follow-up read came back empty would send the user to fix something that
  /// is already correct.
  Future<Supplier?> setSupplierActive({
    required String supplierId,
    required bool isActive,
  }) async {
    final pharmacyId = ref.read(requirePharmacyIdProvider);
    final repository = ref.read(suppliersRepositoryProvider);

    state = const AsyncLoading<Supplier?>();
    try {
      await repository.setActive(
        pharmacyId: pharmacyId,
        supplierId: supplierId,
        isActive: isActive,
      );
      final updated = await repository.byId(
        pharmacyId: pharmacyId,
        supplierId: supplierId,
      );
      state = AsyncData<Supplier?>(updated);
      return updated;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Supplier?>(error, stackTrace);
      rethrow;
    }
  }

  /// Runs a write, mapping its outcome onto `state`.
  Future<Supplier> _write(Future<Supplier> Function() write) async {
    state = const AsyncLoading<Supplier?>();
    try {
      final saved = await write();
      return _publish(saved);
    } on Object catch (error, stackTrace) {
      state = AsyncError<Supplier?>(error, stackTrace);
      rethrow;
    }
  }

  /// Publishes a successful write and returns its supplier.
  Supplier _publish(Supplier supplier) {
    state = AsyncData<Supplier?>(supplier);
    return supplier;
  }
}
