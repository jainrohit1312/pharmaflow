/// Raises a purchase return against a received purchase.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/returns/application/purchase_return_form_controller.dart';
import 'package:app/features/returns/data/purchase_return_totals.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:app/features/returns/presentation/widgets/purchase_picker_field.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Chooses a received purchase, the lines going back, and why.
///
/// The form never asks for money. Every figure on the credit note comes from the
/// invoice line's own stored amounts, and the most a line may return is derived
/// from what was billed, what has already gone back and what is still in the
/// batch - so the number in the field is the number the write will accept.
class PurchaseReturnFormScreen extends ConsumerStatefulWidget {
  /// Creates the purchase return form screen.
  const PurchaseReturnFormScreen({super.key});

  @override
  ConsumerState<PurchaseReturnFormScreen> createState() =>
      _PurchaseReturnFormScreenState();
}

class _PurchaseReturnFormScreenState
    extends ConsumerState<PurchaseReturnFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  /// The invoice the goods came from, as the picker returned it.
  ///
  /// Kept as the whole row rather than as an id: the field has to draw what was
  /// chosen, and a label derived from whatever list happened to be loaded is how
  /// the old dropdown ended up calling a chosen invoice "Another purchase" (I-3).
  Purchase? _purchase;
  DateTime _returnDate = DateTime.now();

  /// Units to return, keyed by purchase-item id. Absent means "this one stays".
  final Map<String, int> _quantities = <String, int>{};

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final purchaseId = _purchase?.id;
    final lines = purchaseId == null
        ? null
        : ref.watch(returnableLinesProvider(purchaseId));
    final isSaving = ref.watch(purchaseReturnFormControllerProvider).isLoading;
    // Who the chosen invoice came from, for the field's label. An unresolved name
    // is simply left off rather than failing anything - the same trade
    // `PurchaseCard` makes with the same map.
    final supplierNames = <String, String>{
      for (final supplier
          in ref.watch(supplierOptionsProvider).value ?? const <Supplier>[])
        supplier.id: supplier.name,
    };

    ref.listen<AsyncValue<PurchaseReturn?>>(
      purchaseReturnFormControllerProvider,
      (previous, next) {
        final error = next.error;
        if (error == null || !mounted) {
          return;
        }
        _report(describeError(error));
      },
    );

    return AppScaffold(
      title: 'New purchase return',
      leading: const AppBackButton(
        location: Routes.returns,
        tooltip: 'Back to returns',
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SectionCard(
              title: 'Return',
              child: Column(
                children: <Widget>[
                  PurchasePickerField(
                    selected: _purchase,
                    selectedSupplierName: _purchase == null
                        ? null
                        : supplierNames[_purchase!.supplierId],
                    onSelected: _choosePurchase,
                  ),
                  const SizedBox(height: 16),
                  AppDateField(
                    label: 'Return date',
                    value: _returnDate,
                    isRequired: true,
                    onChanged: (value) =>
                        setState(() => _returnDate = value ?? DateTime.now()),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _reason,
                    label: 'Reason',
                    hint: 'Damaged, near expiry, sent back by mistake',
                    prefixIcon: Icons.notes_outlined,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Lines',
              child: _Lines(
                lines: lines,
                quantities: _quantities,
                onLineChanged: _setQuantity,
                onRetry: purchaseId == null
                    ? null
                    : () => ref.invalidate(returnableLinesProvider(purchaseId)),
              ),
            ),
            const SizedBox(height: 16),
            _CreditPreview(lines: lines?.value, quantities: _quantities),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'Record return',
              icon: Icons.assignment_return_outlined,
              isLoading: isSaving,
              onPressed: isSaving || purchaseId == null ? null : _save,
            ),
          ],
        ),
      ),
    );
  }

  /// Switches the invoice being credited, dropping the previous line choices.
  ///
  /// The quantities are keyed by purchase-item id, so a stale choice could never
  /// be attributed to the wrong invoice - but leaving them in place would make the
  /// fields wrong on screen if the same item id came back, so they are cleared.
  void _choosePurchase(Purchase purchase) => setState(() {
    if (_purchase?.id != purchase.id) {
      _quantities.clear();
    }
    _purchase = purchase;
  });

  /// Records how many units of one line are going back, or clears it at zero.
  void _setQuantity(String purchaseItemId, int qty) => setState(() {
    if (qty <= 0) {
      _quantities.remove(purchaseItemId);
    } else {
      _quantities[purchaseItemId] = qty;
    }
  });

  /// Validates and writes the return, then opens it.
  Future<void> _save() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    final purchaseId = _purchase?.id;
    if (purchaseId == null) {
      _report('Choose the purchase the goods came from.');
      return;
    }
    if (_quantities.isEmpty) {
      _report('Enter how many units are going back.');
      return;
    }

    try {
      final saved = await ref
          .read(purchaseReturnFormControllerProvider.notifier)
          .createReturn(
            purchaseId: purchaseId,
            returnDate: _returnDate,
            quantities: Map<String, int>.of(_quantities),
            reason: _reason.text,
          );
      if (!mounted) {
        return;
      }
      context.go(Routes.returnDetail(saved.id));
    } on Object {
      // The controller has already put the failure in its state, which the
      // `ref.listen` above turns into a SnackBar.
    }
  }

  /// Shows a message to the user without involving the controller.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The lines of the chosen purchase, each with how many units go back.
class _Lines extends StatelessWidget {
  const _Lines({
    required this.lines,
    required this.quantities,
    required this.onLineChanged,
    required this.onRetry,
  });

  /// The invoice lines, or `null` while no purchase is chosen.
  final AsyncValue<List<ReturnableLine>>? lines;

  /// The current choices.
  final Map<String, int> quantities;

  /// Called with a line's new quantity.
  final void Function(String purchaseItemId, int qty) onLineChanged;

  /// Retries the line read, or `null` when there is nothing to retry.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final state = lines;
    if (state == null) {
      return Text(
        'Choose the purchase these goods came from and its lines appear here.',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    if (state.hasError && !state.hasValue) {
      return ErrorView(message: describeError(state.error!), onRetry: onRetry);
    }
    final value = state.value;
    if (value == null) {
      return const LoadingView(message: 'Loading the invoice lines…');
    }
    if (value.isEmpty) {
      return Text(
        'That purchase has no lines, so there is nothing to send back.',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }

    return Column(
      children: <Widget>[
        for (final line in value)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ReturnLineField(
              key: ValueKey<String>(line.item.id),
              line: line,
              quantity: quantities[line.item.id] ?? 0,
              onChanged: (qty) => onLineChanged(line.item.id, qty),
            ),
          ),
      ],
    );
  }
}

/// One invoice line: what was billed, what is left, and how many go back.
class _ReturnLineField extends StatefulWidget {
  const _ReturnLineField({
    required this.line,
    required this.quantity,
    required this.onChanged,
    super.key,
  });

  /// The invoice line and its limits.
  final ReturnableLine line;

  /// The quantity currently chosen.
  final int quantity;

  /// Called with the new quantity.
  final ValueChanged<int> onChanged;

  @override
  State<_ReturnLineField> createState() => _ReturnLineFieldState();
}

class _ReturnLineFieldState extends State<_ReturnLineField> {
  late final TextEditingController _qty = TextEditingController(
    text: widget.quantity == 0 ? '' : '${widget.quantity}',
  );

  @override
  void initState() {
    super.initState();
    // A listener rather than `onSubmitted`: the parent holds the quantities the
    // write is built from, and on a desktop or in a browser there is no submit
    // key to press - a field that only reported on submit would leave the parent,
    // and the credit preview, believing nothing was going back.
    _qty.addListener(_emit);
  }

  @override
  void dispose() {
    _qty
      ..removeListener(_emit)
      ..dispose();
    super.dispose();
  }

  /// Reports what is typed, treating blank as "nothing goes back".
  void _emit() => widget.onChanged(int.tryParse(_qty.text.trim()) ?? 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = widget.line;
    final item = line.item;
    final name = (item.productNameRaw?.trim().isNotEmpty ?? false)
        ? item.productNameRaw!.trim()
        : 'Line ${item.id}';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              name,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              'Billed ${_units(item.qty)} · already returned '
              '${_units(line.alreadyReturned)} · in the batch '
              '${_units(line.onHand)}'
              '${item.batchNo == null ? '' : ' · batch ${item.batchNo}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (line.canReturn)
              AppTextField(
                controller: _qty,
                label: 'Returning',
                hint: 'Up to ${line.returnable}',
                prefixIcon: Icons.assignment_return_outlined,
                keyboardType: TextInputType.number,
                validator: (value) {
                  final raw = value?.trim() ?? '';
                  if (raw.isEmpty) {
                    return null;
                  }
                  final invalid = Validators.nonNegativeInt(raw);
                  if (invalid != null) {
                    return invalid;
                  }
                  if (int.parse(raw) > line.returnable) {
                    return 'At most ${line.returnable}';
                  }
                  return null;
                },
              )
            else
              Text(
                line.blockedReason ?? 'Nothing can be returned from this line.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The credit the current choices add up to.
///
/// Rendered from the invoice's own stored amounts, with the same helper the write
/// uses, so the preview cannot disagree with what gets stored.
class _CreditPreview extends StatelessWidget {
  const _CreditPreview({required this.lines, required this.quantities});

  /// The invoice lines, if they have loaded.
  final List<ReturnableLine>? lines;

  /// The current choices.
  final Map<String, int> quantities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loaded = lines;
    if (loaded == null || quantities.isEmpty) {
      return const SizedBox.shrink();
    }

    final amounts = <PurchaseReturnLineAmounts>[
      for (final line in loaded)
        if ((quantities[line.item.id] ?? 0) > 0)
          PurchaseReturnTotals.forLine(
            item: line.item,
            qty: quantities[line.item.id]!,
          ),
    ];
    if (amounts.isEmpty) {
      return const SizedBox.shrink();
    }
    final totals = PurchaseReturnTotals.forLines(amounts);

    return SectionCard(
      title: 'Credit',
      child: Column(
        children: <Widget>[
          _AmountRow(
            label: 'Value',
            value: Formatters.currency(totals.subTotal),
          ),
          _AmountRow(label: 'Tax', value: Formatters.currency(totals.taxTotal)),
          const Divider(height: 20),
          _AmountRow(
            label: 'Total credit',
            value: Formatters.currency(totals.grandTotal),
            emphasis: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// One label and amount in the credit preview.
class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.value, this.emphasis});

  /// What the amount is.
  final String label;

  /// The amount, already formatted.
  final String value;

  /// Style for the amount, for the total.
  final TextStyle? emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(value, style: emphasis ?? theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// `12 units`, or `1 unit`.
String _units(int qty) => '$qty ${qty == 1 ? 'unit' : 'units'}';
