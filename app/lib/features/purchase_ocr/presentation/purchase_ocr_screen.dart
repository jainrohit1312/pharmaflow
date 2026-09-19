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

import 'dart:async';

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
import 'package:app/data/models/product_match.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/purchase_form_controller.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_line_editor.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_totals_preview.dart';
import 'package:app/features/purchase_ocr/application/purchase_match_controller.dart';
import 'package:app/features/purchase_ocr/application/purchase_ocr_controller.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:app/services/match_service.dart';
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
              // Keyed on the parse. The form seeds its lines once, in
              // `initState`, so without this a *successful* re-read would update
              // `bill` while the screen went on showing the earlier parse's lines -
              // and the matcher would go on suggesting products for a bill that is
              // no longer on screen. A new key re-seeds both.
              key: ValueKey<OcrPurchaseBill>(bill),
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
    super.key,
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

  /// The matcher's candidates, by line slot.
  ///
  /// Keyed by slot rather than by position because the list of lines is the
  /// user's to change: a line removed while the batch was in flight must not
  /// shift every later line onto the previous line's suggestions.
  Map<int, List<MatchCandidate>> _suggestions = <int, List<MatchCandidate>>{};

  @override
  void initState() {
    super.initState();
    final document = widget.bill.document;
    final drafts = widget.bill.toLineDrafts();

    _invoiceNo.text = document.invoiceNo ?? '';
    _invoiceDate = document.invoiceDate ?? DateTime.now();
    _lines = <_LineSlot>[
      // `toLineDrafts()` maps `lines` one for one, so the printed text and the
      // draft line up by index - and the index is the slot's id, which is what
      // the matcher's answer is aligned with.
      for (var index = 0; index < drafts.length; index++)
        _LineSlot(
          id: index,
          draft: drafts[index],
          invoiceText: widget.bill.lines[index].rawName,
        ),
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

  /// Records the supplier the bill came from, and asks the matcher about the
  /// bill's lines.
  ///
  /// The ask waits for this choice rather than running when the parse arrives,
  /// because the supplier is what scopes the alias leg: an alias learned from one
  /// distributor deliberately does not answer the same printed text on another's
  /// bill (D-036), so a match asked for before the human named the supplier could
  /// not use the one leg that makes a repeat bill cheap. Asking once, when the
  /// choice is made, is also what keeps this to **one embedding request per
  /// bill** (N-2/D-036): a changed choice asks again and drops the offers that
  /// were ranked for the previous supplier rather than showing them against the
  /// wrong one.
  void _onSupplierChanged(String? supplierId) {
    setState(() {
      _supplierId = supplierId;
      _suggestions = <int, List<MatchCandidate>>{};
    });
    if (supplierId == null) {
      return;
    }
    unawaited(_askForSuggestions());
  }

  /// Asks the matcher about every line, as one batch.
  ///
  /// Awaited by nobody: the bill has to be saveable while the call is still out,
  /// and a call that never returns must not stop the save. The mapping from the
  /// answer back to the lines is made here, at the moment of asking, because the
  /// answer is aligned by position with what was sent (the RPC's contract) and the
  /// slot ids are what survive a line being added or removed in the meantime.
  Future<void> _askForSuggestions() async {
    final sent = <int>[for (final slot in _lines) slot.id];
    final lines = <MatchLineRequest>[
      for (final slot in _lines)
        MatchLineRequest(rawName: slot.invoiceText, supplierId: _supplierId),
    ];

    final matches = await ref
        .read(purchaseMatchControllerProvider.notifier)
        .matchBill(lines: lines);
    if (!mounted) {
      return;
    }

    setState(() {
      _suggestions = <int, List<MatchCandidate>>{
        for (var index = 0; index < sent.length; index++)
          sent[index]: matches.length > index
              ? matches[index].candidates
              : const <MatchCandidate>[],
      };
    });
  }

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
                  onChanged: _onSupplierChanged,
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
                _MatchNote(
                  hasSupplier: _supplierId != null,
                  state: ref.watch(purchaseMatchControllerProvider),
                  onRetry: () => unawaited(_askForSuggestions()),
                ),
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
                      suggestions:
                          _suggestions[_lines[index].id] ??
                          const <MatchCandidate>[],
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

      // After the write, and never able to fail it: what this records is what
      // makes the *next* bill from this supplier cheap, and it can only be about a
      // document that exists.
      await _learnAliases(supplierId: supplierId);

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

  /// Records the printed text of every line this human matched to a product.
  ///
  /// One call for the whole bill, and only the human's choice creates anything: a
  /// suggestion that was not accepted teaches nothing, and a line the reader
  /// printed but nobody matched teaches nothing either. The text is
  /// [_LineSlot.invoiceText] rather than the draft's `productNameRaw`, because
  /// picking a product overwrites that with the catalogue's own spelling — and a
  /// catalogue name is not what the next bill will print.
  ///
  /// A supplier that the server does not recognise is the server's to read as
  /// "no supplier" (it stores a pharmacy-wide alias instead); a bill whose
  /// supplier is somehow absent sends none, and the same rule applies.
  Future<void> _learnAliases({required String supplierId}) async {
    final aliases = <ConfirmedAlias>[
      for (final slot in _lines)
        if (slot.invoiceText != null && slot.draft.productId != null)
          ConfirmedAlias(
            rawName: slot.invoiceText!,
            productId: slot.draft.productId!,
            supplierId: supplierId,
          ),
    ];
    if (aliases.isEmpty) {
      return;
    }

    try {
      await ref.read(matchServiceProvider).learnAliases(aliases: aliases);
    } on Object {
      // Best effort, and silent on purpose. The purchase is saved, and a user told
      // "the alias could not be recorded" would have no action to take and a
      // document that is fine. What is actually lost is next time's head start:
      // the same printed text is matched by name and by vector again, and the
      // human chooses again - which is exactly what happened this time.
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

/// The one line the screen says about the matcher, and only when it has something
/// worth saying.
///
/// A bill is saveable whether or not the matcher ever answers, so this never
/// stands in for anything and never blocks anything: it explains an absence
/// ("nothing has been asked yet", "the catalogue could not be searched"), it
/// repeats the server's own sentence when a leg was unavailable, and it offers a
/// **manual** retry rather than spending another embedding request on its own
/// (D-036's rule for the reader's key, applied here — the choice to spend one is
/// the user's).
class _MatchNote extends StatelessWidget {
  const _MatchNote({
    required this.hasSupplier,
    required this.state,
    required this.onRetry,
  });

  /// Whether the bill's supplier has been chosen yet.
  ///
  /// Every leg but the alias leg answers without it, but the alias leg is the one
  /// that makes a repeat bill cheap *and* it is scoped by the supplier — so the ask
  /// waits for a human to name the supplier rather than running twice.
  final bool hasSupplier;

  /// What the matcher last said about itself.
  final PurchaseMatchState state;

  /// Asks again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = state.error;

    if (failure != null) {
      return _note(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'The catalogue could not be searched this time, so pick each '
              'product by hand. Nothing else about this bill is affected.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 2),
            Text(
              describeError(failure),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.search),
                label: const Text('Look again'),
              ),
            ),
          ],
        ),
      );
    }

    if (state.isMatching) {
      return _note(
        Row(
          children: <Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Looking these lines up in your catalogue…',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    // The server's own sentences, kept verbatim: they say which leg was skipped
    // and why, which is the difference between "your catalogue does not have it"
    // and "this answer is narrower than usual".
    if (state.hasWarnings) {
      return _note(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final warning in state.meta!.warnings)
              Row(
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
          ],
        ),
      );
    }

    if (!hasSupplier) {
      return _note(
        Text(
          'Choose the supplier and these lines will be looked up in your '
          'catalogue.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return const SizedBox.shrink();
  }

  /// One note, spaced like the line cards below it.
  Widget _note(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
}

/// One line's editor, kept across rebuilds by its id.
class _LineSlot {
  _LineSlot({required this.id, required this.draft, this.invoiceText});

  /// Stable across rebuilds, so the editor is not rebuilt from scratch.
  final int id;

  /// The line as it currently stands.
  PurchaseLineDraft draft;

  /// The text the reader printed on this line, when it read one.
  ///
  /// Kept here rather than read back from [draft] because picking a product
  /// overwrites the draft's raw name with the catalogue's own spelling - that is
  /// what the field then displays - and the *printed* text is the only thing an
  /// alias can be learned from and the only thing worth matching against.
  final String? invoiceText;
}
