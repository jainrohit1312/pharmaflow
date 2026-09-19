/// The bill reader's screen: choose a bill, check what was read, save a draft.
///
/// The shape is a decision. This screen **reads**; it does not create a purchase
/// itself. What it produces is a `PurchaseDraft` written through
/// `PurchaseFormController.createPurchase` — the same controller the manual form
/// calls — so stock and the payable move exactly as they always do: through the
/// goods receipt, one tap away, and never from here (D-011/D-013, D-023).
///
/// The reader's output is therefore a *suggestion on a form*, never a document.
/// Every field it filled can be corrected, every line needs a product the human
/// chooses (matching is Chunk C), and the money is computed by `PurchaseTotals`
/// rather than believed: the reader's totals are shown beside the computed ones as
/// context, and the computed ones are what gets saved.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/purchase_form_controller.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_line_editor.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_totals_preview.dart';
import 'package:app/features/purchase_ocr/application/purchase_ocr_controller.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Reads a supplier bill into a purchase draft.
class PurchaseOcrScreen extends ConsumerWidget {
  /// Creates the screen.
  const PurchaseOcrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(purchaseOcrControllerProvider);
    final scan = state.scan;
    final bill = scan?.bill;

    return AppScaffold(
      title: 'Read a bill',
      actions: <Widget>[
        if (state.hasScan)
          IconButton(
            icon: const Icon(Icons.add_a_photo_outlined),
            tooltip: 'Choose another bill',
            onPressed: state.isBusy
                ? null
                : () =>
                      ref.read(purchaseOcrControllerProvider.notifier).clear(),
          ),
      ],
      body: bill != null && scan != null
          ? _VerifyForm(
              scan: scan,
              bill: bill,
              failure: state.error,
              failureIsRetryable: state.errorIsRetryable,
            )
          : _ChooseBill(state: state),
    );
  }
}

/// Everything before there is a parse: choosing a bill, waiting, and the two
/// ways a read can fail.
class _ChooseBill extends ConsumerWidget {
  const _ChooseBill({required this.state});

  final PurchaseOcrState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final failure = state.error;
    // A bill that is up in the bucket but was not read is a different situation
    // from one that never arrived, and the retry differs: reading the stored
    // object again, versus choosing a file.
    final uploaded = state.hasScan;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (state.isRetrying)
          const _Busy(
            message: 'The bill reader is busy — retrying…',
            detail:
                'The reader allows a few bills a minute. This takes a moment.',
          )
        else if (state.isBusy)
          const _Busy(
            message: 'Reading the bill…',
            detail: 'Uploading the image and asking the reader what it says.',
          ),
        if (failure != null && !state.isBusy) ...<Widget>[
          SectionCard(
            title: uploaded
                ? 'That bill could not be read'
                : 'That bill did not upload',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(describeError(failure), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                if (uploaded)
                  AppButton.primary(
                    label: 'Read it again',
                    icon: Icons.refresh,
                    onPressed: () => ref
                        .read(purchaseOcrControllerProvider.notifier)
                        .rescan(),
                  ),
                if (state.errorIsRetryable) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'This one is worth trying again — the reader was busy, not '
                    'beaten.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        SectionCard(
          title: 'Choose the supplier bill',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Photograph the whole bill, filling the frame with the item '
                'table — a small or angled table is the one thing the reader '
                'cannot cope with.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              AppButton.primary(
                label: 'Take a photo',
                icon: Icons.photo_camera_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _pick(ref, fromCamera: true),
              ),
              const SizedBox(height: 8),
              AppButton.outlined(
                label: 'Choose a file',
                icon: Icons.folder_open_outlined,
                onPressed: state.isBusy
                    ? null
                    : () => _pick(ref, fromCamera: false),
              ),
              const SizedBox(height: 12),
              Text(
                'JPEG, PNG, WebP or PDF, up to 10 MB. The bill is stored privately '
                'for this pharmacy.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Asks the platform for a bill. The controller does the rest.
  Future<void> _pick(WidgetRef ref, {required bool fromCamera}) => ref
      .read(purchaseOcrControllerProvider.notifier)
      .pickBill(fromCamera: fromCamera);
}

/// A centred wait with a reason.
class _Busy extends StatelessWidget {
  const _Busy({required this.message, required this.detail});

  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The verify form: what was read, correctable, beside the bill itself.
class _VerifyForm extends ConsumerStatefulWidget {
  const _VerifyForm({
    required this.scan,
    required this.bill,
    this.failure,
    this.failureIsRetryable = false,
  });

  final OcrScan scan;
  final OcrPurchaseBill bill;

  /// A failure from a re-read, which must not be mistaken for a fresh parse.
  final Object? failure;

  final bool failureIsRetryable;

  @override
  ConsumerState<_VerifyForm> createState() => _VerifyFormState();
}

class _VerifyFormState extends ConsumerState<_VerifyForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _invoiceNo = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  late List<_LineSlot> _lines;
  String? _supplierId;
  late DateTime _invoiceDate;
  bool _isSaving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final document = widget.bill.document;

    _invoiceNo.text = document.invoiceNo ?? '';
    _invoiceDate = document.invoiceDate ?? DateTime.now();
    _lines = <_LineSlot>[
      for (var index = 0; index < widget.bill.toLineDrafts().length; index++)
        _LineSlot(id: index, draft: widget.bill.toLineDrafts()[index]),
    ];
    if (_lines.isEmpty) {
      // A bill with no readable lines still gets a row to type into: the reader
      // failing is not a reason for the flow to stop.
      _lines = <_LineSlot>[_LineSlot(id: 0, draft: _blankLine())];
    }
  }

  @override
  void dispose() {
    _invoiceNo.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// A line for a bill the reader could not read: the same defaults the manual
  /// form's blank line uses.
  PurchaseLineDraft _blankLine() => const PurchaseLineDraft(
    qty: 1,
    purchaseRate: 0,
    mrp: 0,
    gstPercent: defaultOcrGstPercent,
  );

  List<PurchaseLineDraft> get _drafts => <PurchaseLineDraft>[
    for (final slot in _lines) slot.draft,
  ];

  TaxSplit get _split => _supplierId == null
      ? TaxSplit.intraState
      : ref.watch(purchaseTaxSplitProvider(_supplierId!)).value ??
            TaxSplit.intraState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suppliers =
        ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];
    final supplierIds = <String>[
      if (_supplierId != null && !suppliers.any((s) => s.id == _supplierId))
        _supplierId!,
      for (final supplier in suppliers) supplier.id,
    ];
    final names = <String, String>{
      for (final supplier in suppliers) supplier.id: supplier.name,
    };

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (widget.failure != null) ...<Widget>[
            SectionCard(
              title: 'The last read did not finish',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    describeError(widget.failure!),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'What is below is from the read before it, so check it before '
                    'saving.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  AppButton.outlined(
                    label: 'Read it again',
                    icon: Icons.refresh,
                    onPressed: () => ref
                        .read(purchaseOcrControllerProvider.notifier)
                        .rescan(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _ReadBack(scan: widget.scan),
          const SizedBox(height: 12),
          SectionCard(
            title: 'The bill',
            child: Column(
              children: <Widget>[
                AppDropdownField<String>(
                  label: 'Supplier',
                  value: _supplierId,
                  values: supplierIds,
                  labelOf: (id) => names[id] ?? id,
                  onChanged: (value) => setState(() => _supplierId = value),
                  validator: (value) => value == null
                      ? 'Choose the supplier this bill came from'
                      : null,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _invoiceNo,
                  label: 'Invoice number',
                  hint: 'As printed on the bill',
                  validator: Validators.required,
                ),
                const SizedBox(height: 12),
                AppDateField(
                  label: 'Invoice date',
                  value: _invoiceDate,
                  isRequired: true,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _invoiceDate = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                AppTextField(controller: _notes, label: 'Notes', maxLines: 2),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Lines read from the bill',
            trailing: TextButton.icon(
              onPressed: _isSaving
                  ? null
                  : () => setState(
                      () => _lines = <_LineSlot>[
                        ..._lines,
                        _LineSlot(id: _nextId(), draft: _blankLine()),
                      ],
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Add a line'),
            ),
            child: Column(
              children: <Widget>[
                for (var index = 0; index < _lines.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PurchaseLineEditor(
                      // A stable key per slot: the editor seeds from the line it
                      // is given and reports changes afterwards, so a rebuilt key
                      // would throw away what the user typed.
                      key: ValueKey<int>(_lines[index].id),
                      line: _lines[index].draft,
                      title: 'Line ${index + 1}',
                      split: _split,
                      showBatchFields: true,
                      canRemove: _lines.length > 1,
                      onChanged: (draft) =>
                          setState(() => _lines[index].draft = draft),
                      onRemove: () => setState(
                        () => _lines = <_LineSlot>[
                          for (final slot in _lines)
                            if (slot.id != _lines[index].id) slot,
                        ],
                      ),
                    ),
                  ),
                if (widget.bill.meta.isTruncated)
                  Text(
                    'The reader stopped before the end of the bill. Check that '
                    'every line is here.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'What this will save',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                PurchaseTotalsPreview(lines: _drafts, split: _split),
                if (widget.bill.document.grandTotal != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'The bill says ${Formatters.currency(widget.bill.document.grandTotal!)}. '
                    'That is what was printed, not what will be saved.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (_saveError != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_saveError!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          AppButton.primary(
            label: 'Save as a draft',
            icon: Icons.save_outlined,
            isLoading: _isSaving,
            onPressed: _isSaving ? null : _save,
          ),
          const SizedBox(height: 8),
          Text(
            'This saves a draft. The goods receipt — where stock and the supplier '
            'payable move — is the next step.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// A slot id that no live slot holds.
  int _nextId() =>
      _lines.fold<int>(
        0,
        (highest, slot) => slot.id > highest ? slot.id : highest,
      ) +
      1;

  /// Writes the draft through the manual form's controller.
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final supplierId = _supplierId;
    if (supplierId == null) {
      setState(() => _saveError = 'Choose the supplier this bill came from.');
      return;
    }

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      final saved = await ref
          .read(purchaseFormControllerProvider.notifier)
          .createPurchase(
            header: PurchaseDraft(
              supplierId: supplierId,
              invoiceNo: _invoiceNo.text.trim(),
              invoiceDate: _invoiceDate,
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            ),
            lines: _drafts,
          );

      ref
        ..invalidate(purchasesListControllerProvider)
        ..invalidate(purchaseWithLinesProvider(saved.id));

      if (!mounted) {
        return;
      }
      context.go(Routes.purchaseDetail(saved.id));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
        _saveError = describeError(error);
      });
    }
  }
}

/// The image beside what was read, and what the reader was unsure about.
class _ReadBack extends StatelessWidget {
  const _ReadBack({required this.scan});

  final OcrScan scan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final document = scan.bill?.document;

    return SectionCard(
      title: 'What the reader saw',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              scan.bytes,
              height: 220,
              width: double.infinity,
              fit: BoxFit.contain,
              // A file the platform cannot decode is still a file the reader may
              // have read, so the screen says what it cannot show rather than
              // failing the whole page.
              errorBuilder: (context, error, stackTrace) => Text(
                'This file cannot be shown here.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (document?.supplierName != null)
            Text(document!.supplierName!, style: theme.textTheme.titleSmall),
          if (document?.invoiceNo != null)
            Text(
              'Invoice ${document!.invoiceNo}',
              style: theme.textTheme.bodySmall,
            ),
          for (final warning in scan.bill?.meta.warnings ?? const <String>[])
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(warning, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One line's editor, kept across rebuilds by its id.
class _LineSlot {
  _LineSlot({required this.id, required this.draft});

  /// Stable across rebuilds, so the editor is not rebuilt from scratch.
  final int id;

  /// The line as it currently stands.
  PurchaseLineDraft draft;
}
