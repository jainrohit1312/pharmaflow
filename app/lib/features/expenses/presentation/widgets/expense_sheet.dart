/// The sheet that records an expense.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/expenses/application/expenses_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows the expense entry sheet, resolving to whether anything was written.
///
/// A sheet rather than a route, like the payment sheet: it is four fields, and a
/// page for it would be chrome around a form the user is one tap away from
/// anyway.
Future<bool> showExpenseSheet(BuildContext context) async {
  final written = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => const _ExpenseSheet(),
  );
  return written ?? false;
}

/// The expense form.
class _ExpenseSheet extends ConsumerStatefulWidget {
  const _ExpenseSheet();

  @override
  ConsumerState<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends ConsumerState<_ExpenseSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  String? _category;
  PaymentMode _mode = PaymentMode.cash;
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSaving = ref.watch(expenseFormControllerProvider).isLoading;

    return Padding(
      // Keeps the fields above the soft keyboard on a phone.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Record an expense', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'An expense has no supplier on the other side of it, so it stays '
                'off the party ledger and reaches the reports instead.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              AppDropdownField<String>(
                label: 'Category',
                hint: 'What was paid for',
                prefixIcon: Icons.category_outlined,
                value: _category,
                values: expenseCategories,
                labelOf: (category) => category,
                validator: (value) =>
                    value == null ? 'Choose a category' : null,
                onChanged: (value) => setState(() => _category = value),
              ),
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
                    // On-account is omitted for the same reason the payment sheet
                    // omits it: `credit` means "not settled", and an expense has no
                    // invoice behind it for the balance to sit against.
                    if (!mode.isOnAccount)
                      ChoiceChip(
                        label: Text(mode.label),
                        selected: _mode == mode,
                        onSelected: (picked) => setState(() => _mode = mode),
                      ),
                ],
              ),
              const SizedBox(height: 16),
              AppDateField(
                label: 'Spent on',
                value: _date,
                isRequired: true,
                onChanged: (value) =>
                    setState(() => _date = value ?? DateTime.now()),
              ),
              const SizedBox(height: 16),
              AppTextField(controller: _notes, label: 'Notes', maxLines: 2),
              const SizedBox(height: 24),
              AppButton.primary(
                label: 'Record expense',
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
    return double.parse(value!.trim()) <= 0 ? 'Must be more than zero' : null;
  }

  /// Validates, writes, and closes with `true` once the expense is in.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    final category = _category;
    if (form == null || !form.validate() || category == null) {
      return;
    }

    try {
      await ref
          .read(expenseFormControllerProvider.notifier)
          .createExpense(
            category: category,
            amount: double.parse(_amount.text.trim()),
            expenseDate: _date,
            paymentMode: _mode,
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
      // user is one edit away from an expense it will accept.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}
