/// The supplier detail screen's data: the supplier and its ledger balance.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'suppliers_detail_controller.g.dart';

/// Everything the detail screen shows about one supplier.
class SupplierDetailData {
  /// Creates a detail snapshot.
  const SupplierDetailData({required this.supplier, required this.balance});

  /// The supplier itself.
  final Supplier supplier;

  /// Its ledger totals, read from `ledger_entries`.
  ///
  /// The balance is not `null` for a supplier with no entries: the ledger
  /// repository always answers with totals, and `balance.isEmpty` is what
  /// distinguishes "nothing posted yet" from "posted to a net zero".
  final PartyBalance balance;

  /// What the pharmacy currently owes this supplier.
  ///
  /// Positive is a payable; see `PartyBalanceX.payable`.
  double get payable => balance.payable;
}

/// Loads one supplier's detail, including its ledger balance.
@riverpod
class SupplierDetailController extends _$SupplierDetailController {
  @override
  Future<SupplierDetailData> build(String supplierId) async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final repository = ref.watch(suppliersRepositoryProvider);
    final ledger = ref.watch(ledgerRepositoryProvider);

    final supplier = await repository.byId(
      pharmacyId: pharmacyId,
      supplierId: supplierId,
    );
    if (supplier == null) {
      throw const NotFoundException(
        message: 'That supplier no longer exists in your records.',
      );
    }

    // Sequential rather than concurrent on purpose: `Future.wait` would surface
    // a `ParallelWaitError` instead of the friendly AppException each of these
    // throws, and the error mapping on screen depends on that.
    final balance = await ledger.balanceFor(
      pharmacyId: pharmacyId,
      partyType: PartyType.supplier,
      partyId: supplierId,
    );

    return SupplierDetailData(supplier: supplier, balance: balance);
  }
}
