/// The customer detail screen's data.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'customers_detail_controller.g.dart';

/// Everything the detail screen shows about one customer.
class CustomerDetailData {
  /// Creates a detail snapshot.
  const CustomerDetailData({required this.customer, required this.balance});

  /// The customer itself.
  final Customer customer;

  /// What the customer owes, and how much has been posted to their ledger.
  ///
  /// The balance is not `null` for a customer with no entries: the ledger
  /// repository always answers with totals, and `balance.isEmpty` is what
  /// distinguishes "nothing posted yet" from "posted to a net zero".
  ///
  /// Carried whole rather than reduced to a single number here, because the
  /// screen shows both directions and the entry count as well.
  final PartyBalance balance;

  /// What the customer currently owes the pharmacy.
  ///
  /// Positive is a receivable; see `PartyBalanceX.receivable`.
  double get receivable => balance.receivable;
}

/// Loads one customer's detail.
///
/// Read-only: the detail screen's only write is the activate/deactivate toggle,
/// which belongs with the other customer writes in `CustomersFormController`.
@riverpod
class CustomerDetailController extends _$CustomerDetailController {
  @override
  Future<CustomerDetailData> build(String customerId) async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final repository = ref.watch(customersRepositoryProvider);

    final customer = await repository.byId(
      pharmacyId: pharmacyId,
      customerId: customerId,
    );
    if (customer == null) {
      throw const NotFoundException(
        message: 'That customer no longer exists in your records.',
      );
    }

    // The ledger is read only once the customer is known to exist: a missing
    // customer is a NotFoundException, and issuing the balance query first would
    // spend a round trip on a party id that cannot have any entries.
    //
    // The two reads are sequential rather than concurrent for that reason, and
    // also because `Future.wait` would surface a `ParallelWaitError` instead of
    // the friendly AppException the ledger repository throws - the screen's
    // error mapping depends on the latter.
    final balance = await ref
        .watch(ledgerRepositoryProvider)
        .balanceFor(
          pharmacyId: pharmacyId,
          partyType: PartyType.customer,
          partyId: customerId,
        );

    return CustomerDetailData(customer: customer, balance: balance);
  }
}
