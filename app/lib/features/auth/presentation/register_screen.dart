/// Account registration screen.
library;

import 'package:app/core/constants/app_constants.dart';
import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/utils/validators.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Screen that creates a new PharmaFlow account.
///
/// Registration is deliberately belt-and-braces: on success the screen sends
/// the user to [Routes.dashboard] itself *and* the router redirect does the
/// same thing, because a freshly created session flips the auth state the
/// redirect reacts to. If one of the two ever changes, the other still lands
/// the user in the right place.
class RegisterScreen extends ConsumerStatefulWidget {
  /// Creates the registration screen.
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// Validates the form, creates the account, and opens the dashboard.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    final auth = ref.read(authControllerProvider.notifier);
    try {
      await auth.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        fullName: _fullNameController.text.trim(),
      );
    } on Object catch (error, stackTrace) {
      // The error is already in the provider's `AsyncValue` and surfaces
      // through the `ref.listen` below.
      appLogger.w('Sign-up failed', error: error, stackTrace: stackTrace);
      return;
    }

    if (!mounted) {
      return;
    }
    context.go(Routes.dashboard);
  }

  /// Maps an async error payload to a user-facing message.
  String _messageFor(Object error) =>
      error is AppException ? error.message : error.toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoading = ref.watch(authControllerProvider).isLoading;

    ref.listen<AsyncValue<Profile?>>(authControllerProvider, (previous, next) {
      final error = next.error;
      if (error == null || !mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_messageFor(error))));
    });

    return AppScaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Icon(
                    Icons.local_pharmacy,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Create your ${AppConstants.appName} account',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your owner will link you to a pharmacy.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  AppTextField(
                    controller: _fullNameController,
                    label: 'Full name',
                    prefixIcon: Icons.person_outline,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.name],
                    textCapitalization: TextCapitalization.words,
                    validator: (value) =>
                        Validators.required(value, 'Full name'),
                    enabled: !isLoading,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _emailController,
                    label: 'Email',
                    hint: 'you@pharmacy.example',
                    prefixIcon: Icons.mail_outline,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.email],
                    validator: Validators.email,
                    enabled: !isLoading,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _passwordController,
                    label: 'Password',
                    prefixIcon: Icons.lock_outline,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.newPassword],
                    validator: Validators.password,
                    enabled: !isLoading,
                  ),
                  const SizedBox(height: 16),
                  AppTextField(
                    controller: _confirmPasswordController,
                    label: 'Confirm password',
                    prefixIcon: Icons.lock_reset_outlined,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    validator: (value) => Validators.confirmPassword(
                      value,
                      _passwordController.text,
                    ),
                    enabled: !isLoading,
                    onSubmitted: (value) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  AppButton.primary(
                    label: 'Create Account',
                    isLoading: isLoading,
                    onPressed: isLoading ? null : _submit,
                  ),
                  const SizedBox(height: 8),
                  AppButton.text(
                    label: 'Back to sign in',
                    onPressed: isLoading
                        ? null
                        : () => context.go(Routes.login),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
