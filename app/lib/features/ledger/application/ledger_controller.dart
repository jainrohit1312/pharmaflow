/// Which party's ledger is on screen, and what is in it.
library;

import 'package:app/data/models/ledger_entry.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ledger_controller.g.dart';

/// The party whose ledger the screen is showing.
class LedgerSelection {
  /// Creates a selection.
  const LedgerSelection({this.partyType = PartyType.supplier, this.partyId});

  /// Whether a supplier or a customer is selected.
  final PartyType partyType;

  /// The party, or `null` until one is chosen.
  final String? partyId;

  /// A copy with the party type replaced.
  ///
  /// Changing the side clears the party: a supplier id means nothing as a customer.
  LedgerSelection withPartyType(PartyType value) =>
      LedgerSelection(partyType: value);

  /// A copy with the party replaced, or cleared by passing `null`.
  LedgerSelection withParty(String? value) =>
      LedgerSelection(partyType: partyType, partyId: value);
}

/// Which party's ledger is selected.
///
/// Kept alive: a user checking several parties' ledgers should not be sent back to
/// an empty screen when they open a document and come back.
@Riverpod(keepAlive: true)
class LedgerSelectionController extends _$LedgerSelectionController {
  @override
  LedgerSelection build() => const LedgerSelection();

  /// Switches between the supplier and customer ledgers.
  void partyType(PartyType value) {
    if (state.partyType == value) {
      return;
    }
    state = state.withPartyType(value);
  }

  /// Selects a party, or clears the selection with `null`.
  void party(String? value) {
    if (state.partyId == value) {
      return;
    }
    state = state.withParty(value);
  }
}

/// One loaded page of ledger entries, and whether another exists.
class LedgerPage {
  /// Creates a page.
  const LedgerPage({
    required this.entries,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The entries loaded so far, newest first.
  final List<LedgerEntry> entries;

  /// Whether the last fetch filled a whole page.
  final bool hasMore;

  /// Whether a load-more is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  LedgerPage copyWith({
    List<LedgerEntry>? entries,
    bool? hasMore,
    bool? isLoadingMore,
  }) => LedgerPage(
    entries: entries ?? this.entries,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The selected party's ledger entries.
@riverpod
class LedgerEntriesController extends _$LedgerEntriesController {
  @override
  Future<LedgerPage> build() async {
    final selection = ref.watch(ledgerSelectionControllerProvider);
    final partyId = selection.partyId;
    if (partyId == null) {
      // Nothing selected is a legitimate state - the screen asks for a party - and
      // not an error: an empty page says so without a spinner or a failure.
      return const LedgerPage(entries: <LedgerEntry>[], hasMore: false);
    }

    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final entries = await ref
        .watch(ledgerRepositoryProvider)
        .entriesFor(
          pharmacyId: pharmacyId,
          partyType: selection.partyType,
          partyId: partyId,
        );

    return LedgerPage(
      entries: entries,
      hasMore: entries.length == LedgerRepository.ledgerPageSize,
    );
  }

  /// Appends the next page, restoring the current one and rethrowing on failure.
  Future<void> loadMore() async {
    final current = state.value;
    final selection = ref.read(ledgerSelectionControllerProvider);
    final partyId = selection.partyId;
    if (current == null ||
        partyId == null ||
        !current.hasMore ||
        current.isLoadingMore) {
      return;
    }

    state = AsyncData<LedgerPage>(current.copyWith(isLoadingMore: true));
    try {
      final entries = await ref
          .read(ledgerRepositoryProvider)
          .entriesFor(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            partyType: selection.partyType,
            partyId: partyId,
            offset: current.entries.length,
          );

      state = AsyncData<LedgerPage>(
        LedgerPage(
          entries: <LedgerEntry>[...current.entries, ...entries],
          hasMore: entries.length == LedgerRepository.ledgerPageSize,
        ),
      );
    } on Object {
      state = AsyncData<LedgerPage>(current);
      rethrow;
    }
  }
}

/// The selected party's balance, or `null` while nothing is selected.
@riverpod
Future<PartyBalance?> partyLedgerBalance(Ref ref) async {
  final selection = ref.watch(ledgerSelectionControllerProvider);
  final partyId = selection.partyId;
  if (partyId == null) {
    return null;
  }

  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  // The entries are watched as well, so recording a payment - which invalidates
  // them - also refreshes the balance they add up to.
  await ref.watch(ledgerEntriesControllerProvider.future);

  return ref
      .watch(ledgerRepositoryProvider)
      .balanceFor(
        pharmacyId: pharmacyId,
        partyType: selection.partyType,
        partyId: partyId,
      );
}

/// What a [PartyBalance] means for the selected side.
///
/// One helper rather than a sign convention repeated at each call site: a supplier
/// balance and a customer balance are the same two columns read in opposite
/// directions (`PartyBalanceX`).
extension LedgerBalanceMeaning on PartyBalance {
  /// The amount that matters for [partyType], always positive when owed.
  double owedFor(PartyType partyType) =>
      partyType == PartyType.supplier ? payable : receivable;

  /// What to call that amount, from the pharmacy's point of view.
  String labelFor(PartyType partyType) => partyType == PartyType.supplier
      ? 'Payable to the supplier'
      : 'Receivable from the customer';
}
