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
import 'package:app/features/products/application/product_categories.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:app/features/sales/application/sale_checkout_controller.dart';
import 'package:app/features/sales/application/sale_requirements.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/presentation/patients/patient_step.dart';
import 'package:app/features/sales/presentation/widgets/batch_chooser_sheet.dart';
import 'package:app/features/sales/presentation/widgets/payment_confirmation.dart';
import 'package:app/features/sales/presentation/widgets/pos_cart_line.dart';
import 'package:app/features/sales/presentation/widgets/pos_search_results.dart';
import 'package:app/features/sales/presentation/widgets/pos_strip.dart';
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

  /// The bill-level discount, driven rather than left to the widget: the write clears it
  /// with the rest of the bill once the sale is saved, so a discount cannot leak onto the
  /// next customer's bill.
  final _billDiscount = TextEditingController();

  /// The product search's field, driven rather than left to the widget: a
  /// selection, a dialog and a refusal all have to empty it and put the caret back.
  final _search = TextEditingController();

  /// Labelled so the keyboard contract is **assertable**: "the caret went to the new line's
  /// quantity" and "Escape brought it back here" are things a test can now name, the same way
  /// the cart line labels its own nodes.
  final _searchFocus = FocusNode(debugLabel: 'pos search');
  String _term = '';

  /// Which row of the dropdown Enter would add, as an index into the results.
  int _highlighted = 0;

  /// Which strip tab the counter has chosen, when no term has been typed.
  ///
  /// Recent, because re-selling what was just sold is the commonest action at a
  /// counter - and a tab is a list key, so this is the same value the list reads.
  PosListKey _strip = PosStrip.recent;

  /// Whether Escape has closed the dropdown for the current term.
  ///
  /// Reset by the next keystroke, so Escape dismisses the list without ending the
  /// search.
  bool _searchClosed = false;

  /// Whether the confirmation dialog is already up.
  ///
  /// The dialog is a **second** window a double tap can land in, and the newer of the
  /// two: no write has started while it is open, so the live-state guard in `_checkout`
  /// cannot see the second tap the way it sees one arriving during a write.
  bool _confirming = false;

  /// The line whose quantity field should take the caret, once it is built.
  ///
  /// Set by an add and cleared by the line that answers it, so the request is a **one-shot**:
  /// a line rung up at the counter puts the caret in its own quantity - where the operator
  /// nearly always goes next - and nothing later in the basket's life may pull it back there.
  String? _pendingQtyFocus;

  /// What the counter's list is showing: the search when a term is typed - a term
  /// wins over the strip, because typing is an explicit act - and the strip's own
  /// tab otherwise.
  PosListKey get _listKey =>
      PosListKey(term: _term, recent: _strip.recent, category: _strip.category);

  @override
  void dispose() {
    _debounce.dispose();
    _tender.dispose();
    _placeOfSupply.dispose();
    _billDiscount.dispose();
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
  /// Not simply the results' length: the list is hidden once Escape has closed it
  /// and after every add, and Enter must not add a product the counter cannot see.
  /// This is the guard that makes "Enter never adds something invisible" true.
  int get _shownResults {
    if (_searchClosed) {
      return 0;
    }
    return ref.read(posListProvider(_listKey)).value?.length ?? 0;
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
        ref.read(posListProvider(_listKey)).value ?? const <PosSearchHit>[];
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
    // The caret goes to the line just rung up, so the operator can change the quantity
    // without reaching for the mouse: a counter rings a line up and then very often says
    // "make it two".
    _pendingQtyFocus = batch.id;
    _resetSearch(refocusSearch: false);
  }

  /// Empties the field, closes the list and puts the caret back.
  ///
  /// This is what makes a rapid second Enter harmless: with no term and a basket
  /// that is no longer empty the dropdown is not showing, so a second press has
  /// nothing to add and cannot double-add.
  ///
  /// [refocusSearch] is false **after an add**, where the caret belongs in the new line's
  /// quantity instead. The list still closes, which is the half that keeps a second Enter
  /// harmless - so moving the caret costs nothing.
  void _resetSearch({bool refocusSearch = true}) {
    _debounce.cancel();
    _search.clear();
    setState(() {
      _term = '';
      _highlighted = 0;
      _searchClosed = true;
    });
    if (refocusSearch) {
      _searchFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(posControllerProvider);
    final pos = ref.read(posControllerProvider.notifier);
    final isSaving = ref.watch(saleCheckoutControllerProvider).isLoading;
    // Read leniently: a failed categories read costs the strip its middle tabs, not
    // the counter its sale - the same choice the package picker makes about accounts.
    final categories =
        ref.watch(productCategoriesProvider).value ?? const <String>[];
    final split =
        ref.watch(saleTaxSplitProvider(cart.placeOfSupply)).value ??
        TaxSplit.intraState;
    // The lines and the header out of ONE walk, so the discount the counter types and the
    // totals it watches move together - and so the figures on screen are the figures the
    // write sends (D-075's whole point).
    final priced = SaleTotals.price(
      cart.lines,
      split: split,
      saleType: cart.saleType,
      billDiscount: cart.billDiscount,
    );
    final totals = priced.totals;
    final paid = cart.paidFor(totals.grandTotal);
    final change = SaleTotals.changeFor(
      tendered: SaleTotals.tenderedFor(
        grandTotal: totals.grandTotal,
        tendered: cart.tendered,
        isOnAccount: cart.paymentMode.isOnAccount,
      ),
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
      // A refusal leaves the counter where it was working: the caret goes back to
      // the field it will type into next, so the keyboard contract survives an
      // error as well as a selection.
      _searchFocus.requestFocus();
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
          // The counter's working surface: pick a tab or type, press Enter, next
          // line. The strip decides what the list shows while the field is empty,
          // and the field takes the caret on load.
          PosStrip(
            choice: _strip,
            categories: categories,
            onChanged: _chooseStrip,
          ),
          const SizedBox(height: 8),
          // The Focus is where the keys the field does not use are caught (arrows,
          // Enter, Escape); it is not focusable itself, so the caret stays in the
          // field.
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
          if (!_searchClosed) ...<Widget>[
            const SizedBox(height: 8),
            PosSearchResults(
              listKey: _listKey,
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
                // The group, with an ordered policy, is what makes the line
                // widget's own FocusTraversalOrders mean anything: Tab walks the
                // quantities in basket order rather than the tree's.
                : FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Column(
                      children: <Widget>[
                        for (
                          var index = 0;
                          index < cart.lines.length;
                          index++
                        ) ...<Widget>[
                          PosCartLine(
                            key: ValueKey<String>(cart.lines[index].batchId),
                            line: cart.lines[index],
                            order: index,
                            // The line's own total, with its share of the bill's discount
                            // already off it - the figure the receipt will print for it.
                            lineTotal: priced.lines[index].total,
                            focusQty:
                                _pendingQtyFocus == cart.lines[index].batchId,
                            onQtyFocused: () {
                              if (_pendingQtyFocus != null) {
                                setState(() => _pendingQtyFocus = null);
                              }
                            },
                            // Enter **and** Escape in a quantity step back out to the search,
                            // which is what lets a whole bill be rung up from the keyboard -
                            // one product after another, without the mouse. Neither clears the
                            // quantity and neither touches the basket.
                            onReturnToSearch: _searchFocus.requestFocus,
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
              discount: _billDiscount,
              onDiscountChanged: pos.setBillDiscount,
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

  /// Switches the strip's tab, and reopens the list with it.
  void _chooseStrip(PosListKey choice) {
    setState(() {
      _strip = choice;
      // Choosing a tab is a request to see that list, so a list that Escape or an
      // add closed comes back - and the highlight goes back to the first row.
      _searchClosed = false;
      _highlighted = 0;
    });
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
    // The deliberate path takes the caret to the line as well: it is still an add, and the
    // operator who opened the chooser wants the quantity next as much as anyone.
    _pendingQtyFocus = batch.id;
    _resetSearch(refocusSearch: false);
  }

  /// Confirms the bill, writes it, and opens its invoice.
  ///
  /// Two steps, in this order, because only one of the two can be the truth (D-075):
  ///
  ///  1. the counter shows what it is about to write - its own total, computed on the
  ///     server's basis - and the operator confirms it;
  ///  2. the server writes the sale and answers with the stored row. Nothing is shown as
  ///     written, and nothing is printed, until it does.
  ///
  /// Every refusal happens **before** the dialog, so the operator is never asked to
  /// confirm a sale the counter is about to refuse.
  Future<void> _checkout(PosCart cart, TaxSplit split) async {
    // A second tap (or key) is the same submission, not another sale. The button is
    // already disabled while a write is in flight, but a rebuild happens a frame after
    // the tap does - so the live state decides this rather than the state this build
    // drew from. `_confirming` covers the other window: a second tap arriving while the
    // confirmation is up, when no write has started and `isLoading` is still false.
    if (_confirming || ref.read(saleCheckoutControllerProvider).isLoading) {
      return;
    }

    // The same walk the screen drew from, so the dialog the operator confirms and the
    // figures that were on screen behind it cannot be two different bills.
    final totals = SaleTotals.price(
      cart.lines,
      split: split,
      saleType: cart.saleType,
      billDiscount: cart.billDiscount,
    ).totals;

    // What the document itself needs, asked through the same provider the write uses, so
    // the counter cannot check one question here and the write another. Every refusal
    // happens **before** the dialog: asking an operator to confirm a sale the counter is
    // about to refuse spends the one moment they are looking at the screen.
    final refusal = saleRefusal(
      cart: cart,
      packageMarkupPercent: await ref.read(
        packageMarkupPercentProvider(cart.saleType).future,
      ),
    );
    if (!mounted) {
      return;
    }
    if (refusal != null) {
      _report(refusal);
      _searchFocus.requestFocus();
      return;
    }

    // The counter's own completeness rule, the one the server does not have: it refuses
    // a sale paid *more* than its bill and turns any shortfall into a balance whatever
    // the mode says, so a "cash" sale carrying a balance is storable - and is not
    // something this counter should write.
    final paymentRefusal = paymentModeRefusal(
      cart: cart,
      grandTotal: totals.grandTotal,
    );
    if (paymentRefusal != null) {
      _report(paymentRefusal);
      _searchFocus.requestFocus();
      return;
    }

    // Step one: the counter shows what it is about to write and the operator confirms
    // it. Nothing has been written at this point.
    _confirming = true;
    final confirmed = await showPaymentConfirmation(
      context,
      cart: cart,
      totals: totals,
    );
    _confirming = false;
    if (!mounted) {
      return;
    }
    if (!confirmed) {
      // A cancelled confirmation is not an error, so nothing is reported: the caret goes
      // back to the field the operator will type into next.
      _searchFocus.requestFocus();
      return;
    }

    try {
      // Step two: the server writes it and answers with the stored row.
      final saved = await ref
          .read(saleCheckoutControllerProvider.notifier)
          .checkout(cart: cart, split: split);
      if (!mounted) {
        return;
      }
      // The basket is gone with the sale, so the fields that described it are
      // cleared too - a tender left over from the last customer would be applied
      // to the next one, and so would a discount.
      _tender.clear();
      _placeOfSupply.clear();
      _billDiscount.clear();

      // The server's figures against the ones the dialog just showed. They agree in the
      // ordinary case - the client computes on the server's basis - and a disagreement is
      // named rather than hidden, because the bill the customer is about to be handed is
      // the server's version of this sale and not the counter's.
      if (!SaleTotals.matchesStored(shown: totals, stored: saved)) {
        await showVerifiedTotals(context, shown: totals, stored: saved);
        if (!mounted) {
          return;
        }
      }

      context.go(Routes.saleDetail(saved.id));
    } on Object {
      // The controller has already put the failure in its state, which the
      // `ref.listen` above turns into a SnackBar. Nothing is shown as written.
    }
  }

  /// Shows a message to the user without involving the controller.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The bill: what it adds up to, and what comes back.
class _TotalsPanel extends StatelessWidget {
  const _TotalsPanel({
    required this.totals,
    required this.split,
    required this.paid,
    required this.change,
    required this.discount,
    required this.onDiscountChanged,
  });

  /// The document totals for the basket.
  final SaleDocumentTotals totals;

  /// Which tax heads the amount sits under.
  final TaxSplit split;

  /// What the sale will record as paid.
  final double paid;

  /// What is handed back.
  final double change;

  /// The bill-level discount's own field, owned by the screen.
  final TextEditingController discount;

  /// Called with the discount in rupees, on every keystroke.
  final ValueChanged<double> onDiscountChanged;

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
          _AmountRow(
            label: split == TaxSplit.intraState ? 'CGST + SGST' : 'IGST',
            value: Formatters.currency(totals.taxTotal),
          ),
          // The bill's own discount: ONE amount in rupees, typed here and always on
          // screen - not behind the tap a line's rate and slab are behind, because it is
          // the figure the owner asked for once, near the totals (2026-09-21). What it
          // takes off is shown beside it and the total it produces is the row directly
          // below, which is the order the receipt prints them in.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                // A fixed width rather than an expanded field: what it takes off appears
                // beside it as soon as the figure is non-zero, and a field that narrowed
                // itself mid-keystroke would move under the operator's thumb.
                SizedBox(
                  width: 176,
                  child: AppTextField(
                    controller: discount,
                    label: 'Discount ₹',
                    hint: '0.00',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: Validators.nonNegativeDecimalIfPresent,
                    onChanged: (value) =>
                        onDiscountChanged(double.tryParse(value.trim()) ?? 0),
                  ),
                ),
                const Spacer(),
                if (totals.discountTotal > 0)
                  Text(
                    '-${Formatters.currency(totals.discountTotal)}',
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
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
