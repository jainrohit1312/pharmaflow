/// Create and edit form for a purchase document.
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

/// Creates a purchase order, or edits the one named by [purchaseId].
///
/// This form writes the order half of a purchase's life: the invoice details and
/// its lines, with no batch numbers and no stock movement. Batches are what a
/// *receipt* creates, and the receipt has its own screen (`GrnScreen`) reachable
/// from the document's detail page.
///
/// One consequence of that split is worth knowing: the repository rewrites an
/// edited document back to `draft` (see `PurchasesRepository.updateDraft`), so
/// saving changes to an `ordered` purchase returns it to draft and it has to be
/// marked ordered again.
class PurchaseFormScreen extends ConsumerWidget {
  /// Creates the purchase form screen.
  const PurchaseFormScreen({super.key, this.purchaseId});

  /// The document being edited, or `null` when creating a new one.
  final String? purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = purchaseId;
    if (id == null) {
      return const _PurchaseForm(existing: null);
    }

    final target = ref.watch(purchaseWithLinesProvider(id));

    // Checked in this order so a refresh does not tear the form down: while the
    // provider reloads it still holds the document the form was seeded from.
    if (target.hasValue) {
      final working = target.value;
      if (working == null) {
        return AppScaffold(
          title: 'Edit purchase',
          leading: _backToPurchases,
          body: ErrorView(
            message: 'That purchase no longer exists in your records.',
            onRetry: () => ref.invalidate(purchaseWithLinesProvider(id)),
          ),
        );
      }
      if (!working.isEditable) {
        return AppScaffold(
          title: 'Edit purchase',
          leading: _backToPurchases,
          body: PurchaseLockedView(
            purchaseId: id,
            status: working.purchase.status,
          ),
        );
      }
      return _PurchaseForm(existing: working);
    }

    if (target.hasError) {
      return AppScaffold(
        title: 'Edit purchase',
        leading: _backToPurchases,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(purchaseWithLinesProvider(id)),
        ),
      );
    }

    return const AppScaffold(
      title: 'Edit purchase',
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

/// One line as this form holds it: a stable identity for the widget key, plus
/// the draft the editor reports.
///
/// The identity matters: `PurchaseLineEditor` seeds its text controllers once, so
/// a line that is rebuilt under a new key would lose what the user typed, and one
/// rebuilt under a shifted key would show another line's numbers.
class _LineSlot {
  _LineSlot({required this.id, required this.draft});

  /// Stable per-form identity, used as the widget key.
  final int id;

  /// The line as the editor last reported it.
  PurchaseLineDraft draft;
}

/// The form itself, seeded once from [existing].
///
/// A separate stateful widget rather than seeding inside the parent: the parent
/// only builds this once the document has arrived, so `initState` is a safe
/// place to fill the controllers and there is no "have I seeded yet" flag to get
/// wrong.
class _PurchaseForm extends ConsumerStatefulWidget {
  const _PurchaseForm({required this.existing});

  /// The document being edited, or `null` when creating one.
  final PurchaseWithLines? existing;

  @override
  ConsumerState<_PurchaseForm> createState() => _PurchaseFormState();
}

class _PurchaseFormState extends ConsumerState<_PurchaseForm> {
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

  /// A blank line, with the GST slab most medicines attract already filled in.
  ///
  /// Zero would be the "safer" default only in the sense that it asserts
  /// nothing; it is also wrong for almost every line, and would silently put a
  /// tax-free invoice in front of a user who did not notice the field. The slab
  /// is on screen and editable either way.
  _LineSlot _newSlot() => _LineSlot(
    id: _nextSlotId++,
    draft: const PurchaseLineDraft(
      qty: 1,
      purchaseRate: 0,
      mrp: 0,
      gstPercent: 12,
    ),
  );

  /// A stored line as the editor wants it.
  ///
  /// The batch fields are deliberately dropped: a purchase order line has no
  /// batch yet, and carrying a stale one through this form would let the order
  /// screen rewrite receipt data.
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
    hsnCode: item.hsnCode,
  );

  /// Adds an empty line to the document.
  void _addLine() => setState(() => _lines.add(_newSlot()));

  /// Removes [slot], never leaving the document with no lines at all.
  void _removeLine(_LineSlot slot) {
    if (_lines.length <= 1) {
      return;
    }
    setState(() => _lines.remove(slot));
  }

  /// Validates and saves, optionally moving a new document straight to ordered.
  Future<void> _save({required bool markOrdered}) async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    final supplierId = _supplierId;
    if (supplierId == null) {
      _report('Choose the supplier this invoice came from.');
      return;
    }
    final invoiceDate = _invoiceDate;
    if (invoiceDate == null) {
      // Unreachable while the date field is marked required, and cheap enough to
      // state rather than to assume.
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
    final controller = ref.read(purchaseFormControllerProvider.notifier);
    final existing = widget.existing?.purchase;

    try {
      final saved = existing == null
          ? await controller.createPurchase(header: header, lines: lines)
          : await controller.updatePurchase(
              purchaseId: existing.id,
              header: header,
              lines: lines,
            );
      if (markOrdered && saved.status == PurchaseStatus.draft) {
        await controller.setStatus(
          purchaseId: saved.id,
          status: PurchaseStatus.ordered,
        );
      }
      if (!mounted) {
        return;
      }
      // Both the list and this document have to be re-read: the write changed the
      // totals, and an edit also puts an ordered document back to draft, so a
      // cached copy would show the detail screen something the database no longer
      // holds.
      ref
        ..invalidate(purchasesListControllerProvider)
        ..invalidate(purchaseWithLinesProvider(saved.id));
      context.go(Routes.purchaseDetail(saved.id));
    } on Object catch (error, stackTrace) {
      // The controller has already put the failure in its state, which the
      // `ref.listen` below turns into a SnackBar. Logging here keeps it out of
      // the framework's uncaught-error handler.
      appLogger.w(
        'Saving the purchase failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Shows a message to the user without involving the controller.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final isSaving = ref.watch(purchaseFormControllerProvider).isLoading;
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

    ref.listen<AsyncValue<Purchase?>>(purchaseFormControllerProvider, (
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
      title: isEditing ? 'Edit purchase' : 'New purchase',
      leading: _backToPurchases,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SectionCard(
              title: 'Invoice',
              child: Column(
                children: <Widget>[
                  AppDropdownField<String>(
                    label: 'Supplier',
                    hint: 'Who the invoice is from',
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
                    hint: 'Anything worth remembering about this invoice',
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Lines',
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
            PurchaseTotalsPreview(lines: _lineDrafts, split: split),
            const SizedBox(height: 24),
            if (isEditing) ...<Widget>[
              AppButton.primary(
                label: 'Save changes',
                icon: Icons.check,
                isLoading: isSaving,
                onPressed: isSaving ? null : () => _save(markOrdered: false),
              ),
            ] else ...<Widget>[
              AppButton.primary(
                label: 'Save draft',
                icon: Icons.save_outlined,
                isLoading: isSaving,
                onPressed: isSaving ? null : () => _save(markOrdered: false),
              ),
              const SizedBox(height: 12),
              AppButton.outlined(
                label: 'Save and mark ordered',
                icon: Icons.local_shipping_outlined,
                isLoading: isSaving,
                onPressed: isSaving ? null : () => _save(markOrdered: true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The lines as the totals preview and the write want them.
  List<PurchaseLineDraft> get _lineDrafts =>
      _lines.map((slot) => slot.draft).toList(growable: false);
}

/// The ids a supplier dropdown may offer: every active supplier, plus the one
/// already on the document even if it has since been deactivated.
///
/// The `isActive` filter is dropped for the selected supplier because handing a
/// dropdown a value that is not among its items asserts. And when the document
/// arrived before the supplier list did, the id is offered on its own so the
/// field can still show what was loaded - the value would otherwise be dropped
/// and the form would look like it had no supplier at all.
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
///
/// Empty strings are sent as null so the column is cleared rather than being set
/// to `''`, which would sort, filter and search differently from "no value".
String? _trimmedOrNull(TextEditingController controller) {
  final value = controller.text.trim();
  return value.isEmpty ? null : value;
}
