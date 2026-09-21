/// The sheet that records a manual stock correction.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/stock_adjustment.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/inventory/application/stock_adjustment_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows the stock correction sheet, resolving to what the write did.
///
/// [onHand] is the batch's current quantity, and it is what makes the decrease
/// direction checkable before the write: the database refuses a decrease that
/// would take the batch below zero, and a form that lets the user type it anyway
/// spends a round trip to say so.
///
/// A batch is required. `stock_adjustments.batch_id` is nullable, and the trigger
/// records a product-level row without moving anything - which is not a thing a
/// user should be able to do from a screen that looks like it changes stock.
///
/// The answer is the **write's outcome** rather than a bare "something was written":
/// for anybody but the owner the correction is a request, and a caller that reported
/// "Stock adjusted." for one would be reporting a movement that has not happened.
Future<WriteOutcome<StockAdjustment>?> showStockAdjustmentSheet(
  BuildContext context, {
  required String productId,
  required String productName,
  required String batchId,
  required String batchNo,
  required int onHand,
}) => showModalBottomSheet<WriteOutcome<StockAdjustment>>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => _StockAdjustmentSheet(
    productId: productId,
    productName: productName,
    batchId: batchId,
    batchNo: batchNo,
    onHand: onHand,
  ),
);

/// The correction form.
class _StockAdjustmentSheet extends ConsumerStatefulWidget {
  const _StockAdjustmentSheet({
    required this.productId,
    required this.productName,
    required this.batchId,
    required this.batchNo,
    required this.onHand,
  });

  final String productId;
  final String productName;
  final String batchId;
  final String batchNo;
  final int onHand;

  @override
  ConsumerState<_StockAdjustmentSheet> createState() =>
      _StockAdjustmentSheetState();
}

class _StockAdjustmentSheetState extends ConsumerState<_StockAdjustmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  AdjustmentType _type = AdjustmentType.decrease;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// Validates, writes, and closes with the outcome once the write has answered.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    try {
      final outcome = await ref
          .read(stockAdjustmentControllerProvider.notifier)
          .adjustStock(
            productId: widget.productId,
            type: _type,
            qty: int.parse(_qty.text.trim()),
            batchId: widget.batchId,
            reason: _reason.text,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(outcome);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      // Left open on purpose: the message names what the database refused, and
      // the user is one edit away from a correction it will accept.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSaving = ref.watch(stockAdjustmentControllerProvider).isLoading;
    final isDecrease = _type == AdjustmentType.decrease;

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
              Text('Adjust stock', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${widget.productName} · batch ${widget.batchNo} · '
                '${_units(widget.onHand)} on hand',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              SegmentedButton<AdjustmentType>(
                segments: const <ButtonSegment<AdjustmentType>>[
                  ButtonSegment<AdjustmentType>(
                    value: AdjustmentType.increase,
                    label: Text('Increase'),
                    icon: Icon(Icons.add),
                  ),
                  ButtonSegment<AdjustmentType>(
                    value: AdjustmentType.decrease,
                    label: Text('Decrease'),
                    icon: Icon(Icons.remove),
                  ),
                ],
                selected: <AdjustmentType>{_type},
                onSelectionChanged: (selection) =>
                    setState(() => _type = selection.first),
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _qty,
                label: 'Quantity',
                hint: 'Whole units',
                prefixIcon: Icons.numbers,
                keyboardType: TextInputType.number,
                validator: _validateQty,
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _reason,
                label: 'Reason',
                hint: isDecrease
                    ? 'Breakage, spillage, a counting correction'
                    : 'Stock found, a counting correction',
                prefixIcon: Icons.notes_outlined,
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Text(
                isDecrease
                    ? 'A decrease cannot take the batch below zero; stock that '
                          'has already gone out belongs to a sale or a return.'
                    : 'The units are added to this batch, at the cost basis the '
                          'batch already carries.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              AppButton.primary(
                label: 'Record adjustment',
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

  /// Requires a whole number of at least one, and no more than is on hand.
  String? _validateQty(String? value) {
    final invalid = Validators.positiveInt(value);
    if (invalid != null) {
      return invalid;
    }
    final qty = int.parse(value!.trim());
    if (_type == AdjustmentType.decrease && qty > widget.onHand) {
      return 'Only ${_units(widget.onHand)} on hand';
    }
    return null;
  }
}

/// `12 units`, or `1 unit`.
String _units(int qty) => '$qty ${qty == 1 ? 'unit' : 'units'}';
