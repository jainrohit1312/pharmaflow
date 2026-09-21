/// Raises a return against a sale the customer brought back.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_return.dart';
import 'package:app/features/approvals/presentation/sent_to_owner.dart';
import 'package:app/features/returns/application/sale_return_form_controller.dart';
import 'package:app/features/returns/data/sale_return_totals.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Chooses a sale, the lines coming back, and where the units go.
///
/// The form never asks for money. Every figure on the credit note comes from the
/// sold line's own stored amounts (D-020's rule, applied to the customer side), and
/// the most a line may return is what was billed less what has already come back.
class SaleReturnFormScreen extends ConsumerStatefulWidget {
  /// Creates the sale return form screen.
  const SaleReturnFormScreen({super.key});

  @override
  ConsumerState<SaleReturnFormScreen> createState() =>
      _SaleReturnFormScreenState();
}

class _SaleReturnFormScreenState extends ConsumerState<SaleReturnFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  String? _saleId;
  DateTime _returnDate = DateTime.now();
  bool _restock = true;
  PaymentMode _refundMode = PaymentMode.cash;

  /// Units coming back, keyed by sale-item id. Absent means "this one stays".
  final Map<String, int> _quantities = <String, int>{};

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sales = ref.watch(returnableSalesProvider);
    final saleId = _saleId;
    final returnable = saleId == null
        ? null
        : ref.watch(saleReturnableProvider(saleId));
    final isSaving = ref.watch(saleReturnFormControllerProvider).isLoading;

    ref.listen<AsyncValue<SaleReturn?>>(saleReturnFormControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !mounted) {
        return;
      }
      _report(describeError(error));
    });

    return AppScaffold(
      title: 'New sale return',
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
                  _SaleField(
                    sales: sales,
                    value: saleId,
                    onChanged: _chooseSale,
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
                  AppDropdownField<PaymentMode>(
                    label: 'Refunded by',
                    hint: 'How the money went back',
                    prefixIcon: Icons.payments_outlined,
                    value: _refundMode,
                    values: PaymentMode.values,
                    labelOf: (mode) => mode.label,
                    onChanged: (mode) =>
                        setState(() => _refundMode = mode ?? PaymentMode.cash),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Put the units back in stock'),
                    subtitle: Text(
                      _restock
                          ? 'They go back into the batch they came from.'
                          : 'Damaged or unsellable: the return is recorded, but '
                                'the stock is not restored.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    value: _restock,
                    onChanged: (value) => setState(() => _restock = value),
                  ),
                  const SizedBox(height: 8),
                  AppTextField(
                    controller: _reason,
                    label: 'Reason',
                    hint: 'Damaged, wrong item, customer changed their mind',
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
                saleId: saleId,
                returnable: returnable,
                quantities: _quantities,
                onLineChanged: _setQuantity,
                onRetry: saleId == null
                    ? null
                    : () => ref.invalidate(saleReturnableProvider(saleId)),
              ),
            ),
            const SizedBox(height: 16),
            _CreditPreview(
              returnable: returnable?.value,
              quantities: _quantities,
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'Record return',
              icon: Icons.assignment_return_outlined,
              isLoading: isSaving,
              onPressed: isSaving || saleId == null ? null : _save,
            ),
          ],
        ),
      ),
    );
  }

  /// Switches the bill being credited, dropping the previous line choices.
  void _chooseSale(String? value) => setState(() {
    if (_saleId != value) {
      _quantities.clear();
    }
    _saleId = value;
  });

  /// Records how many units of one line are coming back, or clears it at zero.
  void _setQuantity(String saleItemId, int qty) => setState(() {
    if (qty <= 0) {
      _quantities.remove(saleItemId);
    } else {
      _quantities[saleItemId] = qty;
    }
  });

  /// Validates and writes the return, then opens the sale it credits.
  Future<void> _save() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    // The button is disabled until a bill is chosen, so this is the type system's
    // narrowing rather than a second rule kept in step with it. It used to be both:
    // the picker also carried a "Choose a bill" validator and this branch reported
    // the same thing, and neither could ever reach a user (T-4). The rule lives in
    // the button's `onPressed` now, and nowhere else.
    final saleId = _saleId;
    if (saleId == null) {
      return;
    }
    if (_quantities.isEmpty) {
      _report('Enter how many units are coming back.');
      return;
    }

    try {
      final outcome = await ref
          .read(saleReturnFormControllerProvider.notifier)
          .createReturn(
            saleId: saleId,
            returnDate: _returnDate,
            quantities: Map<String, int>.of(_quantities),
            restock: _restock,
            refundMode: _refundMode,
            reason: _reason.text,
          );
      if (!mounted) {
        return;
      }
      // The bill is the context for a return, and there is no return screen of its
      // own: opening the sale shows both what was sold and what came back.
      //
      // Unless the return is a REQUEST, which for anybody but the owner it is: then
      // nothing was written, so there is nothing new to see on the bill and the work
      // is in the owner's queue.
      if (outcome.document case final saved?) {
        context.go(Routes.saleDetail(saved.saleId));
        return;
      }
      showSentToOwnerNotice(context, message: sentForApprovalMessage);
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

/// The sale picker, with the read's three states.
class _SaleField extends StatelessWidget {
  const _SaleField({
    required this.sales,
    required this.value,
    required this.onChanged,
  });

  /// The sales on offer, or the failed read.
  final AsyncValue<List<Sale>> sales;

  /// The selected sale id.
  final String? value;

  /// Called with the chosen id.
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (sales.hasError && !sales.hasValue) {
      return Text(
        describeError(sales.error!),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    final options = sales.value ?? const <Sale>[];
    return AppDropdownField<String>(
      label: 'Bill',
      // Three states, three hints. `sales.value` is null while the read is still
      // in flight, and taking its length was how this field rendered "No sales yet"
      // for a pharmacy it had not finished asking - an empty, disabled picker with
      // no way to tell the two apart (T-5). `enabled` follows the options, so a
      // loading picker stays untappable either way.
      hint: sales.value == null
          ? 'Loading the bills…'
          : (options.isEmpty ? 'No sales yet' : 'Which bill'),
      prefixIcon: Icons.receipt_long_outlined,
      value: value,
      values: options.map((sale) => sale.id).toList(growable: false),
      labelOf: (id) => _saleLabel(options, id),
      enabled: options.isNotEmpty,
      onChanged: onChanged,
    );
  }
}

/// The label for a sale in the picker: invoice, then when.
String _saleLabel(List<Sale> sales, String id) {
  for (final sale in sales) {
    if (sale.id == id) {
      return '${sale.invoiceNo} · '
          '${Formatters.dateDdMmmYyyy(sale.saleDate)} · '
          '${Formatters.currency(sale.grandTotal)}';
    }
  }
  return 'Another bill';
}

/// The lines of the chosen sale, each with how many units come back.
class _Lines extends StatelessWidget {
  const _Lines({
    required this.saleId,
    required this.returnable,
    required this.quantities,
    required this.onLineChanged,
    required this.onRetry,
  });

  /// The chosen sale, or `null` while none is chosen.
  final String? saleId;

  /// What can come back, or the read's state.
  final AsyncValue<SaleReturnable>? returnable;

  /// The current choices.
  final Map<String, int> quantities;

  /// Called with a line's new quantity.
  final void Function(String saleItemId, int qty) onLineChanged;

  /// Retries the line read, or `null` when there is nothing to retry.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final state = returnable;
    if (state == null) {
      return Text(
        'Choose the bill these goods were sold on and its lines appear here.',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    if (state.hasError && !state.hasValue) {
      return ErrorView(message: describeError(state.error!), onRetry: onRetry);
    }
    final value = state.value;
    if (value == null) {
      return const LoadingView(message: 'Loading the sold lines…');
    }
    if (value.lines.isEmpty) {
      return Text(
        'That sale has no lines, so there is nothing to return.',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }

    return Column(
      children: <Widget>[
        for (final line in value.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ReturnLineField(
              key: ValueKey<String>(line.item.id),
              line: line,
              name: saleReturnableName(value, line),
              quantity: quantities[line.item.id] ?? 0,
              onChanged: (qty) => onLineChanged(line.item.id, qty),
            ),
          ),
      ],
    );
  }
}

/// One sold line: what was billed, what is left, and how many come back.
class _ReturnLineField extends StatefulWidget {
  const _ReturnLineField({
    required this.line,
    required this.name,
    required this.quantity,
    required this.onChanged,
    super.key,
  });

  /// The sold line and its limits.
  final SaleReturnableLine line;

  /// What the product is called.
  final String name;

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
    // A listener rather than `onSubmitted`: a browser and a desktop have no submit
    // key, and the credit preview has to follow every keystroke.
    _qty.addListener(_emit);
  }

  @override
  void dispose() {
    _qty
      ..removeListener(_emit)
      ..dispose();
    super.dispose();
  }

  /// Reports what is typed, treating blank as "nothing comes back".
  void _emit() => widget.onChanged(int.tryParse(_qty.text.trim()) ?? 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = widget.line;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.name,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              'Sold ${_units(line.item.qty)} · already returned '
              '${_units(line.alreadyReturned)} · '
              '${Formatters.currency(line.item.rate)} each',
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
                line.blockedReason ?? 'Nothing can come back from this line.',
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
class _CreditPreview extends StatelessWidget {
  const _CreditPreview({required this.returnable, required this.quantities});

  /// What can come back, if it has loaded.
  final SaleReturnable? returnable;

  /// The current choices.
  final Map<String, int> quantities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loaded = returnable;
    if (loaded == null || quantities.isEmpty) {
      return const SizedBox.shrink();
    }

    final amounts = <SaleReturnLineAmounts>[
      for (final line in loaded.lines)
        if ((quantities[line.item.id] ?? 0) > 0)
          SaleReturnTotals.forLine(
            item: line.item,
            qty: quantities[line.item.id]!,
          ),
    ];
    if (amounts.isEmpty) {
      return const SizedBox.shrink();
    }
    final totals = SaleReturnTotals.forLines(amounts);

    return SectionCard(
      title: 'Refund',
      child: Column(
        children: <Widget>[
          _AmountRow(
            label: 'Value',
            value: Formatters.currency(totals.subTotal),
          ),
          _AmountRow(label: 'Tax', value: Formatters.currency(totals.taxTotal)),
          const Divider(height: 20),
          _AmountRow(
            label: 'Total refund',
            value: Formatters.currency(totals.grandTotal),
            emphasis: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// One label and amount in the refund preview.
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
