/// Goods receipt: books stock in and posts the supplier payable.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/logger.dart';
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
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/grn_controller.dart';
import 'package:app/features/purchase/application/purchase_form_controller.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_line_editor.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_locked_view.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_totals_preview.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Books goods in, either against an existing document or on its own.
///
/// This is the only screen that posts stock and a supplier payable (D-013), and
/// the whole write - batches first, lines second, status last - lives in
/// `PurchasesRepository.receive`. The screen's job is to collect the batch
/// details the receipt needs and to hand them over, never to assemble the
/// receipt itself.
///
/// Two ways in:
///
///  * [purchaseId] given - the receipt half of a purchase order raised earlier.
///    The document's lines are loaded and each one is given its batch details.
///  * [purchaseId] omitted - a standalone receipt, for goods that arrived with
///    no purchase order behind them. The header is created as a draft and
///    received in the same action. If the receipt then fails, that draft stays
///    on the purchase list with the lines already in it and can be received
///    again from its detail screen - the lines are not lost.
class GrnScreen extends ConsumerWidget {
  /// Creates the goods receipt screen.
  const GrnScreen({super.key, this.purchaseId});

  /// The document being received, or `null` for a standalone receipt.
  final String? purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = purchaseId;
    if (id == null) {
      return const _GrnForm(existing: null);
    }

    final target = ref.watch(purchaseWithLinesProvider(id));

    if (target.hasValue) {
      final working = target.value;
      if (working == null) {
        return AppScaffold(
          title: 'Receive goods',
          leading: _backToPurchases,
          body: ErrorView(
            message: 'That purchase no longer exists in your records.',
            onRetry: () => ref.invalidate(purchaseWithLinesProvider(id)),
          ),
        );
      }
      if (!working.isEditable) {
        return AppScaffold(
          title: 'Receive goods',
          leading: _backToPurchases,
          body: PurchaseLockedView(
            purchaseId: id,
            status: working.purchase.status,
          ),
        );
      }
      return _GrnForm(existing: working);
    }

    if (target.hasError) {
      return AppScaffold(
        title: 'Receive goods',
        leading: _backToPurchases,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(purchaseWithLinesProvider(id)),
        ),
      );
    }

    return const AppScaffold(
      title: 'Receive goods',
      leading: _backToPurchases,
      body: LoadingView(message: 'Loading purchase…'),
    );
  }
}

/// Returns to the purchase list.
const AppBackButton _backToPurchases = AppBackButton(
  location: Routes.purchase,
  tooltip: 'Back to purchases',
);

/// One receipt line: a stable identity for the widget key, plus the draft the
/// editor reports.
class _LineSlot {
  _LineSlot({required this.id, required this.draft});

  /// Stable per-form identity, used as the widget key.
  final int id;

  /// The line as the editor last reported it.
  PurchaseLineDraft draft;
}

/// The receipt form, seeded once from [existing].
class _GrnForm extends ConsumerStatefulWidget {
  const _GrnForm({required this.existing});

  /// The document being received, or `null` for a standalone receipt.
  final PurchaseWithLines? existing;

  @override
  ConsumerState<_GrnForm> createState() => _GrnFormState();
}

class _GrnFormState extends ConsumerState<_GrnForm> {
  final _formKey = GlobalKey<FormState>();
  final _invoiceNo = TextEditingController();
  final _notes = TextEditingController();
  late DateTime? _invoiceDate;
  String? _supplierId;
  late List<_LineSlot> _lines;
  int _nextSlotId = 0;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final purchase = existing?.purchase;

    _invoiceNo.text = purchase?.invoiceNo ?? '';
    _notes.text = purchase?.notes ?? '';
    _invoiceDate = purchase?.invoiceDate ?? DateTime.now();
    _supplierId = purchase?.supplierId;

    final items = existing?.items ?? const <PurchaseItem>[];
    _lines = items.isEmpty
        ? <_LineSlot>[_newSlot()]
        : items
              .map(
                (item) => _LineSlot(id: _nextSlotId++, draft: _draftOf(item)),
              )
              .toList(growable: true);
  }

  @override
  void dispose() {
    _invoiceNo.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// A blank receipt line, GST slab filled in as the purchase form does.
  _LineSlot _newSlot() => _LineSlot(
    id: _nextSlotId++,
    draft: const PurchaseLineDraft(
      qty: 1,
      purchaseRate: 0,
      mrp: 0,
      gstPercent: 12,
    ),
  );

  /// A stored line as this editor wants it.
  ///
  /// The batch fields are carried over, unlike on the order form: a receipt that
  /// failed part-way leaves a draft whose lines already hold the batch number and
  /// dates the user typed, and re-entering them would be the first thing to go
  /// wrong. There is no manufacturing date to carry - `purchase_items` has no
  /// such column, since it belongs to the batch.
  PurchaseLineDraft _draftOf(PurchaseItem item) => PurchaseLineDraft(
    qty: item.qty,
    freeQty: item.freeQty,
    purchaseRate: item.purchaseRate,
    mrp: item.mrp,
    sellingRate: item.sellingRate,
    discountPercent: item.discountPercent,
    gstPercent: item.gstPercent,
    productId: item.productId,
    productNameRaw: item.productNameRaw,
    batchNo: item.batchNo,
    expiryDate: item.expiryDate,
    hsnCode: item.hsnCode,
  );

  /// Adds an empty line to the receipt.
  void _addLine() => setState(() => _lines.add(_newSlot()));

  /// Removes [slot], never leaving the receipt with no lines at all.
  void _removeLine(_LineSlot slot) {
    if (_lines.length <= 1) {
      return;
    }
    setState(() => _lines.remove(slot));
  }

  /// Validates the receipt and books the goods in.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    final supplierId = _supplierId;
    if (supplierId == null) {
      _report('Choose the supplier these goods came from.');
      return;
    }
    final invoiceDate = _invoiceDate;
    if (invoiceDate == null) {
      _report('Choose the invoice date.');
      return;
    }

    final header = PurchaseDraft(
      supplierId: supplierId,
      invoiceNo: _invoiceNo.text.trim(),
      invoiceDate: invoiceDate,
      notes: _trimmedOrNull(_notes),
    );
    final lines = _lines.map((slot) => slot.draft).toList(growable: false);
    final existing = widget.existing?.purchase;

    try {
      var purchaseId = existing?.id;
      if (purchaseId == null) {
        // A standalone receipt still has to be a receipt *of* something: the
        // write needs a document to attach the batches and lines to. Creating it
        // as a draft first also means a failure after this point leaves the
        // document on the list, receivable again, instead of discarding what the
        // user just typed.
        final created = await ref
            .read(purchaseFormControllerProvider.notifier)
            .createPurchase(header: header, lines: lines);
        purchaseId = created.id;
      }

      final received = await ref
          .read(grnControllerProvider.notifier)
          .receive(purchaseId: purchaseId, header: header, lines: lines);
      if (!mounted) {
        return;
      }
      // Both the list and this document have to be re-read: the receipt changed
      // the status, and a document provider still cached from this screen would
      // otherwise hand the detail screen the pre-receipt copy.
      ref
        ..invalidate(purchasesListControllerProvider)
        ..invalidate(purchaseWithLinesProvider(received.id));
      context.go(Routes.purchaseDetail(received.id));
    } on Object catch (error, stackTrace) {
      // The controllers have already put the failure in their state, which the
      // `ref.listen` below turns into a SnackBar.
      appLogger.w(
        'Receiving the goods failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Shows a message to the user without involving a controller.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final isSaving =
        ref.watch(grnControllerProvider).isLoading ||
        ref.watch(purchaseFormControllerProvider).isLoading;
    final suppliers =
        ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];
    final names = <String, String>{
      for (final supplier in suppliers) supplier.id: supplier.name,
    };
    final supplierId = _supplierId;
    final split = supplierId == null
        ? TaxSplit.intraState
        : ref.watch(purchaseTaxSplitProvider(supplierId)).value ??
              TaxSplit.intraState;

    ref
      ..listen<AsyncValue<Purchase?>>(
        grnControllerProvider,
        (previous, next) => _onWrite(next.error),
      )
      ..listen<AsyncValue<Purchase?>>(
        purchaseFormControllerProvider,
        (previous, next) => _onWrite(next.error),
      );

    return AppScaffold(
      title: 'Receive goods',
      leading: _backToPurchases,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _ReceiptNotice(existing: existing),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Invoice',
              child: Column(
                children: <Widget>[
                  AppDropdownField<String>(
                    label: 'Supplier',
                    hint: 'Who the goods came from',
                    prefixIcon: Icons.local_shipping_outlined,
                    value: supplierId,
                    values: _supplierIds(suppliers, supplierId),
                    labelOf: (id) => names[id] ?? 'Currently selected supplier',
                    onChanged: (value) => setState(() => _supplierId = value),
                    validator: (value) =>
                        value == null ? 'Choose a supplier' : null,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _invoiceNo,
                    label: 'Invoice number',
                    hint: 'As printed on the invoice',
                    prefixIcon: Icons.receipt_long_outlined,
                    textCapitalization: TextCapitalization.characters,
                    validator: (value) =>
                        Validators.required(value, 'Invoice number'),
                  ),
                  const SizedBox(height: 16),
                  AppDateField(
                    label: 'Invoice date',
                    value: _invoiceDate,
                    isRequired: true,
                    onChanged: (value) => setState(() => _invoiceDate = value),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _notes,
                    label: 'Notes',
                    hint: 'Anything worth remembering about this delivery',
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Batches',
              trailing: AppButton.text(
                label: 'Add line',
                icon: Icons.add,
                expand: false,
                onPressed: _addLine,
              ),
              child: Column(
                children: <Widget>[
                  for (
                    var index = 0;
                    index < _lines.length;
                    index++
                  ) ...<Widget>[
                    if (index > 0) const SizedBox(height: 12),
                    PurchaseLineEditor(
                      key: ValueKey<int>(_lines[index].id),
                      line: _lines[index].draft,
                      title: 'Line ${index + 1}',
                      split: split,
                      showBatchFields: true,
                      canRemove: _lines.length > 1,
                      onChanged: (line) =>
                          setState(() => _lines[index].draft = line),
                      onRemove: () => _removeLine(_lines[index]),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            PurchaseTotalsPreview(
              lines: _lines.map((slot) => slot.draft).toList(growable: false),
              split: split,
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'Receive goods',
              icon: Icons.inventory_2_outlined,
              isLoading: isSaving,
              onPressed: isSaving ? null : _submit,
            ),
            const SizedBox(height: 8),
            Text(
              'Receiving books the stock into the batches above and posts the '
              'supplier payable. It cannot be undone by editing - corrections go '
              'through a purchase return or a stock adjustment.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Reports a failed write, ignoring a state that carries none.
  void _onWrite(Object? error) {
    if (error == null || !mounted) {
      return;
    }
    _report(describeError(error));
  }
}

/// What this receipt is and what receiving it will do.
class _ReceiptNotice extends StatelessWidget {
  const _ReceiptNotice({required this.existing});

  /// The document being received, or `null` for a standalone receipt.
  final PurchaseWithLines? existing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final purchase = existing?.purchase;

    return SectionCard(
      title: purchase == null
          ? 'Standalone receipt'
          : 'Receiving ${purchase.invoiceNo}',
      child: Text(
        purchase == null
            ? 'Goods that arrived without a purchase order. The document is '
                  'created and received in one step.'
            : 'Each line has to name the batch it arrived in before the goods '
                  'can be booked in. Quantities and rates are carried over from '
                  'the order and can be corrected to match the invoice.',
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}

/// The ids a supplier dropdown may offer: every active supplier, plus the one
/// already on the document even if it has since been deactivated.
List<String> _supplierIds(List<Supplier> suppliers, String? selected) {
  final ids = <String>[
    for (final supplier in suppliers)
      if (supplier.isActive || supplier.id == selected) supplier.id,
  ];
  if (selected != null && !ids.contains(selected)) {
    ids.insert(0, selected);
  }
  return ids;
}

/// The trimmed text of [controller], or `null` when it holds nothing.
String? _trimmedOrNull(TextEditingController controller) {
  final value = controller.text.trim();
  return value.isEmpty ? null : value;
}
