/// The sheet that applies money the pharmacy is already holding to the bills it settles.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/party_deposits.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/balances/application/balances.dart';
import 'package:app/features/balances/application/deposit_application_controller.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows the sheet, resolving to whether any money was applied.
///
/// The caller reloads nothing itself: applying money refreshes the patient's account, the bills it
/// can settle and the receipts that hold it, in the controller. That is the one-way dependency the
/// payment sheet has too - the balance card shows this sheet without the balances feature having to
/// know which screen opened it.
Future<bool> showApplyDepositSheet(
  BuildContext context, {
  required String customerId,
  required String patientName,
}) async {
  final applied = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _ApplyDepositSheet(customerId: customerId, patientName: patientName),
  );
  return applied ?? false;
}

/// The form: which receipt the money comes from, and how much of it settles which bill.
class _ApplyDepositSheet extends ConsumerStatefulWidget {
  const _ApplyDepositSheet({
    required this.customerId,
    required this.patientName,
  });

  final String customerId;
  final String patientName;

  @override
  ConsumerState<_ApplyDepositSheet> createState() => _ApplyDepositSheetState();
}

class _ApplyDepositSheetState extends ConsumerState<_ApplyDepositSheet> {
  /// The receipt the operator has picked, or `null` for the oldest one that still holds money.
  String? _receiptId;

  /// One amount per bill, keyed by the bill's id, created as the bills arrive.
  final Map<String, TextEditingController> _amounts =
      <String, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _amounts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deposits = ref.watch(depositReceiptsProvider(widget.customerId));
    final bills = ref.watch(openBillsProvider(widget.customerId));
    final isSaving = ref.watch(depositApplicationControllerProvider).isLoading;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Apply held money', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.patientName, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            ..._body(theme, deposits, bills, isSaving),
            const SizedBox(height: 16),
            AppButton.text(
              label: 'Close',
              onPressed: isSaving ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's body: a first-load failure, the two empty cases, or the form.
  List<Widget> _body(
    ThemeData theme,
    AsyncValue<List<DepositReceipt>> deposits,
    AsyncValue<List<OpenBill>> bills,
    bool isSaving,
  ) {
    // A refresh keeps showing what is loaded; only a first-load failure takes the sheet over,
    // checked before `isLoading` for the same reason the balance card does it.
    final failure = !deposits.hasValue
        ? deposits.error
        : (bills.hasValue ? null : bills.error);

    if (failure != null) {
      return <Widget>[
        ErrorView(
          message: describeError(failure),
          onRetry: () => ref
            ..invalidate(depositReceiptsProvider(widget.customerId))
            ..invalidate(openBillsProvider(widget.customerId)),
        ),
      ];
    }

    if (!deposits.hasValue || !bills.hasValue) {
      return <Widget>[const Text('Loading what is held…')];
    }

    final receipts = deposits.requireValue;
    final open = bills.requireValue;

    if (receipts.isEmpty) {
      // The money is not here to apply: a receipt with nothing left is not a deposit, and the
      // repository does not return one.
      return <Widget>[
        Text(
          'Nothing is held for this patient. Every receipt taken from them has been '
          'applied to a bill already.',
          style: theme.textTheme.bodyMedium,
        ),
      ];
    }

    // The operator's pick, falling back to the oldest receipt that still holds something - which
    // is also what happens when the one they picked has just been applied in full.
    final receipt = receipts.firstWhere(
      (candidate) => candidate.id == _receiptId,
      orElse: () => receipts.first,
    );

    if (open.isEmpty) {
      return <Widget>[
        _heldLine(theme, receipt),
        const SizedBox(height: 12),
        Text(
          'There is nothing to apply it to: every bill this patient has is settled. The '
          'money stays held until one is raised.',
          style: theme.textTheme.bodyMedium,
        ),
      ];
    }

    return <Widget>[
      Text('Which receipt', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final candidate in receipts)
            ChoiceChip(
              label: Text(_receiptLabel(candidate)),
              selected: candidate.id == receipt.id,
              onSelected: (_) => setState(() => _receiptId = candidate.id),
            ),
        ],
      ),
      const SizedBox(height: 16),
      _heldLine(theme, receipt),
      const SizedBox(height: 16),
      Text('Which bills it settles', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      for (final bill in open) ...<Widget>[
        _BillRow(
          bill: bill,
          controller: _amounts.putIfAbsent(
            bill.saleId,
            TextEditingController.new,
          ),
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 12),
      ],
      _applyingLine(theme, receipt, open),
      const SizedBox(height: 16),
      AppButton.primary(
        label: 'Apply money',
        icon: Icons.price_check,
        isLoading: isSaving,
        // Disabled until there is something to apply: a button that writes a zero row would ask
        // the server a question with no answer.
        onPressed: isSaving || _total(open) <= 0
            ? null
            : () => _submit(receipt),
      ),
    ];
  }

  /// What the chosen receipt still holds, as the sheet's own sentence.
  Widget _heldLine(ThemeData theme, DepositReceipt receipt) => Text(
    'Holding ${Formatters.currency(receipt.held)} from '
    '${_receiptLabel(receipt)}.',
    style: theme.textTheme.bodyMedium,
  );

  /// How much is about to be applied, and how much would be left.
  ///
  /// Shown rather than enforced: the caps belong to `allocate_payment()`, which re-checks each bill
  /// under a row lock and the total against the receipt. A sheet that refused a figure the server
  /// would have accepted, or accepted one it would refuse, would be a second opinion about money.
  Widget _applyingLine(
    ThemeData theme,
    DepositReceipt receipt,
    List<OpenBill> open,
  ) {
    final total = _total(open);
    return Text(
      'Applying ${Formatters.currency(total)} of the '
      '${Formatters.currency(receipt.held)} held; '
      '${Formatters.currency(receipt.held - total)} would stay held.',
      style: theme.textTheme.bodySmall,
    );
  }

  /// The receipt as a chip reads it: what it holds, when, and how it was taken.
  String _receiptLabel(DepositReceipt receipt) {
    final date = receipt.paymentDate;
    return '${Formatters.currency(receipt.held)}'
        '${date == null ? '' : ' · ${Formatters.dateDdMmYyyy(date)}'}'
        ' · ${receipt.mode.label}';
  }

  /// Every amount the operator has typed, in bill order.
  List<PaymentAllocationTarget> _targets(List<OpenBill> open) =>
      <PaymentAllocationTarget>[
        for (final bill in open)
          if (_amountOf(bill) > 0)
            PaymentAllocationTarget.sale(
              saleId: bill.saleId,
              amount: _amountOf(bill),
            ),
      ];

  /// What has been typed for [bill], or zero.
  double _amountOf(OpenBill bill) =>
      double.tryParse(_amounts[bill.saleId]?.text.trim() ?? '') ?? 0;

  /// The total about to be applied.
  double _total(List<OpenBill> open) =>
      open.fold<double>(0, (sum, bill) => sum + _amountOf(bill));

  /// Applies what has been entered, and closes once the server has taken it.
  Future<void> _submit(DepositReceipt receipt) async {
    final targets = _targets(
      ref.read(openBillsProvider(widget.customerId)).requireValue,
    );
    if (targets.isEmpty) {
      return;
    }

    try {
      await ref
          .read(depositApplicationControllerProvider.notifier)
          .apply(
            customerId: widget.customerId,
            paymentId: receipt.id,
            targets: targets,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      // Left open on purpose: the message is the server's own words about what it refused - a bill
      // that has moved on, a figure larger than it owes - and the operator is one edit away from an
      // application it will accept.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// One bill, and the amount that would settle part of it.
class _BillRow extends StatelessWidget {
  const _BillRow({
    required this.bill,
    required this.controller,
    required this.onChanged,
  });

  final OpenBill bill;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = bill.saleDate;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(bill.invoiceNo, style: theme.textTheme.titleSmall),
              Text(
                <String>[
                  if (date != null) Formatters.dateDdMmYyyy(date),
                  bill.saleType.label,
                  'owes ${Formatters.currency(bill.outstanding)}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 140,
          child: AppTextField(
            controller: controller,
            label: 'Amount',
            prefixIcon: Icons.currency_rupee,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
          ),
        ),
      ],
    );
  }
}
