/// Editor for one line of a purchase document.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/presentation/widgets/product_picker_field.dart';
import 'package:flutter/material.dart';

/// Edits a single purchase line: what was bought, how many, at what price, and
/// - when [showBatchFields] is set - which batch it arrived in.
///
/// The same widget serves both halves of a purchase's life, because the fields
/// are a superset: a purchase order line is a product and a quantity with no
/// batch yet, and a receipt adds the batch number, its dates and the printed
/// rates. Keeping one editor means the two screens cannot drift apart on how a
/// line's money or quantity is read.
///
/// The editor owns the text controllers and reports every change up through
/// [onChanged]; the parent owns the list of lines and therefore the totals. The
/// parent must give each editor a stable `key`, since the controllers are seeded
/// once and a re-created editor would lose what the user typed.
class PurchaseLineEditor extends StatefulWidget {
  /// Creates a line editor seeded from [line].
  const PurchaseLineEditor({
    required this.line,
    required this.onChanged,
    required this.onRemove,
    super.key,
    this.split = TaxSplit.intraState,
    this.showBatchFields = false,
    this.canRemove = true,
    this.title,
  });

  /// The line as the parent currently holds it; seeds the fields.
  final PurchaseLineDraft line;

  /// Called with the line rebuilt from the current field values, on every
  /// change, so the parent's totals stay live.
  final ValueChanged<PurchaseLineDraft> onChanged;

  /// Called when the user removes this line.
  final VoidCallback onRemove;

  /// Whether the tax is intra-state or inter-state, for the line total shown.
  final TaxSplit split;

  /// Whether to collect the batch number, its dates and the printed rates.
  final bool showBatchFields;

  /// Whether this line may be removed; `false` for the last remaining one.
  final bool canRemove;

  /// Heading for the card, e.g. `Line 2`.
  final String? title;

  @override
  State<PurchaseLineEditor> createState() => _PurchaseLineEditorState();
}

class _PurchaseLineEditorState extends State<PurchaseLineEditor> {
  late final TextEditingController _qty;
  late final TextEditingController _freeQty;
  late final TextEditingController _purchaseRate;
  late final TextEditingController _mrp;
  late final TextEditingController _sellingRate;
  late final TextEditingController _discountPercent;
  late final TextEditingController _gstPercent;
  late final TextEditingController _hsnCode;
  late final TextEditingController _batchNo;

  late String? _productId;
  late String? _productNameRaw;
  late DateTime? _mfgDate;
  late DateTime? _expiryDate;

  /// Every controller this editor owns, for listener wiring and disposal.
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    final line = widget.line;

    _productId = line.productId;
    _productNameRaw = line.productNameRaw;
    _mfgDate = line.mfgDate;
    _expiryDate = line.expiryDate;

    _qty = TextEditingController(text: '${line.qty}');
    _freeQty = TextEditingController(text: '${line.freeQty}');
    _purchaseRate = TextEditingController(text: _numberText(line.purchaseRate));
    _mrp = TextEditingController(text: _numberText(line.mrp));
    _sellingRate = TextEditingController(text: _numberText(line.sellingRate));
    _discountPercent = TextEditingController(
      text: _numberText(line.discountPercent),
    );
    _gstPercent = TextEditingController(text: _numberText(line.gstPercent));
    _hsnCode = TextEditingController(text: line.hsnCode ?? '');
    _batchNo = TextEditingController(text: line.batchNo ?? '');

    _controllers = <TextEditingController>[
      _qty,
      _freeQty,
      _purchaseRate,
      _mrp,
      _sellingRate,
      _discountPercent,
      _gstPercent,
      _hsnCode,
      _batchNo,
    ];
    // Listeners added after the seed text is set, so seeding does not report a
    // change the user did not make.
    for (final controller in _controllers) {
      controller.addListener(_emit);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_emit)
        ..dispose();
    }
    super.dispose();
  }

  /// Reports the line as it now stands.
  void _emit() => widget.onChanged(_build());

  /// The line rebuilt from the current field values.
  PurchaseLineDraft _build() => PurchaseLineDraft(
    qty: _parseInt(_qty.text),
    freeQty: _parseInt(_freeQty.text),
    purchaseRate: _parseDouble(_purchaseRate.text),
    mrp: _parseDouble(_mrp.text),
    sellingRate: _parseDouble(_sellingRate.text),
    discountPercent: _parseDouble(_discountPercent.text),
    gstPercent: _parseDouble(_gstPercent.text),
    productId: _productId,
    productNameRaw: _productNameRaw,
    batchNo: _trimmedOrNull(_batchNo.text),
    hsnCode: _trimmedOrNull(_hsnCode.text),
    mfgDate: _mfgDate,
    expiryDate: _expiryDate,
  );

  /// Records the product the picker reported.
  ///
  /// Only the link and the printed name are taken from the catalogue row; the
  /// purchase rate and margin are what the invoice says, and pre-filling them
  /// from the last purchase would put a number on this invoice that the supplier
  /// never quoted. The HSN code is a property of the product rather than of the
  /// deal, so that one is filled in.
  void _onProduct(Product product) {
    setState(() {
      _productId = product.id;
      _productNameRaw = product.name;
      final hsn = product.hsnCode;
      if (hsn != null &&
          hsn.trim().isNotEmpty &&
          _hsnCode.text.trim().isEmpty) {
        _hsnCode.text = hsn;
      }
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = _build();
    final lineTotal = PurchaseTotals.forLine(line, split: widget.split).total;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.title ?? 'Line',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  Formatters.currency(lineTotal),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: widget.canRemove
                      ? 'Remove this line'
                      : 'A purchase needs at least one line',
                  onPressed: widget.canRemove ? widget.onRemove : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            ProductPickerField(
              selectedName: _productNameRaw,
              onSelected: _onProduct,
            ),
            const SizedBox(height: 12),
            _FieldRow(
              children: <Widget>[
                AppTextField(
                  controller: _qty,
                  label: 'Quantity',
                  hint: 'Units billed',
                  keyboardType: TextInputType.number,
                  validator: _positiveInt,
                ),
                AppTextField(
                  controller: _freeQty,
                  label: 'Free quantity',
                  hint: 'Scheme units',
                  keyboardType: TextInputType.number,
                  validator: Validators.nonNegativeInt,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _FieldRow(
              children: <Widget>[
                AppTextField(
                  controller: _purchaseRate,
                  label: 'Purchase rate',
                  hint: 'Rate billed per unit',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: Validators.nonNegativeDecimal,
                ),
                AppTextField(
                  controller: _mrp,
                  label: 'MRP',
                  hint: 'Printed maximum retail price',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: Validators.nonNegativeDecimal,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _FieldRow(
              children: <Widget>[
                AppTextField(
                  controller: _sellingRate,
                  label: 'Selling rate',
                  hint: 'Your counter price',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: Validators.nonNegativeDecimal,
                ),
                AppTextField(
                  controller: _discountPercent,
                  label: 'Discount %',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _percent,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _FieldRow(
              children: <Widget>[
                AppTextField(
                  controller: _gstPercent,
                  label: 'GST %',
                  hint: '0, 5, 12, 18 or 28',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _percent,
                ),
                AppTextField(
                  controller: _hsnCode,
                  label: 'HSN code',
                  textCapitalization: TextCapitalization.characters,
                ),
              ],
            ),
            if (widget.showBatchFields) ...<Widget>[
              const SizedBox(height: 12),
              AppTextField(
                controller: _batchNo,
                label: 'Batch number',
                hint: 'As printed on the pack',
                textCapitalization: TextCapitalization.characters,
                validator: (value) =>
                    Validators.required(value, 'Batch number'),
              ),
              const SizedBox(height: 12),
              _FieldRow(
                children: <Widget>[
                  AppDateField(
                    label: 'Manufactured on',
                    value: _mfgDate,
                    onChanged: (value) {
                      setState(() => _mfgDate = value);
                      // Reported like every other field: the parent holds the
                      // draft the receipt is built from, and a date it never
                      // heard about would reach the write as null.
                      _emit();
                    },
                  ),
                  AppDateField(
                    label: 'Expiry date',
                    value: _expiryDate,
                    isRequired: true,
                    onChanged: (value) {
                      setState(() => _expiryDate = value);
                      _emit();
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lays [children] out in a row when there is room, and stacked when there is
/// not.
///
/// Two columns of number fields stop being readable on a phone, and the date
/// pickers on a receipt line suffer worst of all: their labels are long and
/// their values are dates, so they ellipsise first.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.children});

  /// Fields to place side by side, or one above the other.
  final List<Widget> children;

  /// Below this width the fields stack.
  static const double _stackBelow = 560;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < _stackBelow) {
      return Column(
        children: <Widget>[
          for (var index = 0; index < children.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(height: 12),
            children[index],
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var index = 0; index < children.length; index++) ...<Widget>[
          if (index > 0) const SizedBox(width: 12),
          Expanded(child: children[index]),
        ],
      ],
    );
  }
}

/// Parses [raw] as an int, falling back to 0 for anything unreadable.
int _parseInt(String raw) => int.tryParse(raw.trim()) ?? 0;

/// Formats [value] for a text field, leaving off a trailing `.0`.
///
/// Field values are stored as `double` - the columns are `numeric` - so a rate of
/// 100 would otherwise be seeded as `100.0` and a slab of 12 as `12.0`, which
/// reads like a precision the user never entered.
String _numberText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

/// Parses [raw] as a double, falling back to 0 for anything unreadable.
double _parseDouble(String raw) => double.tryParse(raw.trim()) ?? 0;

/// The trimmed text of [raw], or `null` when it holds nothing.
String? _trimmedOrNull(String raw) {
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

/// Requires a whole number of at least one.
String? _positiveInt(String? value) {
  final parsed = int.tryParse(value?.trim() ?? '');
  if (parsed == null) {
    return 'Enter a whole number';
  }
  if (parsed <= 0) {
    return 'Must be more than zero';
  }
  return null;
}

/// Accepts a blank field, otherwise a percentage between 0 and 100.
String? _percent(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return null;
  }
  final parsed = double.tryParse(raw);
  if (parsed == null) {
    return 'Enter a number';
  }
  if (parsed < 0 || parsed > 100) {
    return 'Must be between 0 and 100';
  }
  return null;
}
