/// Create and edit form for a supplier.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/models/supplier_draft.dart';
import 'package:app/features/suppliers/application/suppliers_form_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Creates a supplier, or edits the one named by [supplierId].
class SuppliersFormScreen extends ConsumerWidget {
  /// Creates the supplier form screen.
  const SuppliersFormScreen({super.key, this.supplierId});

  /// The supplier being edited, or `null` when creating a new one.
  final String? supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = supplierId;
    if (id == null) {
      return const _FormScaffold(existing: null);
    }

    final target = ref.watch(supplierForEditProvider(id));

    // Checked in this order so a refresh does not tear the form down: while the
    // provider reloads it still holds the supplier the form was seeded from.
    if (target.hasValue) {
      final supplier = target.value;
      if (supplier == null) {
        return AppScaffold(
          title: 'Edit supplier',
          leading: _backToSuppliers,
          body: ErrorView(
            message: 'That supplier no longer exists in your records.',
            onRetry: () => ref.invalidate(supplierForEditProvider(id)),
          ),
        );
      }
      return _FormScaffold(existing: supplier);
    }

    if (target.hasError) {
      return AppScaffold(
        title: 'Edit supplier',
        leading: _backToSuppliers,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(supplierForEditProvider(id)),
        ),
      );
    }

    return const AppScaffold(
      title: 'Edit supplier',
      leading: _backToSuppliers,
      body: LoadingView(message: 'Loading supplier…'),
    );
  }
}

/// Returns to the supplier list.
const AppBackButton _backToSuppliers = AppBackButton(
  location: Routes.suppliers,
  tooltip: 'Back to suppliers',
);

/// The form itself, seeded once from [existing].
///
/// A separate stateful widget rather than seeding inside the parent: the parent
/// only builds this once the supplier has arrived, so `initState` is a safe
/// place to fill the controllers and there is no "have I seeded yet" flag to
/// get wrong.
class _FormScaffold extends ConsumerStatefulWidget {
  const _FormScaffold({required this.existing});

  /// The supplier being edited, or `null` when creating.
  final Supplier? existing;

  @override
  ConsumerState<_FormScaffold> createState() => _FormScaffoldState();
}

class _FormScaffoldState extends ConsumerState<_FormScaffold> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _contactPerson = TextEditingController();
  final _gstin = TextEditingController();
  final _drugLicenseNo = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();
  final _creditDays = TextEditingController();
  final _openingBalance = TextEditingController();
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _contactPerson.text = existing?.contactPerson ?? '';
    _gstin.text = existing?.gstin ?? '';
    _drugLicenseNo.text = existing?.drugLicenseNo ?? '';
    _phone.text = existing?.phone ?? '';
    _email.text = existing?.email ?? '';
    _address.text = existing?.address ?? '';
    _city.text = existing?.city ?? '';
    _state.text = existing?.state ?? '';
    _pincode.text = existing?.pincode ?? '';
    _creditDays.text = existing?.creditDays.toString() ?? '0';
    _openingBalance.text = existing?.openingBalance.toString() ?? '0';
    _isActive = existing?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _contactPerson,
      _gstin,
      _drugLicenseNo,
      _phone,
      _email,
      _address,
      _city,
      _state,
      _pincode,
      _creditDays,
      _openingBalance,
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

    final draft = SupplierDraft(
      name: _name.text.trim(),
      creditDays: int.tryParse(_creditDays.text.trim()) ?? 0,
      openingBalance: double.tryParse(_openingBalance.text.trim()) ?? 0,
      isActive: _isActive,
      gstin: _trimmedOrNull(_gstin),
      drugLicenseNo: _trimmedOrNull(_drugLicenseNo),
      contactPerson: _trimmedOrNull(_contactPerson),
      phone: _trimmedOrNull(_phone),
      email: _trimmedOrNull(_email),
      address: _trimmedOrNull(_address),
      city: _trimmedOrNull(_city),
      state: _trimmedOrNull(_state),
      pincode: _trimmedOrNull(_pincode),
    );

    final existing = widget.existing;
    final controller = ref.read(suppliersFormControllerProvider.notifier);
    try {
      final saved = existing == null
          ? await controller.createSupplier(draft)
          : await controller.updateSupplier(
              supplierId: existing.id,
              draft: draft,
            );
      if (!mounted) {
        return;
      }
      context.go(Routes.supplierDetail(saved.id));
    } on Object catch (error, stackTrace) {
      // The controller has already put the failure in its state, which the
      // `ref.listen` below turns into a SnackBar. Logging here keeps it out of
      // the framework's uncaught-error handler.
      appLogger.w(
        'Saving the supplier failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final isSaving = ref.watch(suppliersFormControllerProvider).isLoading;

    ref.listen<AsyncValue<Supplier?>>(suppliersFormControllerProvider, (
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
      title: isEditing ? 'Edit supplier' : 'New supplier',
      leading: _backToSuppliers,
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
                    label: 'Supplier name',
                    hint: 'e.g. Sun Pharma Distributors',
                    prefixIcon: Icons.local_shipping_outlined,
                    textCapitalization: TextCapitalization.words,
                    validator: (value) =>
                        Validators.required(value, 'Supplier name'),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _contactPerson,
                    label: 'Contact person',
                    hint: 'e.g. Ramesh Kumar',
                    textCapitalization: TextCapitalization.words,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Registration',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _gstin,
                    label: 'GSTIN',
                    hint: '15 characters, leave blank if unregistered',
                    prefixIcon: Icons.receipt_long_outlined,
                    textCapitalization: TextCapitalization.characters,
                    validator: Validators.gstinIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _drugLicenseNo,
                    label: 'Drug licence number',
                    hint: 'e.g. 20B/21B number',
                    textCapitalization: TextCapitalization.characters,
                    validator: Validators.drugLicenseIfPresent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Contact',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _phone,
                    label: 'Phone',
                    hint: '10-digit mobile number',
                    prefixIcon: Icons.phone_outlined,
                    keyboardType: TextInputType.phone,
                    validator: Validators.phoneIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _email,
                    label: 'Email',
                    prefixIcon: Icons.mail_outline,
                    keyboardType: TextInputType.emailAddress,
                    validator: Validators.emailIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _address,
                    label: 'Address',
                    hint: 'Street, area, landmark',
                    maxLines: 3,
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _city,
                    label: 'City',
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _state,
                    label: 'State',
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _pincode,
                    label: 'PIN code',
                    hint: '6 digits',
                    keyboardType: TextInputType.number,
                    validator: Validators.pincodeIfPresent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Commercial',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _creditDays,
                    label: 'Credit days',
                    hint: '0 means payment on delivery',
                    prefixIcon: Icons.schedule_outlined,
                    keyboardType: TextInputType.number,
                    validator: Validators.nonNegativeInt,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _openingBalance,
                    label: 'Opening balance',
                    hint: 'Already owed when you started using PharmaFlow',
                    prefixIcon: Icons.account_balance_wallet_outlined,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: Validators.nonNegativeDecimal,
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
                  'Inactive suppliers stay in your records and in history, '
                  'but are not offered when raising new purchase orders.',
                ),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
              ),
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: isEditing ? 'Save changes' : 'Create supplier',
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
