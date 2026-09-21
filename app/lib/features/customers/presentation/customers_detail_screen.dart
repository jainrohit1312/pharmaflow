/// Customer detail screen: contact, registration, commercial and ledger.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/features/balances/presentation/widgets/patient_balance_card.dart';
import 'package:app/features/customers/application/customers_detail_controller.dart';
import 'package:app/features/customers/application/customers_form_controller.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows everything recorded about one customer.
///
/// One scrolling page rather than tabs: a customer has little enough on them that
/// tabs would hide most of it behind a tap, and the ledger - the part a counter
/// actually opens the screen for - has to be visible without one.
class CustomersDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [customerId].
  const CustomersDetailScreen({required this.customerId, super.key});

  /// The customer to show.
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(customerDetailControllerProvider(customerId));

    // A refresh keeps showing the loaded customer; only a first-load failure
    // takes over the screen.
    if (detail.hasError && !detail.hasValue) {
      return AppScaffold(
        title: 'Customer',
        leading: _backToCustomers,
        body: ErrorView(
          message: describeError(detail.error!),
          onRetry: () =>
              ref.invalidate(customerDetailControllerProvider(customerId)),
        ),
      );
    }

    final data = detail.value;
    if (data == null) {
      return const AppScaffold(
        title: 'Customer',
        leading: _backToCustomers,
        body: LoadingView(message: 'Loading customer…'),
      );
    }

    final customer = data.customer;
    return AppScaffold(
      title: customer.name,
      leading: _backToCustomers,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit customer',
          onPressed: () => context.go(Routes.customerEdit(customerId)),
        ),
        IconButton(
          icon: Icon(
            customer.isActive
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
          tooltip: customer.isActive ? 'Deactivate' : 'Reactivate',
          onPressed: () => _toggleActive(context, ref, customer),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Contact',
            child: Column(
              children: <Widget>[
                _Field(label: 'Phone', value: customer.phone),
                _Field(label: 'Email', value: customer.email),
                _Field(label: 'Address', value: customer.address),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Registration',
            child: _Field(
              label: 'GSTIN',
              value: customer.gstin,
              emptyValue: 'Not registered — treated as a walk-in customer',
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Commercial',
            child: Column(
              children: <Widget>[
                _Field(
                  label: 'Opening balance',
                  value: Formatters.currency(customer.openingBalance),
                ),
                _Field(
                  label: 'Loyalty points',
                  value: '${customer.loyaltyPoints}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // The account before the ledger: "what is owed" is the figure a counter opens
          // this screen for, and the entries behind it are the detail under it.
          PatientBalanceCard(customerId: customerId),
          const SizedBox(height: 16),
          _AdmissionsCard(patientId: customerId),
          const SizedBox(height: 16),
          _LedgerCard(data: data),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Record',
            trailing: StatusBadge(
              label: customer.isActive ? 'Active' : 'Inactive',
              tone: customer.isActive ? BadgeTone.success : BadgeTone.neutral,
            ),
            child: Column(
              children: <Widget>[
                _Field(
                  label: 'Added',
                  value: Formatters.dateTimeDdMmmYyyyHm(customer.createdAt),
                ),
                _Field(
                  label: 'Last updated',
                  value: Formatters.dateTimeDdMmmYyyyHm(customer.updatedAt),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Asks for confirmation, then flips the customer's active flag.
  Future<void> _toggleActive(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final deactivating = customer.isActive;
    final confirmed = await showConfirmDialog(
      context,
      title: deactivating ? 'Deactivate customer?' : 'Reactivate customer?',
      message: deactivating
          ? '${customer.name} stays in the master and in past sales, but will '
                'not be offered for new ones.'
          : '${customer.name} becomes available for new sales again.',
      confirmLabel: deactivating ? 'Deactivate' : 'Reactivate',
      isDestructive: deactivating,
    );
    if (!confirmed || !context.mounted) {
      return;
    }

    try {
      await ref
          .read(customersFormControllerProvider.notifier)
          .setCustomerActive(customerId: customer.id, isActive: !deactivating);
      ref.invalidate(customerDetailControllerProvider(customerId));
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Toggling customer active failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// Back to the customer list.
const AppBackButton _backToCustomers = AppBackButton(
  location: Routes.customers,
  tooltip: 'Back to customers',
);

/// The patient's episodes, each one a door to its own account.
///
/// The drill-down the admission screen is reached from. One patient has many episodes
/// and their balances never mix (D-074), so **which** one is being asked about is chosen
/// here rather than assumed - and a discharged episode is listed too, because a stay
/// that has ended still has an account.
class _AdmissionsCard extends ConsumerWidget {
  const _AdmissionsCard({required this.patientId});

  /// The patient whose episodes these are.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admissions = ref.watch(patientAdmissionsProvider(patientId));

    if (admissions.hasError && !admissions.hasValue) {
      return SectionCard(
        title: 'Admissions',
        child: ErrorView(
          message: describeError(admissions.error!),
          onRetry: () => ref.invalidate(patientAdmissionsProvider(patientId)),
        ),
      );
    }

    final rows = admissions.value;
    if (rows == null) {
      return const SectionCard(
        title: 'Admissions',
        child: Text('Loading admissions…'),
      );
    }

    if (rows.isEmpty) {
      return const SectionCard(
        title: 'Admissions',
        trailing: StatusBadge(label: 'None recorded'),
        child: Text(
          'No IPD episode has been recorded for this patient. An episode is created '
          'when an IPD sale names one, or registered on its own from the counter.',
        ),
      );
    }

    return SectionCard(
      title: 'Admissions',
      trailing: StatusBadge(
        label: rows.length == 1 ? '1 episode' : '${rows.length} episodes',
      ),
      child: Column(
        children: <Widget>[
          for (var index = 0; index < rows.length; index++) ...<Widget>[
            _AdmissionRow(admission: rows[index]),
            if (index < rows.length - 1) const Divider(height: 20),
          ],
        ],
      ),
    );
  }
}

/// One episode, tapping through to its account.
class _AdmissionRow extends StatelessWidget {
  const _AdmissionRow({required this.admission});

  /// The episode.
  final Admission admission;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.go(Routes.admission(admission.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(admission.admissionNo, style: theme.textTheme.bodyLarge),
                  Text(
                    '${Formatters.dateDdMmYyyy(admission.admittedOn)}'
                    '${admission.dischargedOn == null ? ' · active' : ' · discharged'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// What this customer owes, read from their ledger.
///
/// Read-only on purpose: ledger entries are posted by the documents that cause
/// them (a sale, a receipt, a credit note), never typed in here. Hand-editing a
/// total would leave the ledger and the balance disagreeing, with nothing to say
/// which is right.
class _LedgerCard extends StatelessWidget {
  const _LedgerCard({required this.data});

  /// The loaded detail, carrying the balance.
  final CustomerDetailData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balance = data.balance;

    if (balance.isEmpty) {
      return const SectionCard(
        title: 'Ledger balance',
        trailing: StatusBadge(label: 'No entries yet'),
        child: Text(
          'Nothing has been posted to this customer yet. The balance fills in '
          'as sales and receipts are recorded.',
        ),
      );
    }

    // A negative receivable means the pharmacy is holding the customer's money,
    // which is worth flagging rather than showing as a negative "receivable".
    final receivable = data.receivable;
    final isAdvance = receivable < 0;

    return SectionCard(
      title: 'Ledger balance',
      trailing: StatusBadge(
        label: isAdvance ? 'Customer in credit' : 'Receivable',
        tone: isAdvance ? BadgeTone.warning : BadgeTone.info,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Field(
            label: isAdvance ? 'Held for customer' : 'Receivable from customer',
            value: Formatters.currency(receivable.abs()),
          ),
          _Field(label: 'Ledger entries', value: '${balance.entryCount}'),
          _Field(
            label: 'Total billed',
            value: Formatters.currency(balance.totalDebit),
          ),
          _Field(
            label: 'Total received',
            value: Formatters.currency(balance.totalCredit),
          ),
          const SizedBox(height: 8),
          Text(
            'Posted by sales, receipts and credit notes — edit the documents, '
            'not the balance.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// A labelled value, stacked so it stays readable at any width.
class _Field extends StatelessWidget {
  const _Field({required this.label, this.value, this.emptyValue});

  /// What the value is.
  final String label;

  /// The value, or `null`/blank to render [emptyValue].
  final String? value;

  /// What to render in place of an em dash when there is no value.
  final String? emptyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value;
    final isBlank = text == null || text.trim().isEmpty;
    final display = isBlank ? (emptyValue ?? '—') : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(display, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
