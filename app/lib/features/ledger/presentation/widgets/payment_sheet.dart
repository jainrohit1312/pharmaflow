/// The sheet that records a payment against a party.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/ledger/application/payment_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows the payment sheet, resolving to whether anything was written.
///
/// The caller reloads its own reads on success, which is what keeps the dependency
/// one way: the supplier and customer detail screens show this sheet without the
/// ledger feature having to know about them.
Future<bool> showPaymentSheet(
  BuildContext context, {
  required PartyType partyType,
  required String partyId,
  required String partyName,
  double? suggestedAmount,
}) async {
  final written = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _PaymentSheet(
      partyType: partyType,
      partyId: partyId,
      partyName: partyName,
      suggestedAmount: suggestedAmount,
    ),
  );
  return written ?? false;
}

/// The payment form.
class _PaymentSheet extends ConsumerStatefulWidget {
  const _PaymentSheet({
    required this.partyType,
    required this.partyId,
    required this.partyName,
    this.suggestedAmount,
  });

  final PartyType partyType;
  final String partyId;
  final String partyName;
  final double? suggestedAmount;

  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  late final TextEditingController _amount = TextEditingController(
    text: widget.suggestedAmount == null || widget.suggestedAmount! <= 0
        ? ''
        : widget.suggestedAmount!.toStringAsFixed(2),
  );
  PaymentMode _mode = PaymentMode.cash;
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSaving = ref.watch(paymentControllerProvider).isLoading;
    final isSupplier = widget.partyType == PartyType.supplier;

    return Padding(
      // Keeps the fields above the soft keyboard on a phone.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                isSupplier ? 'Pay a supplier' : 'Take a payment',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(widget.partyName, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              AppTextField(
                controller: _amount,
                label: 'Amount',
                prefixIcon: Icons.currency_rupee,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: _validateAmount,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final mode in PaymentMode.values)
                    if (!mode.isOnAccount)
                      ChoiceChip(
                        label: Text(mode.label),
                        selected: _mode == mode,
                        onSelected: (selected) => setState(() => _mode = mode),
                      ),
                ],
              ),
              const SizedBox(height: 16),
              AppDateField(
                label: 'Paid on',
                value: _date,
                isRequired: true,
                onChanged: (value) =>
                    setState(() => _date = value ?? DateTime.now()),
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _reference,
                label: 'Reference',
                hint: 'Cheque number, UPI reference',
                prefixIcon: Icons.tag,
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _notes,
                label: 'Notes',
                maxLines: 2,
              ),
              const SizedBox(height: 24),
              AppButton.primary(
                label: 'Record payment',
                icon: Icons.check,
                isLoading: isSaving,
                onPressed: isSaving ? null : _submit,
              ),
              const SizedBox(height: 8),
              AppButton.text(
                label: 'Cancel',
                onPressed: isSaving ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Requires an amount greater than zero.
  String? _validateAmount(String? value) {
    final invalid = Validators.nonNegativeDecimal(value);
    if (invalid != null) {
      return invalid;
    }
    return double.parse(value!.trim()) <= 0
        ? 'Must be more than zero'
        : null;
  }

  /// Validates, writes, and closes with `true` once the payment is in.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    try {
      await ref
          .read(paymentControllerProvider.notifier)
          .recordPayment(
            partyType: widget.partyType,
            partyId: widget.partyId,
            amount: double.parse(_amount.text.trim()),
            mode: _mode,
            referenceNo: _reference.text,
            paymentDate: _date,
            notes: _notes.text,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      // Left open on purpose: the message says what the database refused, and the
      // user is one edit away from a payment it will accept.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}
