/// Email and password sign-in screen.
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

/// Screen that authenticates an existing PharmaFlow user.
///
/// The screen never navigates on success: [AuthController] updates the auth
/// state, the router redirect runs, and the user lands on the dashboard. The
/// only feedback the screen owns is the error [SnackBar] wired to `ref.listen`.
class LoginScreen extends ConsumerStatefulWidget {
  /// Creates the login screen.
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Validates the form and asks [AuthController] to sign the user in.
  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    final auth = ref.read(authControllerProvider.notifier);
    try {
      await auth.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on Object catch (error, stackTrace) {
      // `AuthController.signIn` already pushed the error into its `AsyncValue`,
      // which the `ref.listen` below turns into a SnackBar. Logging here keeps
      // the failure out of the framework's uncaught-error handler.
      appLogger.w('Sign-in failed', error: error, stackTrace: stackTrace);
    }
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
                    AppConstants.appName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Sign in to manage your pharmacy.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
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
                    textInputAction: TextInputAction.done,
                    autofillHints: const <String>[AutofillHints.password],
                    validator: Validators.password,
                    enabled: !isLoading,
                    onSubmitted: (value) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  AppButton.primary(
                    label: 'Sign In',
                    isLoading: isLoading,
                    onPressed: isLoading ? null : _submit,
                  ),
                  const SizedBox(height: 8),
                  AppButton.text(
                    label: 'Create Account',
                    onPressed: isLoading
                        ? null
                        : () => context.go(Routes.register),
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
