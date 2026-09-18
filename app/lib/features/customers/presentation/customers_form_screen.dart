/// Create and edit form for a customer.
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
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/customer_draft.dart';
import 'package:app/features/customers/application/customers_form_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Creates a customer, or edits the one named by [customerId].
class CustomersFormScreen extends ConsumerWidget {
  /// Creates the customer form screen.
  const CustomersFormScreen({super.key, this.customerId});

  /// The customer being edited, or `null` when creating a new one.
  final String? customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = customerId;
    if (id == null) {
      return const _FormScaffold(existing: null);
    }

    final target = ref.watch(customerForEditProvider(id));

    // Checked in this order so a refresh does not tear the form down: while the
    // provider reloads it still holds the customer the form was seeded from.
    if (target.hasValue) {
      final customer = target.value;
      if (customer == null) {
        return AppScaffold(
          title: 'Edit customer',
          leading: _backToCustomers,
          body: ErrorView(
            message: 'That customer no longer exists in your records.',
            onRetry: () => ref.invalidate(customerForEditProvider(id)),
          ),
        );
      }
      return _FormScaffold(existing: customer);
    }

    if (target.hasError) {
      return AppScaffold(
        title: 'Edit customer',
        leading: _backToCustomers,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(customerForEditProvider(id)),
        ),
      );
    }

    return const AppScaffold(
      title: 'Edit customer',
      leading: _backToCustomers,
      body: LoadingView(message: 'Loading customer…'),
    );
  }
}

/// Returns to the customer list.
const AppBackButton _backToCustomers = AppBackButton(
  location: Routes.customers,
  tooltip: 'Back to customers',
);

/// The form itself, seeded once from [existing].
///
/// A separate stateful widget rather than seeding inside the parent: the parent
/// only builds this once the customer has arrived, so `initState` is a safe place
/// to fill the controllers and there is no "have I seeded yet" flag to get
/// wrong.
class _FormScaffold extends ConsumerStatefulWidget {
  const _FormScaffold({required this.existing});

  /// The customer being edited, or `null` when creating.
  final Customer? existing;

  @override
  ConsumerState<_FormScaffold> createState() => _FormScaffoldState();
}

class _FormScaffoldState extends ConsumerState<_FormScaffold> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _gstin = TextEditingController();
  final _openingBalance = TextEditingController();
  final _loyaltyPoints = TextEditingController();
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _phone.text = existing?.phone ?? '';
    _email.text = existing?.email ?? '';
    _address.text = existing?.address ?? '';
    _gstin.text = existing?.gstin ?? '';
    _openingBalance.text = existing?.openingBalance.toString() ?? '0';
    _loyaltyPoints.text = existing?.loyaltyPoints.toString() ?? '0';
    _isActive = existing?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _phone,
      _email,
      _address,
      _gstin,
      _openingBalance,
      _loyaltyPoints,
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

    final draft = CustomerDraft(
      name: _name.text.trim(),
      openingBalance: double.tryParse(_openingBalance.text.trim()) ?? 0,
      loyaltyPoints: int.tryParse(_loyaltyPoints.text.trim()) ?? 0,
      isActive: _isActive,
      phone: _trimmedOrNull(_phone),
      email: _trimmedOrNull(_email),
      address: _trimmedOrNull(_address),
      gstin: _trimmedOrNull(_gstin)?.toUpperCase(),
    );

    final existing = widget.existing;
    final controller = ref.read(customersFormControllerProvider.notifier);
    try {
      final saved = existing == null
          ? await controller.createCustomer(draft)
          : await controller.updateCustomer(
              customerId: existing.id,
              draft: draft,
            );
      if (!mounted) {
        return;
      }
      context.go(Routes.customerDetail(saved.id));
    } on Object catch (error, stackTrace) {
      // The controller has already put the failure in its state, which the
      // `ref.listen` below turns into a SnackBar. Logging here keeps it out of
      // the framework's uncaught-error handler.
      appLogger.w(
        'Saving the customer failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final isSaving = ref.watch(customersFormControllerProvider).isLoading;

    ref.listen<AsyncValue<Customer?>>(customersFormControllerProvider, (
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
      title: isEditing ? 'Edit customer' : 'New customer',
      leading: _backToCustomers,
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            SectionCard(
              title: 'Identity',
              child: AppTextField(
                controller: _name,
                label: 'Customer name',
                hint: 'e.g. Ramesh Kumar',
                prefixIcon: Icons.person_outline,
                textCapitalization: TextCapitalization.words,
                validator: (value) =>
                    Validators.required(value, 'Customer name'),
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
                    hint: 'e.g. 9876543210',
                    prefixIcon: Icons.phone_outlined,
                    keyboardType: TextInputType.phone,
                    validator: Validators.phoneIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _email,
                    label: 'Email',
                    hint: 'e.g. ramesh@example.com',
                    prefixIcon: Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                    validator: Validators.emailIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _address,
                    label: 'Address',
                    hint: 'Street, area, city',
                    prefixIcon: Icons.home_outlined,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Registration',
              child: AppTextField(
                controller: _gstin,
                label: 'GSTIN',
                hint: 'Optional — needed only for business sales',
                prefixIcon: Icons.receipt_long_outlined,
                textCapitalization: TextCapitalization.characters,
                validator: Validators.gstinIfPresent,
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Commercial',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _openingBalance,
                    label: 'Opening balance',
                    hint: 'What the customer already owed on day one',
                    prefixIcon: Icons.currency_rupee,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: Validators.nonNegativeDecimal,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _loyaltyPoints,
                    label: 'Loyalty points',
                    hint: '0 for a customer who is not on the scheme',
                    prefixIcon: Icons.card_giftcard_outlined,
                    keyboardType: TextInputType.number,
                    validator: Validators.nonNegativeInt,
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
                  'Inactive customers stay in the master and in history, '
                  'but are not offered for new sales.',
                ),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
              ),
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: isEditing ? 'Save changes' : 'Create customer',
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
