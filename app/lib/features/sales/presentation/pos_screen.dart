/// The counter: search a product, pick its batch, take payment.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:app/features/sales/application/sale_checkout_controller.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/presentation/patients/patient_step.dart';
import 'package:app/features/sales/presentation/widgets/batch_chooser_sheet.dart';
import 'package:app/features/sales/presentation/widgets/pos_search_results.dart';
import 'package:app/features/sales/presentation/widgets/sale_identity_fields.dart';
import 'package:app/features/sales/presentation/widgets/sale_type_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// The product search's field, driven rather than left to the widget: a
  /// selection, a dialog and a refusal all have to empty it and put the caret back.
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _term = '';

  /// Which row of the dropdown Enter would add, as an index into the results.
  int _highlighted = 0;

  /// Whether Escape has closed the dropdown for the current term.
  ///
  /// Reset by the next keystroke, so Escape dismisses the list without ending the
  /// search.
  bool _searchClosed = false;

  @override
  void dispose() {
    _debounce.dispose();
    _tender.dispose();
    _placeOfSupply.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Applies a search term once the counter stops typing.
  void _searchChanged(String value) {
    final trimmed = value.trim();
    _debounce.run(() {
      if (!mounted || trimmed == _term) {
        return;
      }
      setState(() {
        _term = trimmed;
        // A new term is a new list, so the highlight goes back to the top rather
        // than pointing at a row of the previous search - and a keystroke reopens
        // the list Escape closed.
        _highlighted = 0;
        _searchClosed = false;
      });
    });
  }

  /// How many rows the dropdown is actually showing, or 0 when it is not.
  ///
  /// Not simply the results' length: the dropdown is hidden while the field is
  /// empty **and** something is already rung up, and Enter must not add a product
  /// the counter cannot see. This is the guard that makes "Enter never adds
  /// something invisible" true.
  int get _shownResults {
    if (_searchClosed ||
        (_term.isEmpty && ref.read(posControllerProvider).isNotEmpty)) {
      return 0;
    }
    return ref.read(posSearchResultsProvider(_term)).value?.length ?? 0;
  }

  /// The counter's keyboard contract for the keys the field itself does not use.
  ///
  /// Arrows move the highlight, Enter adds the highlighted row, and Escape closes
  /// the list. Every key this returns `ignored` for is left alone, so Tab still
  /// moves focus and typing still reaches the field - a character is consumed by
  /// the field before this node is ever asked.
  ///
  /// **Enter never checks out.** The only way to write the sale is the button,
  /// which is why a keyboard mistake at the counter cannot take money.
  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (!_searchClosed && _term.isNotEmpty) {
        // Closes the list and claims nothing else: Escape steps back out of the
        // search, it never empties a basket a cashier is mid-way through.
        setState(() => _searchClosed = true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final count = _shownResults;
    if (count == 0) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlighted = (_highlighted + 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlighted = (_highlighted - 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _addHighlighted();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Adds the row Enter is on, if the dropdown is showing one.
  void _addHighlighted() {
    if (_shownResults == 0) {
      return;
    }
    final hits =
        ref.read(posSearchResultsProvider(_term)).value ??
        const <PosSearchHit>[];
    if (_highlighted < 0 || _highlighted >= hits.length) {
      return;
    }
    _addHit(hits[_highlighted]);
  }

  /// Adds [hit]'s FEFO batch, or says why it cannot.
  ///
  /// The batch is taken from the hit rather than read again: it is the same value
  /// the row showed, so what the counter saw is what it gets. The add is synchronous
  /// for the same reason, which is half of what stops a rapid double Enter - the
  /// other half is [_resetSearch] closing the list.
  void _addHit(PosSearchHit hit) {
    final batch = hit.dispensable;
    if (batch == null) {
      _report('Nothing in stock for ${hit.product.name}.');
      return;
    }
    ref
        .read(posControllerProvider.notifier)
        .addLine(product: hit.product, batch: batch, qty: 1);
    _resetSearch();
  }

  /// Empties the field, closes the list and puts the caret back.
  ///
  /// This is what makes a rapid second Enter harmless: with no term and a basket
  /// that is no longer empty the dropdown is not showing, so a second press has
  /// nothing to add and cannot double-add.
  void _resetSearch() {
    _debounce.cancel();
    _search.clear();
    setState(() {
      _term = '';
      _highlighted = 0;
      _searchClosed = true;
    });
    _searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(posControllerProvider);
    final pos = ref.read(posControllerProvider.notifier);
    final isSaving = ref.watch(saleCheckoutControllerProvider).isLoading;
    final split =
        ref.watch(saleTaxSplitProvider(cart.placeOfSupply)).value ??
        TaxSplit.intraState;
    final totals = SaleTotals.forLines(
      cart.lines,
      split: split,
      saleType: cart.saleType,
    );
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
          // The order of the screen is the order of the transaction: who the bill is
          // for, what kind of sale it is, the details that type asks for, then the
          // medicines and the money. The first three are not decoration - the server
          // refuses a sale whose identity and type are missing (D-067, D-074).
          //
          // A transfer names nobody, so the patient step goes away with the type
          // rather than asking for something the payload will not carry.
          if (cart.saleType != SaleType.transfer) ...<Widget>[
            SectionCard(
              title: 'Patient',
              child: PatientStep(cart: cart),
            ),
            const SizedBox(height: 16),
          ],
          SectionCard(
            title: 'Sale type',
            child: SaleTypeSelector(
              value: cart.saleType,
              // A cost-priced basis cannot be chosen under a rung-up basket, which
              // `setSaleType` refuses; the control says the same thing by going
              // quiet, so a tap cannot produce an error nobody can act on.
              enabled: cart.isEmpty || cart.saleType.isPharmacySale,
              onChanged: pos.setSaleType,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: cart.saleType == SaleType.transfer
                ? 'Transfer'
                : 'Prescription & hospital',
            child: SaleIdentityFields(cart: cart),
          ),
          const SizedBox(height: 16),
          // The counter's working surface: type or scan, press Enter, next line.
          // The field takes the caret on load, and the Focus above it is where the
          // keys the field does not use are caught (arrows, Enter, Escape) - it is
          // not focusable itself, so the caret stays in the field.
          Focus(
            canRequestFocus: false,
            onKeyEvent: _onSearchKey,
            child: AppSearchField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              hint: 'Search by name, generic or barcode',
              onChanged: _searchChanged,
              // The platform's own submit (a mobile search key, a desktop Enter the
              // field consumes): the same action as the raw Enter above, and safe
              // beside it because a second one finds the list already closed.
              onSubmitted: (_) => _addHighlighted(),
            ),
          ),
          if (!_searchClosed && (_term.isNotEmpty || cart.isEmpty)) ...<Widget>[
            const SizedBox(height: 8),
            PosSearchResults(
              term: _term,
              highlighted: _highlighted,
              onAdd: _addHit,
              onChooseBatch: _chooseBatch,
            ),
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
                            saleType: cart.saleType,
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
  ///
  /// The deliberate path rather than the default one: Enter takes the FEFO batch,
  /// and this is what a counter uses when the customer asked for a later expiry -
  /// so the chooser is still here, just not in the way of the common case.
  Future<void> _chooseBatch(Product product) async {
    final batch = await showBatchChooser(context, product: product);
    if (batch == null || !mounted) {
      return;
    }
    ref
        .read(posControllerProvider.notifier)
        .addLine(product: product, batch: batch, qty: 1);
    _resetSearch();
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

/// Formats [value] for a text field, leaving off a trailing `.0`.
String _numberText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
