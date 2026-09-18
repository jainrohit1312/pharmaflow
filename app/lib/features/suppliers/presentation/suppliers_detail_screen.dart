/// Supplier detail screen: contact, registration, commercial terms, ledger.
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
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/suppliers/application/suppliers_detail_controller.dart';
import 'package:app/features/suppliers/application/suppliers_form_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows everything recorded about one supplier.
///
/// One scrolling page rather than tabs: a supplier has fewer facets than a
/// product, and the ledger card is a summary that belongs beside the terms it
/// settles against, not behind a tap.
class SuppliersDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [supplierId].
  const SuppliersDetailScreen({required this.supplierId, super.key});

  /// The supplier to show.
  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(supplierDetailControllerProvider(supplierId));

    // A refresh keeps showing the loaded supplier; only a first-load failure
    // takes over the screen.
    if (detail.hasError && !detail.hasValue) {
      return AppScaffold(
        title: 'Supplier',
        leading: _backToSuppliers,
        body: ErrorView(
          message: describeError(detail.error!),
          onRetry: () =>
              ref.invalidate(supplierDetailControllerProvider(supplierId)),
        ),
      );
    }

    final data = detail.value;
    if (data == null) {
      return const AppScaffold(
        title: 'Supplier',
        leading: _backToSuppliers,
        body: LoadingView(message: 'Loading supplier…'),
      );
    }

    final supplier = data.supplier;
    return AppScaffold(
      title: supplier.name,
      leading: _backToSuppliers,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit supplier',
          onPressed: () => context.go(Routes.supplierEdit(supplierId)),
        ),
        IconButton(
          icon: Icon(
            supplier.isActive
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
          tooltip: supplier.isActive ? 'Deactivate' : 'Reactivate',
          onPressed: () => _toggleActive(context, ref, supplier),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Contact',
            trailing: StatusBadge(
              label: supplier.isActive ? 'Active' : 'Inactive',
              tone: supplier.isActive ? BadgeTone.success : BadgeTone.neutral,
            ),
            child: Column(
              children: <Widget>[
                _Field(label: 'Contact person', value: supplier.contactPerson),
                _Field(label: 'Phone', value: supplier.phone),
                _Field(label: 'Email', value: supplier.email),
                _Field(label: 'Address', value: supplier.address),
                _Field(label: 'City', value: supplier.city),
                _Field(label: 'State', value: supplier.state),
                _Field(label: 'PIN code', value: supplier.pincode),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Registration',
            child: Column(
              children: <Widget>[
                _Field(label: 'GSTIN', value: supplier.gstin),
                _Field(label: 'Drug licence', value: supplier.drugLicenseNo),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Commercial',
            child: Column(
              children: <Widget>[
                _Field(
                  label: 'Credit days',
                  value: supplier.creditDays == 0
                      ? 'Payment on delivery'
                      : '${supplier.creditDays} days',
                ),
                _Field(
                  label: 'Opening balance',
                  value: Formatters.currency(supplier.openingBalance),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LedgerCard(data: data),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Record',
            child: Column(
              children: <Widget>[
                _Field(
                  label: 'Added',
                  value: Formatters.dateTimeDdMmmYyyyHm(supplier.createdAt),
                ),
                _Field(
                  label: 'Last updated',
                  value: Formatters.dateTimeDdMmmYyyyHm(supplier.updatedAt),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Asks for confirmation, then flips the supplier's active flag.
  Future<void> _toggleActive(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
  ) async {
    final deactivating = supplier.isActive;
    final confirmed = await showConfirmDialog(
      context,
      title: deactivating ? 'Deactivate supplier?' : 'Reactivate supplier?',
      message: deactivating
          ? '${supplier.name} stays in your records and in past documents, but '
                'will not be offered when raising new purchase orders.'
          : '${supplier.name} becomes available for new purchases again.',
      confirmLabel: deactivating ? 'Deactivate' : 'Reactivate',
      isDestructive: deactivating,
    );
    if (!confirmed || !context.mounted) {
      return;
    }

    try {
      await ref
          .read(suppliersFormControllerProvider.notifier)
          .setSupplierActive(supplierId: supplier.id, isActive: !deactivating);
      ref.invalidate(supplierDetailControllerProvider(supplierId));
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Toggling supplier active failed',
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

/// Returns to the supplier list.
const AppBackButton _backToSuppliers = AppBackButton(
  location: Routes.suppliers,
  tooltip: 'Back to suppliers',
);

/// The supplier's ledger balance, read-only.
///
/// Read-only on purpose: entries are posted by purchases, payments and returns,
/// never by editing the balance. Hand-editing a total here would leave the
/// ledger and the balance disagreeing, with nothing to say which is right.
class _LedgerCard extends StatelessWidget {
  const _LedgerCard({required this.data});

  /// The loaded detail, carrying the balance.
  final SupplierDetailData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balance = data.balance;

    if (balance.isEmpty) {
      return const SectionCard(
        title: 'Ledger balance',
        trailing: StatusBadge(label: 'No entries yet'),
        child: Text(
          'Nothing has been posted to this supplier yet. The balance fills in '
          'as purchases and payments are recorded.',
        ),
      );
    }

    // A negative payable means the supplier is holding the pharmacy's money,
    // which is worth flagging rather than showing as a negative "payable".
    final payable = data.payable;
    final isAdvance = payable < 0;

    return SectionCard(
      title: 'Ledger balance',
      trailing: StatusBadge(
        label: isAdvance ? 'Advance with supplier' : 'Payable',
        tone: isAdvance ? BadgeTone.warning : BadgeTone.info,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Field(
            label: isAdvance ? 'Held by supplier' : 'Payable to supplier',
            value: Formatters.currency(payable.abs()),
          ),
          _Field(label: 'Ledger entries', value: '${balance.entryCount}'),
          _Field(
            label: 'Total billed',
            value: Formatters.currency(balance.totalCredit),
          ),
          _Field(
            label: 'Total paid',
            value: Formatters.currency(balance.totalDebit),
          ),
          const SizedBox(height: 8),
          Text(
            'Posted by purchases, payments and returns — edit the documents, '
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
  const _Field({required this.label, this.value});

  /// What the value is.
  final String label;

  /// The value, or `null`/blank to render an em dash.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value;
    final display = text == null || text.trim().isEmpty ? '—' : text;

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
