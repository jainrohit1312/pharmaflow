/// Pharmacy onboarding for a signed-in account that has no pharmacy yet.
///
/// This screen exists so that linking an account to a pharmacy is something a
/// user can do, instead of something an operator has to do in the SQL editor.
/// It writes through the `onboard_pharmacy` RPC rather than two client updates,
/// because `profiles.role` and `profiles.pharmacy_id` are not writable by the
/// `authenticated` role (D-017).
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:app/features/onboarding/application/onboarding_controller.dart';
import 'package:app/features/onboarding/data/onboarding_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Creates the pharmacy this account will belong to.
class OnboardingPharmacyScreen extends ConsumerStatefulWidget {
  /// Creates the onboarding screen.
  const OnboardingPharmacyScreen({super.key});

  @override
  ConsumerState<OnboardingPharmacyScreen> createState() =>
      _OnboardingPharmacyScreenState();
}

class _OnboardingPharmacyScreenState
    extends ConsumerState<OnboardingPharmacyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _gstin = TextEditingController();
  final _drugLicense = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _gstin,
      _drugLicense,
      _phone,
      _city,
      _state,
      _pincode,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Validates and submits the form.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    final details = OnboardingDetails(
      pharmacyName: _name.text.trim(),
      gstin: _trimmedOrNull(_gstin),
      drugLicense: _trimmedOrNull(_drugLicense),
      phone: _trimmedOrNull(_phone),
      city: _trimmedOrNull(_city),
      state: _trimmedOrNull(_state),
      pincode: _trimmedOrNull(_pincode),
    );

    try {
      await ref
          .read(onboardingControllerProvider.notifier)
          .createPharmacy(details);
      if (!mounted) {
        return;
      }
      // The controller has already invalidated the profile, so this is a
      // request the redirect will honour rather than a way around it.
      context.go(Routes.dashboard);
    } on Object catch (error, stackTrace) {
      // The controller published the failure, which the `ref.listen` below turns
      // into a SnackBar. Logging here keeps it out of the framework's handler.
      appLogger.w('Onboarding failed', error: error, stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSaving = ref.watch(onboardingControllerProvider).isLoading;

    ref.listen<AsyncValue<String?>>(onboardingControllerProvider, (
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
      title: 'Create your pharmacy',
      actions: <Widget>[
        // An account with no pharmacy has nowhere useful to go, so signing out
        // has to be reachable from here.
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign out',
          onPressed: isSaving
              ? null
              : () => ref.read(authControllerProvider.notifier).signOut(),
        ),
      ],
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Your account is not linked to a pharmacy yet. Create one to '
              'start using PharmaFlow. You can change these details later in '
              'Settings.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Pharmacy',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _name,
                    label: 'Pharmacy name',
                    hint: 'e.g. Arihant Medicals',
                    prefixIcon: Icons.local_pharmacy_outlined,
                    textCapitalization: TextCapitalization.words,
                    validator: (value) =>
                        Validators.required(value, 'Pharmacy name'),
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _gstin,
                    label: 'GSTIN',
                    hint: 'Optional',
                    validator: Validators.gstinIfPresent,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _drugLicense,
                    label: 'Drug licence number',
                    hint: 'Optional',
                    validator: Validators.drugLicenseIfPresent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Contact and address',
              child: Column(
                children: <Widget>[
                  AppTextField(
                    controller: _phone,
                    label: 'Phone',
                    prefixIcon: Icons.phone_outlined,
                    keyboardType: TextInputType.phone,
                    validator: Validators.phoneIfPresent,
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
                    keyboardType: TextInputType.number,
                    validator: Validators.pincodeIfPresent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'Create pharmacy',
              icon: Icons.check,
              isLoading: isSaving,
              onPressed: isSaving ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// The trimmed text of [controller], or `null` when it holds nothing.
///
/// Empty strings are sent as null so the RPC stores "not supplied" as one value
/// rather than two.
String? _trimmedOrNull(TextEditingController controller) {
  final value = controller.text.trim();
  return value.isEmpty ? null : value;
}
