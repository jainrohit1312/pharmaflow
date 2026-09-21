/// Create and edit form for a product.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/utils/platform.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_draft.dart';
import 'package:app/features/approvals/presentation/sent_to_owner.dart';
import 'package:app/features/products/application/products_form_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Creates a product, or edits the one named by [productId].
class ProductsFormScreen extends ConsumerWidget {
  /// Creates the product form screen.
  const ProductsFormScreen({super.key, this.productId});

  /// The product being edited, or `null` when creating a new one.
  final String? productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = productId;
    if (id == null) {
      return const _FormScaffold(existing: null);
    }

    final target = ref.watch(productForEditProvider(id));

    // Checked in this order so a refresh does not tear the form down: while the
    // provider reloads it still holds the product the form was seeded from.
    if (target.hasValue) {
      final product = target.value;
      if (product == null) {
        return AppScaffold(
          title: 'Edit product',
          leading: _backToProducts,
          body: ErrorView(
            message: 'That product no longer exists in your catalogue.',
            onRetry: () => ref.invalidate(productForEditProvider(id)),
          ),
        );
      }
      return _FormScaffold(existing: product);
    }

    if (target.hasError) {
      return AppScaffold(
        title: 'Edit product',
        leading: _backToProducts,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(productForEditProvider(id)),
        ),
      );
    }

    return const AppScaffold(
      title: 'Edit product',
      leading: _backToProducts,
      body: LoadingView(message: 'Loading product…'),
    );
  }
}

/// Returns to the product list.
const AppBackButton _backToProducts = AppBackButton(
  location: Routes.products,
  tooltip: 'Back to products',
);

/// The form itself, seeded once from [existing].
///
/// A separate stateful widget rather than seeding inside the parent: the parent
/// only builds this once the product has arrived, so `initState` is a safe place
/// to fill the controllers and there is no "have I seeded yet" flag to get
/// wrong.
class _FormScaffold extends ConsumerStatefulWidget {
  const _FormScaffold({required this.existing});

  /// The product being edited, or `null` when creating.
  final Product? existing;

  @override
  ConsumerState<_FormScaffold> createState() => _FormScaffoldState();
}

class _FormScaffoldState extends ConsumerState<_FormScaffold> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _genericName = TextEditingController();
  final _brand = TextEditingController();
  final _manufacturer = TextEditingController();
  final _hsnCode = TextEditingController();
  final _category = TextEditingController();
  final _packSize = TextEditingController();
  final _unit = TextEditingController();
  final _minStockLevel = TextEditingController();
  final _rackLocation = TextEditingController();
  final _barcode = TextEditingController();
  late ScheduleType _scheduleType;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _genericName.text = existing?.genericName ?? '';
    _brand.text = existing?.brand ?? '';
    _manufacturer.text = existing?.manufacturer ?? '';
    _hsnCode.text = existing?.hsnCode ?? '';
    _category.text = existing?.category ?? '';
    _packSize.text = existing?.packSize ?? '';
    _unit.text = existing?.unit ?? '';
    _minStockLevel.text = existing?.minStockLevel.toString() ?? '0';
    _rackLocation.text = existing?.rackLocation ?? '';
    _barcode.text = existing?.barcode ?? '';
    _scheduleType = existing?.scheduleType ?? ScheduleType.otc;
    _isActive = existing?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _genericName,
      _brand,
      _manufacturer,
      _hsnCode,
      _category,
      _packSize,
      _unit,
      _minStockLevel,
      _rackLocation,
      _barcode,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Validates and submits the form.
  Future<void> _save() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    final draft = ProductDraft(
      name: _name.text.trim(),
      scheduleType: _scheduleType,
      minStockLevel: int.tryParse(_minStockLevel.text.trim()) ?? 0,
      isActive: _isActive,
      genericName: _trimmedOrNull(_genericName),
      brand: _trimmedOrNull(_brand),
      manufacturer: _trimmedOrNull(_manufacturer),
      hsnCode: _trimmedOrNull(_hsnCode),
      category: _trimmedOrNull(_category),
      packSize: _trimmedOrNull(_packSize),
      unit: _trimmedOrNull(_unit),
      rackLocation: _trimmedOrNull(_rackLocation),
      barcode: _trimmedOrNull(_barcode),
    );

    final existing = widget.existing;
    final controller = ref.read(productsFormControllerProvider.notifier);
    try {
      final saved = existing == null
          ? await controller.createProduct(draft)
          : await controller.updateProduct(
              productId: existing.id,
              draft: draft,
            );
      if (!mounted) {
        return;
      }

      // A staged write wrote NOTHING - the product does not exist yet, or the edit has not
      // happened - so there is no detail route to open. Navigating to the product anyway would
      // show the pre-edit row and read as a save, which is exactly the claim this sentence exists
      // to prevent.
      if (saved.isStaged) {
        showSentToOwnerNotice(context, message: sentForApprovalMessage);
        context.go(
          existing == null
              ? Routes.products
              : Routes.productDetail(existing.id),
        );
        return;
      }

      context.go(Routes.productDetail(saved.document!.id));
    } on Object catch (error, stackTrace) {
      // The controller has already put the failure in its state, which the
      // `ref.listen` below turns into a SnackBar. Logging here keeps it out of
      // the framework's uncaught-error handler.
      appLogger.w(
        'Saving the product failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Explains that camera scanning is not wired up yet.
  ///
  /// The hook exists so the field does not silently differ per platform: on the
  /// web there is no button and the field is type-only, which is the documented
  /// Phase 1 behaviour.
  void _showScannerNotice() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Camera scanning arrives in Phase 6 — type the code for now.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final isSaving = ref.watch(productsFormControllerProvider).isLoading;

    ref.listen<AsyncValue<Product?>>(productsFormControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    });

    return AppScaffold(
      title: isEditing ? 'Edit product' : 'New product',
      leading: _backToProducts,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SectionCard(
              title: 'Identity',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _name,
                    label: 'Product name',
                    hint: 'e.g. Dolo 650',
                    prefixIcon: Icons.medication_outlined,
                    textCapitalization: TextCapitalization.words,
                    validator: (value) =>
                        Validators.required(value, 'Product name'),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _genericName,
                    label: 'Generic name',
                    hint: 'e.g. Paracetamol',
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _brand,
                    label: 'Brand',
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _manufacturer,
                    label: 'Manufacturer',
                    textCapitalization: TextCapitalization.words,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Classification',
              child: Column(
                children: <Widget>[
                  AppDropdownField<ScheduleType>(
                    label: 'Drug schedule',
                    values: ScheduleType.values,
                    labelOf: (schedule) => schedule.label,
                    value: _scheduleType,
                    prefixIcon: Icons.assignment_outlined,
                    onChanged: (schedule) => setState(
                      () => _scheduleType = schedule ?? ScheduleType.otc,
                    ),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _category,
                    label: 'Category',
                    hint: 'e.g. Analgesic',
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(controller: _hsnCode, label: 'HSN code'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Pack and stock',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _packSize,
                    label: 'Pack size',
                    hint: 'e.g. 10 tab',
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _unit,
                    label: 'Unit',
                    hint: 'e.g. strip',
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _minStockLevel,
                    label: 'Minimum stock level',
                    hint: '0 means no alert',
                    prefixIcon: Icons.inventory_2_outlined,
                    keyboardType: TextInputType.number,
                    validator: Validators.nonNegativeInt,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Codes and location',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _barcode,
                    label: 'Barcode',
                    hint: isMobile ? 'Scan or type the code' : 'Type the code',
                    prefixIcon: Icons.qr_code_2_outlined,
                    keyboardType: TextInputType.number,
                    suffix: isMobile
                        ? IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            tooltip: 'Scan barcode',
                            onPressed: _showScannerNotice,
                          )
                        : null,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _rackLocation,
                    label: 'Rack location',
                    hint: 'e.g. A-3',
                    prefixIcon: Icons.place_outlined,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Availability',
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text(
                  'Inactive products stay in the catalogue and in history, '
                  'but are not offered for new sales or purchases.',
                ),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
              ),
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: isEditing ? 'Save changes' : 'Create product',
              icon: Icons.check,
              isLoading: isSaving,
              onPressed: isSaving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// The trimmed text of [controller], or `null` when it holds nothing.
///
/// Empty strings are sent as null so the column is cleared rather than being set
/// to `''`, which would sort, filter and search differently from "no value".
String? _trimmedOrNull(TextEditingController controller) {
  final value = controller.text.trim();
  return value.isEmpty ? null : value;
}
