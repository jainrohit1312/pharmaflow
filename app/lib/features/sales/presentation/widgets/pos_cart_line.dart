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

  /// Whether this line's rate, discount and slab are on screen.
  bool _details = false;

  @override
  void initState() {
    super.initState();
    // Listeners rather than `onSubmitted`: a browser and a desktop have no submit
    // key, and the bill's totals must follow every keystroke (the bug the
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
    _card.dispose();
    super.dispose();
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
                      child: AppTextField(
                        controller: _qty,
                        label: 'Qty',
                        keyboardType: TextInputType.number,
                        validator: Validators.positiveInt,
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

  // The traversal orders, all explicit because the tree's own order is not the
  // counter's: every line's quantity sorts before every line's details, so Tab walks
  // down the quantities - which is what "Tab from qty to the next line" means. The
  // bands are far apart so a basket of any realistic length cannot collide.
  double get _qtyOrder => widget.order * 100;
  double get _toggleOrder => 500000 + widget.order.toDouble();
  double get _removeOrder => 900000 + widget.order.toDouble();

  /// The order of this line's [index]-th detail field (`0` rate, `1` disc, `2` GST).
  double _detailOrder(int index) =>
      600000 + widget.order * 10 + index.toDouble();
}

/// Formats [value] for a text field, leaving off a trailing `.0`.
String _numberText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

/// The floor for a control the counter touches with a thumb.
///
/// Material's own default for an `IconButton` is 40, which is a mouse's number;
/// this is the counter's.
const BoxConstraints _tapTarget = BoxConstraints(minWidth: 44, minHeight: 44);
