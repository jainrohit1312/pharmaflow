/// One basket line at the counter, compact enough for a 360px phone.
///
/// The counter reads four things off a line while the customer is standing there -
/// what it is, which batch and expiry, how many, and what it comes to - so those
/// are always on screen. Rate, discount and slab are the counter's exceptions
/// rather than its routine, so they are one tap away instead of occupying a row of
/// fields that most lines never touch.
///
/// The keyboard contract lives here too: **Tab** from a line's quantity moves to
/// the next line's quantity (not into that line's own details), and **Delete**
/// removes the line the caret is on. Both are explicit focus orders rather than the
/// tree's own order, because "the next line" is the counter's mental model, not the
/// widget tree's.
///
/// The **quantity field** has a contract of its own, and every clause of it is there
/// because the field used to delete the line out from under the operator:
///
///  * it takes the caret when its line is the one just rung up (`focusQty`), with what is
///    in it **selected**, so a typed digit replaces the default `1` in one keystroke and
///    the operator never has to clear the field first;
///  * an **emptied** field is not a quantity, and it is certainly not a removal - the line
///    keeps its own number until the field answers, and the field puts that number back
///    when the caret leaves it;
///  * **Enter** moves on like Tab, and **Escape** steps back out to the search field -
///    Escape does not clear the quantity and does not touch the basket (D-078).
///
/// Only the line's own delete control and Delete remove a line.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One line of the basket.
class PosCartLine extends StatefulWidget {
  /// Creates a line.
  const PosCartLine({
    required this.line,
    required this.lineTotal,
    required this.order,
    required this.onQty,
    required this.onRate,
    required this.onDiscount,
    required this.onGst,
    required this.onRemove,
    this.focusQty = false,
    this.onQtyFocused,
    this.onEscape,
    super.key,
  });

  /// The line as the basket holds it.
  final SaleCartLine line;

  /// What the line comes to, already worked out by `SaleTotals`.
  final double lineTotal;

  /// Where this line sits in the basket, which decides its keys' traversal order.
  final int order;

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

  /// Whether this line's quantity field should take the caret as soon as it can.
  ///
  /// Set by the counter for the line it has *just* rung up, and answered once through
  /// [onQtyFocused] so the request is a one-shot: Enter on a search result has to put the
  /// caret in the new line's quantity, and nothing later in the basket's life may take it
  /// back.
  final bool focusQty;

  /// Called once the caret has reached this line's quantity field.
  final VoidCallback? onQtyFocused;

  /// Called by Escape in the quantity field: step back out to the search field.
  final VoidCallback? onEscape;

  @override
  State<PosCartLine> createState() => _PosCartLineState();
}

class _PosCartLineState extends State<PosCartLine> {
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

  /// The focus the card itself holds, so Delete has somewhere to be pressed.
  final _card = FocusNode(debugLabel: 'pos cart line', skipTraversal: true);

  /// The quantity field's own focus, so the counter can send the caret to it.
  ///
  /// Owned here rather than left to the framework because two things outside the field need
  /// it: the counter, which focuses the line it has just rung up, and the field itself,
  /// which selects what is in it when focus arrives.
  final _qtyFocus = FocusNode(debugLabel: 'pos cart quantity');

  /// Whether this line's rate, discount and slab are on screen.
  bool _details = false;

  @override
  void initState() {
    super.initState();
    // Listeners rather than `onSubmitted`: a browser and a desktop have no submit
    // key, and the bill's totals must follow every keystroke (the bug the
    // purchase-return form paid for).
    // An **empty or unusable** field reports nothing at all. It used to report zero, and a
    // quantity of zero was how a line was removed - which is what made Backspace on the
    // default `1` delete the row. The controller refuses a non-positive quantity now, and
    // this side simply does not ask it to.
    _qty.addListener(() {
      final typed = int.tryParse(_qty.text.trim());
      if (typed == null || typed <= 0) {
        return;
      }
      widget.onQty(typed);
    });
    // Selecting on arrival is what makes a typed digit replace the default `1` in one
    // keystroke; leaving is where an emptied field is settled.
    _qtyFocus.addListener(() {
      if (_qtyFocus.hasFocus) {
        _selectAll();
      } else {
        _settleQty();
      }
    });
    if (widget.focusQty) {
      _takeQtyFocus();
    }
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
    _card.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PosCartLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A second scan of the same product and batch **merges** into the line already there, so
    // that line's State is not rebuilt from scratch and the request arrives here rather
    // than in `initState`.
    if (widget.focusQty && !oldWidget.focusQty) {
      _takeQtyFocus();
    }
  }

  /// Sends the caret to this line's quantity, once, after the frame that built it.
  ///
  /// Post-frame because a field that has not been laid out cannot take focus, and because
  /// the line this is called for may be brand new.
  void _takeQtyFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _qtyFocus.requestFocus();
      _selectAll();
      widget.onQtyFocused?.call();
    });
  }

  /// Selects everything in the quantity field, so the next digit replaces it.
  ///
  /// The whole point of the field's contract: a counter that has just rung up one unit and
  /// means three types `3`, not Backspace then `3`.
  void _selectAll() {
    final text = _qty.text;
    if (text.isEmpty) {
      return;
    }
    _qty.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
  }

  /// Settles the field when the caret leaves it.
  ///
  /// An emptied or unusable field puts **the line's own quantity** back and reports it, so
  /// the line is never left describing a number the bill does not use - and never removed,
  /// which is what used to happen here. A field the operator did fill in is left alone.
  void _settleQty() {
    final typed = int.tryParse(_qty.text.trim());
    if (typed != null && typed > 0) {
      return;
    }
    final restored = widget.line.qty;
    _qty.text = '$restored';
    widget.onQty(restored);
  }

  /// Enter moves on like Tab; Escape steps back out to the search field.
  ///
  /// Escape deliberately does **not** clear the quantity and does not touch the basket: at
  /// the counter it means "stop editing this number", not "undo the line" (D-078).
  KeyEventResult _onQtyKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onEscape?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The line's own keys: Delete removes it.
  ///
  /// Only reached when no field inside the line holds the caret, because a text
  /// field consumes Delete as an edit before this node is asked - which is exactly
  /// the distinction that makes one key mean "change this number" in a field and
  /// "take this line out" on the line.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.delete) {
      return KeyEventResult.ignored;
    }
    widget.onRemove();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = widget.line;

    return Focus(
      focusNode: _card,
      onKeyEvent: _onKey,
      child: GestureDetector(
        // Tapping a line's own space puts the caret on the line rather than in one
        // of its fields, which is what makes Delete mean "this line".
        behavior: HitTestBehavior.opaque,
        onTap: _card.requestFocus,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
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
                  FocusTraversalOrder(
                    order: NumericFocusOrder(_removeOrder),
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove this line',
                      // Material's own default is 40, and the counter is used with a
                      // thumb: the floor here is a fingertip.
                      constraints: _tapTarget,
                      onPressed: widget.onRemove,
                    ),
                  ),
                ],
              ),
              Text(_detail(line), style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 88,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(_qtyOrder),
                      // Not focusable itself, so Tab lands in the field rather than on this
                      // wrapper: it exists only to catch Escape before the field's own
                      // handler sees it, the shape the counter's search field already uses.
                      child: Focus(
                        canRequestFocus: false,
                        onKeyEvent: _onQtyKey,
                        child: AppTextField(
                          controller: _qty,
                          focusNode: _qtyFocus,
                          label: 'Qty',
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          validator: Validators.positiveInt,
                          // Enter moves on like Tab. Tapping selects what is already there,
                          // so a touch reaches the behaviour a keyboard gets for free - and
                          // post-frame, so the selection is set after the tap has placed the
                          // caret rather than before.
                          onSubmitted: (_) =>
                              FocusScope.of(context).nextFocus(),
                          onTap: () => WidgetsBinding.instance
                              .addPostFrameCallback((_) => _selectAll()),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Formatters.currency(widget.lineTotal),
                      style: theme.textTheme.titleSmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  FocusTraversalOrder(
                    order: NumericFocusOrder(_toggleOrder),
                    child: IconButton(
                      icon: Icon(_details ? Icons.unfold_less : Icons.tune),
                      tooltip: _details
                          ? 'Hide rate, discount and GST'
                          : 'Rate, discount and GST',
                      constraints: _tapTarget,
                      onPressed: () => setState(() => _details = !_details),
                    ),
                  ),
                ],
              ),
              if (_details) ...<Widget>[
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FocusTraversalOrder(
                        order: NumericFocusOrder(_detailOrder(0)),
                        child: AppTextField(
                          controller: _rate,
                          label: 'Rate',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          validator: Validators.nonNegativeDecimal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: NumericFocusOrder(_detailOrder(1)),
                        child: AppTextField(
                          controller: _discount,
                          label: 'Disc %',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          validator: Validators.percentIfPresent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: NumericFocusOrder(_detailOrder(2)),
                        child: AppTextField(
                          controller: _gst,
                          label: 'GST %',
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          validator: Validators.percentIfPresent,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// What the line says about the batch it comes out of.
  ///
  /// The expiry as `MM/yy`, and **`unknown`** rather than a plausible-looking date
  /// when nobody recorded one - 145 of the owner's opening-stock batches have no
  /// expiry (migration 00031), and a blank there reads as a rendering fault.
  static String _detail(SaleCartLine line) {
    final expiry = line.expiryDateIso;
    final date = expiry == null ? null : DateTime.tryParse(expiry);
    return 'Batch ${line.batchNo} · '
        'exp ${date == null ? 'unknown' : Formatters.monthYearShort(date)}';
  }

  // The traversal bands, all explicit because the tree's own order is not the counter's.
  //
  // **Every quantity sorts above every one of a line's own controls**, and that is what
  // makes Tab walk the quantities and then *leave the basket*: from the last quantity this
  // group has nothing left above it, so the next stop is the payment card - which is where
  // a counter wants to be when it has finished ringing lines up. A line's own controls (the
  // details toggle, the remove button, the rate/discount/GST fields) sit in the bands below,
  // so Tab never falls into them; they stay reachable by Shift+Tab and by tap.
  //
  // It used to be the other way round, and the last quantity's Tab landed on that line's
  // details toggle instead of the money.
  double get _qtyOrder => 1000000 + widget.order * 100;
  double get _toggleOrder => 100000 + widget.order.toDouble();
  double get _removeOrder => 200000 + widget.order.toDouble();

  /// The order of this line's [index]-th detail field (`0` rate, `1` disc, `2` GST).
  double _detailOrder(int index) =>
      300000 + widget.order * 10 + index.toDouble();
}

/// Formats [value] for a text field, leaving off a trailing `.0`.
String _numberText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

/// The floor for a control the counter touches with a thumb.
///
/// Material's own default for an `IconButton` is 40, which is a mouse's number;
/// this is the counter's.
const BoxConstraints _tapTarget = BoxConstraints(minWidth: 44, minHeight: 44);
