/// The counter: search a product, pick its batch, take payment.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/products/application/product_search.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sale_checkout_controller.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/presentation/widgets/batch_chooser_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The point of sale.
///
/// The order of the screen is the order of the transaction: find the product, say
/// which batch it came out of, then settle up. Stock leaves the batch when the sale
/// is written (`checkout_sale`, one transaction), so nothing here has to remember
/// to move anything.
class PosScreen extends ConsumerStatefulWidget {
  /// Creates the counter screen.
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _debounce = Debouncer();
  final _tender = TextEditingController();
  final _placeOfSupply = TextEditingController();
  String _term = '';

  @override
  void dispose() {
    _debounce.dispose();
    _tender.dispose();
    _placeOfSupply.dispose();
    super.dispose();
  }

  /// Applies a search term once the user stops typing.
  void _search(String value) {
    final trimmed = value.trim();
    if (trimmed == _term) {
      return;
    }
    _debounce.run(() {
      if (mounted) {
        setState(() => _term = trimmed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(posControllerProvider);
    final pos = ref.read(posControllerProvider.notifier);
    final isSaving = ref.watch(saleCheckoutControllerProvider).isLoading;
    // A failed customer read costs the picker its options, not the counter its
    // basket, so it is read leniently.
    final customers =
        ref.watch(customerOptionsProvider).value ?? const <Customer>[];
    final split =
        ref.watch(saleTaxSplitProvider(cart.placeOfSupply)).value ??
        TaxSplit.intraState;
    final totals = SaleTotals.forLines(cart.lines, split: split);
    final paid = cart.paidFor(totals.grandTotal);
    final change = SaleTotals.changeFor(
      tendered: _tenderedValue(totals.grandTotal, cart),
      total: totals.grandTotal,
    );

    ref.listen<AsyncValue<Sale?>>(saleCheckoutControllerProvider, (
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
      title: 'New sale',
      leading: const AppBackButton(
        location: Routes.sales,
        tooltip: 'Back to sales',
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          AppSearchField(
            hint: 'Search by name, generic or barcode',
            onChanged: _search,
          ),
          if (_term.isNotEmpty || cart.isEmpty) ...<Widget>[
            const SizedBox(height: 8),
            _SearchResults(term: _term, onSelected: _chooseBatch),
          ],
          const SizedBox(height: 16),
          SectionCard(
            title: 'Basket',
            trailing: cart.isEmpty
                ? null
                : AppButton.text(
                    label: 'Clear',
                    icon: Icons.delete_sweep_outlined,
                    expand: false,
                    onPressed: pos.clear,
                  ),
            child: cart.isEmpty
                ? Text(
                    'Nothing rung up yet. Search for a product above.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                : Column(
                    children: <Widget>[
                      for (
                        var index = 0;
                        index < cart.lines.length;
                        index++
                      ) ...<Widget>[
                        _CartLineTile(
                          key: ValueKey<String>(cart.lines[index].batchId),
                          line: cart.lines[index],
                          lineTotal: SaleTotals.forLine(
                            cart.lines[index],
                            split: split,
                          ).total,
                          onQty: (qty) =>
                              pos.setQty(cart.lines[index].batchId, qty),
                          onRate: (rate) =>
                              pos.setRate(cart.lines[index].batchId, rate),
                          onDiscount: (percent) => pos.setDiscount(
                            cart.lines[index].batchId,
                            percent,
                          ),
                          onGst: (percent) =>
                              pos.setGst(cart.lines[index].batchId, percent),
                          onRemove: () =>
                              pos.removeLine(cart.lines[index].batchId),
                        ),
                        if (index < cart.lines.length - 1)
                          const Divider(height: 24),
                      ],
                    ],
                  ),
          ),
          if (cart.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            SectionCard(
              title: 'Payment',
              child: Column(
                children: <Widget>[
                  AppDropdownField<String>(
                    label: 'Customer',
                    hint: 'Walk-in',
                    prefixIcon: Icons.person_outline,
                    value: cart.customerId,
                    values: _customerIds(customers, cart.customerId),
                    labelOf: (id) => _customerName(customers, id),
                    allowNone: true,
                    onChanged: pos.setCustomer,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final mode in PaymentMode.values)
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: cart.paymentMode == mode,
                          onSelected: (selected) => pos.setPaymentMode(mode),
                        ),
                    ],
                  ),
                  if (!cart.paymentMode.isOnAccount) ...<Widget>[
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _tender,
                      label: 'Received',
                      hint: 'Leave blank when the exact amount was paid',
                      prefixIcon: Icons.payments_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: Validators.nonNegativeDecimalIfPresent,
                      onChanged: (value) =>
                          pos.setTendered(double.tryParse(value.trim()) ?? 0),
                    ),
                  ],
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: _placeOfSupply,
                    label: 'Place of supply',
                    hint: 'Blank means the pharmacy\u2019s own state',
                    prefixIcon: Icons.place_outlined,
                    onChanged: (value) => pos.setPlaceOfSupply(
                      value.trim().isEmpty ? null : value.trim(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _TotalsPanel(
              totals: totals,
              split: split,
              paid: paid,
              change: change,
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'Take payment',
              icon: Icons.check,
              isLoading: isSaving,
              onPressed: isSaving ? null : () => _checkout(cart, split),
            ),
          ],
        ],
      ),
    );
  }

  /// Opens the batch chooser for [product] and adds what was picked.
  Future<void> _chooseBatch(Product product) async {
    final batch = await showBatchChooser(context, product: product);
    if (batch == null || !mounted) {
      return;
    }
    ref
        .read(posControllerProvider.notifier)
        .addLine(product: product, batch: batch, qty: 1);
  }

  /// Writes the sale and opens its invoice.
  Future<void> _checkout(PosCart cart, TaxSplit split) async {
    try {
      final saved = await ref
          .read(saleCheckoutControllerProvider.notifier)
          .checkout(cart: cart, split: split);
      if (!mounted) {
        return;
      }
      // The basket is gone with the sale, so the fields that described it are
      // cleared too - a tender left over from the last customer would be applied
      // to the next one.
      _tender.clear();
      _placeOfSupply.clear();
      context.go(Routes.saleDetail(saved.id));
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

/// The raw tender for a bill, whether or not one was typed.
///
/// The screen needs the *tendered* figure to work out the change; the figure that
/// gets stored is [PosCart.paidFor], which clamps it.
double _tenderedValue(double grandTotal, PosCart cart) => cart.tendered > 0
    ? cart.tendered
    : (cart.paymentMode.isOnAccount ? 0 : grandTotal);

/// The product search results, while a term is being typed.
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.term, required this.onSelected});

  /// The term to search for.
  final String term;

  /// Called with the product that was tapped.
  final ValueChanged<Product> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(productSearchProvider(term));
    final theme = Theme.of(context);

    if (results.hasValue) {
      final products = results.value!;
      if (products.isEmpty) {
        return Text(
          'No product matches "$term".',
          style: theme.textTheme.bodySmall,
        );
      }
      return Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: <Widget>[
            for (final product in products)
              ListTile(
                dense: true,
                title: Text(product.name),
                subtitle: Text(
                  <String>[
                    if (product.genericName != null) product.genericName!,
                    if (product.packSize != null) product.packSize!,
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.add_circle_outline),
                onTap: () => onSelected(product),
              ),
          ],
        ),
      );
    }

    if (results.hasError) {
      return Text(
        describeError(results.error!),
        style: theme.textTheme.bodySmall,
      );
    }

    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: LinearProgressIndicator(),
    );
  }
}

/// One basket line, with everything the counter may change about it.
class _CartLineTile extends StatefulWidget {
  const _CartLineTile({
    required this.line,
    required this.lineTotal,
    required this.onQty,
    required this.onRate,
    required this.onDiscount,
    required this.onGst,
    required this.onRemove,
    super.key,
  });

  /// The line as the basket holds it.
  final SaleCartLine line;

  /// What the line comes to, already worked out.
  final double lineTotal;

  /// Called with the new quantity.
  final ValueChanged<int> onQty;

  /// Called with the new rate.
  final ValueChanged<double> onRate;

  /// Called with the new discount percentage.
  final ValueChanged<double> onDiscount;

  /// Called with the new GST slab.
  final ValueChanged<double> onGst;

  /// Called when the line is removed.
  final VoidCallback onRemove;

  @override
  State<_CartLineTile> createState() => _CartLineTileState();
}

class _CartLineTileState extends State<_CartLineTile> {
  late final TextEditingController _qty = TextEditingController(
    text: '${widget.line.qty}',
  );
  late final TextEditingController _rate = TextEditingController(
    text: _numberText(widget.line.rate),
  );
  late final TextEditingController _discount = TextEditingController(
    text: _numberText(widget.line.discountPercent),
  );
  late final TextEditingController _gst = TextEditingController(
    text: _numberText(widget.line.gstPercent),
  );

  @override
  void initState() {
    super.initState();
    // Listeners rather than `onSubmitted`: a browser and a desktop have no submit
    // key, and the basket's totals must follow every keystroke (the bug the
    // purchase-return form paid for).
    _qty.addListener(() => widget.onQty(int.tryParse(_qty.text.trim()) ?? 0));
    _rate.addListener(
      () => widget.onRate(double.tryParse(_rate.text.trim()) ?? 0),
    );
    _discount.addListener(
      () => widget.onDiscount(double.tryParse(_discount.text.trim()) ?? 0),
    );
    _gst.addListener(
      () => widget.onGst(double.tryParse(_gst.text.trim()) ?? 0),
    );
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _qty,
      _rate,
      _discount,
      _gst,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = widget.line;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                line.productName,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              Formatters.currency(widget.lineTotal),
              style: theme.textTheme.titleSmall,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove this line',
              onPressed: widget.onRemove,
            ),
          ],
        ),
        Text('Batch ${line.batchNo}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: AppTextField(
                controller: _qty,
                label: 'Qty',
                keyboardType: TextInputType.number,
                validator: Validators.positiveInt,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppTextField(
                controller: _rate,
                label: 'Rate',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: Validators.nonNegativeDecimal,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppTextField(
                controller: _discount,
                label: 'Disc %',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: Validators.percentIfPresent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppTextField(
                controller: _gst,
                label: 'GST %',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: Validators.percentIfPresent,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The bill: what it adds up to, and what comes back.
class _TotalsPanel extends StatelessWidget {
  const _TotalsPanel({
    required this.totals,
    required this.split,
    required this.paid,
    required this.change,
  });

  /// The document totals for the basket.
  final SaleDocumentTotals totals;

  /// Which tax heads the amount sits under.
  final TaxSplit split;

  /// What the sale will record as paid.
  final double paid;

  /// What is handed back.
  final double change;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Bill',
      child: Column(
        children: <Widget>[
          _AmountRow(
            label: 'Value',
            value: Formatters.currency(totals.subTotal),
          ),
          if (totals.discountTotal > 0)
            _AmountRow(
              label: 'Discount',
              value: '-${Formatters.currency(totals.discountTotal)}',
            ),
          _AmountRow(
            label: split == TaxSplit.intraState ? 'CGST + SGST' : 'IGST',
            value: Formatters.currency(totals.taxTotal),
          ),
          const Divider(height: 20),
          _AmountRow(
            label: 'Total',
            value: Formatters.currency(totals.grandTotal),
            emphasis: theme.textTheme.titleMedium,
          ),
          _AmountRow(label: 'Paid', value: Formatters.currency(paid)),
          if (change > 0)
            _AmountRow(label: 'Change', value: Formatters.currency(change)),
          if (paid < totals.grandTotal)
            _AmountRow(
              label: 'Balance due',
              value: Formatters.currency(totals.grandTotal - paid),
            ),
        ],
      ),
    );
  }
}

/// One label and amount in the bill.
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

/// The ids a customer dropdown may offer: every customer, plus the one already
/// chosen even when it is not in the page that loaded.
List<String> _customerIds(List<Customer> customers, String? selected) {
  final ids = <String>[
    for (final customer in customers)
      if (customer.isActive || customer.id == selected) customer.id,
  ];
  if (selected != null && !ids.contains(selected)) {
    ids.insert(0, selected);
  }
  return ids;
}

/// The name of [id], or a placeholder when the list has not loaded.
String _customerName(List<Customer> customers, String id) {
  for (final customer in customers) {
    if (customer.id == id) {
      return customer.name;
    }
  }
  return 'Currently selected customer';
}

/// Formats [value] for a text field, leaving off a trailing `.0`.
String _numberText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
