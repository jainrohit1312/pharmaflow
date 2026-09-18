/// The ledger: what one party owes, and every entry that added up to it.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/ledger_entry.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/ledger/application/ledger_controller.dart';
import 'package:app/features/ledger/presentation/widgets/payment_sheet.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One party's ledger: the balance, and the entries behind it.
///
/// The balance is read from `ledger_entries` rather than from a stored figure,
/// because the ledger *is* the record - and it is read as both directions, since a
/// supplier's balance and a customer's are the same two columns pointing opposite
/// ways (`PartyBalanceX`).
class LedgerScreen extends ConsumerWidget {
  /// Creates the ledger screen.
  const LedgerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(ledgerSelectionControllerProvider);
    final selector = ref.read(ledgerSelectionControllerProvider.notifier);
    final parties = _partiesOf(ref, selection.partyType);
    final balance = ref.watch(partyLedgerBalanceProvider);
    final page = ref.watch(ledgerEntriesControllerProvider);
    final isSupplier = selection.partyType == PartyType.supplier;

    ref.listen<AsyncValue<LedgerPage>>(ledgerEntriesControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    });

    return AppScaffold(
      title: 'Ledger',
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: <Widget>[
                SegmentedButton<PartyType>(
                  segments: const <ButtonSegment<PartyType>>[
                    ButtonSegment<PartyType>(
                      value: PartyType.supplier,
                      label: Text('Suppliers'),
                      icon: Icon(Icons.local_shipping_outlined),
                    ),
                    ButtonSegment<PartyType>(
                      value: PartyType.customer,
                      label: Text('Customers'),
                      icon: Icon(Icons.people_outline),
                    ),
                  ],
                  selected: <PartyType>{selection.partyType},
                  onSelectionChanged: (chosen) =>
                      selector.partyType(chosen.first),
                ),
                const SizedBox(height: 12),
                AppDropdownField<String>(
                  label: isSupplier ? 'Supplier' : 'Customer',
                  hint: 'Choose one to see their ledger',
                  prefixIcon: Icons.receipt_long_outlined,
                  value: selection.partyId,
                  values: parties.ids,
                  labelOf: (id) => parties.names[id] ?? 'Unknown party',
                  allowNone: true,
                  onChanged: selector.party,
                ),
              ],
            ),
          ),
          Expanded(
            child: _LedgerBody(
              selection: selection,
              balance: balance,
              page: page,
              partyName: selection.partyId == null
                  ? null
                  : parties.names[selection.partyId],
            ),
          ),
        ],
      ),
    );
  }

  /// The parties on one side, with their names.
  ///
  /// A failed read costs the picker its options, not the screen its ledger, so it is
  /// read leniently - the same choice the purchase and sales filters make.
  static _Parties _partiesOf(WidgetRef ref, PartyType partyType) {
    if (partyType == PartyType.supplier) {
      final suppliers =
          ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];
      return _Parties(
        ids: suppliers.map((supplier) => supplier.id).toList(growable: false),
        names: <String, String>{
          for (final supplier in suppliers) supplier.id: supplier.name,
        },
      );
    }
    final customers =
        ref.watch(customerOptionsProvider).value ?? const <Customer>[];
    return _Parties(
      ids: customers.map((customer) => customer.id).toList(growable: false),
      names: <String, String>{
        for (final customer in customers) customer.id: customer.name,
      },
    );
  }
}

/// A party list's ids and names.
class _Parties {
  const _Parties({required this.ids, required this.names});

  /// The selectable ids, in display order.
  final List<String> ids;

  /// Their names by id.
  final Map<String, String> names;
}

/// The selected party's balance and entries.
class _LedgerBody extends ConsumerWidget {
  const _LedgerBody({
    required this.selection,
    required this.balance,
    required this.page,
    required this.partyName,
  });

  /// Which party is selected.
  final LedgerSelection selection;

  /// Their balance, or the failed read.
  final AsyncValue<PartyBalance?> balance;

  /// Their entries, or the failed read.
  final AsyncValue<LedgerPage> page;

  /// The selected party's name, for the payment sheet.
  final String? partyName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partyId = selection.partyId;
    if (partyId == null) {
      return const AppEmptyView(
        icon: Icons.account_balance_outlined,
        title: 'Pick a party',
        message:
            'A ledger is kept per supplier and per customer. Choose one to see '
            'what has been billed, paid and returned.',
      );
    }

    if (page.hasError && !page.hasValue) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(ledgerEntriesControllerProvider),
      );
    }
    final loaded = page.value;
    if (loaded == null) {
      return const LoadingView(message: 'Loading the ledger…');
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SectionCard(
            title: 'Balance',
            trailing: AppButton.text(
              label: selection.partyType == PartyType.supplier
                  ? 'Record payment'
                  : 'Take payment',
              icon: Icons.payments_outlined,
              expand: false,
              onPressed: () => _recordPayment(context, ref, partyId),
            ),
            child: _BalanceRow(
              balance: balance.value,
              partyType: selection.partyType,
              isLoading: balance.isLoading,
            ),
          ),
        ),
        Expanded(
          child: loaded.entries.isEmpty
              ? const AppEmptyView(
                  icon: Icons.receipt_long_outlined,
                  title: 'Nothing on this ledger',
                  message:
                      'Entries appear here as documents are posted: a purchase '
                      'credits a supplier, a sale debits a customer, and '
                      'payments and returns settle them.',
                )
              : _EntryList(page: loaded, partyType: selection.partyType),
        ),
      ],
    );
  }

  /// Opens the payment sheet and reloads what it changed.
  Future<void> _recordPayment(
    BuildContext context,
    WidgetRef ref,
    String partyId,
  ) async {
    final written = await showPaymentSheet(
      context,
      partyType: selection.partyType,
      partyId: partyId,
      partyName: partyName ?? 'This party',
      suggestedAmount: balance.value?.owedFor(selection.partyType),
    );
    if (!written || !context.mounted) {
      return;
    }
    // The controller has already invalidated the ledger reads; this only says so.
    appLogger.i('Payment recorded against $partyName');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Payment recorded.')));
  }
}

/// The balance itself, with what it means.
class _BalanceRow extends StatelessWidget {
  const _BalanceRow({
    required this.balance,
    required this.partyType,
    required this.isLoading,
  });

  /// The totals, or `null` while they load.
  final PartyBalance? balance;

  /// Which side of the ledger this is.
  final PartyType partyType;

  /// Whether the balance is still loading.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = balance;
    if (totals == null) {
      return Text(
        isLoading ? 'Reading the ledger…' : 'No balance yet.',
        style: theme.textTheme.bodyMedium,
      );
    }

    final owed = totals.owedFor(partyType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                Formatters.currency(owed.abs()),
                style: theme.textTheme.headlineSmall,
              ),
            ),
            StatusBadge(
              label: owed >= 0 ? 'Outstanding' : 'In advance',
              tone: owed >= 0 ? BadgeTone.warning : BadgeTone.info,
              icon: owed >= 0 ? Icons.schedule_outlined : Icons.trending_up,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(totals.labelFor(partyType), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Text(
          '${totals.entryCount} '
          '${totals.entryCount == 1 ? 'entry' : 'entries'} · '
          '${Formatters.currency(totals.totalDebit)} debit · '
          '${Formatters.currency(totals.totalCredit)} credit',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The loaded entries, with a trailing control to fetch the next page.
class _EntryList extends ConsumerWidget {
  const _EntryList({required this.page, required this.partyType});

  /// The entries loaded so far.
  final LedgerPage page;

  /// Which side of the ledger these entries belong to.
  final PartyType partyType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: page.entries.length + (page.hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= page.entries.length) {
          return Center(
            child: AppButton.outlined(
              label: isLoadingMore ? 'Loading…' : 'Load more',
              icon: Icons.expand_more,
              expand: false,
              isLoading: isLoadingMore,
              onPressed: isLoadingMore ? null : () => _loadMore(context, ref),
            ),
          );
        }
        return _EntryTile(entry: page.entries[index], partyType: partyType);
      },
    );
  }

  /// Fetches the next page, reporting a failure without clearing the list.
  Future<void> _loadMore(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(ledgerEntriesControllerProvider.notifier).loadMore();
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// One ledger entry, read in the direction the party is owed.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.partyType});

  /// The entry.
  final LedgerEntry entry;

  /// Which side of the ledger it belongs to.
  final PartyType partyType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effect = partyType == PartyType.supplier
        ? entry.supplierEffect
        : entry.customerEffect;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.description ?? entry.referenceType.label,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${Formatters.dateDdMmmYyyy(entry.entryDate)} · '
                    '${entry.referenceType.label}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  Formatters.currency(effect.abs()),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: effect >= 0
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.primary,
                  ),
                ),
                Text(_effectLabel(effect), style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What a signed effect means, said from the pharmacy's side.
  ///
  /// Deliberately not "debit" and "credit": a pharmacy owner reading their own
  /// ledger wants to know which way the money went, and the two words mean opposite
  /// things depending on which party is on screen.
  String _effectLabel(double effect) {
    if (effect == 0) {
      return 'no change';
    }
    if (partyType == PartyType.supplier) {
      return effect > 0 ? 'we owe more' : 'we paid';
    }
    return effect > 0 ? 'they owe more' : 'they paid';
  }
}
