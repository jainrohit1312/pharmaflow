/// Splash screen shown while the session is restored.
library;

import 'package:flutter/material.dart';

/// The first screen the router renders.
///
/// This widget is purely presentational: it contains **no navigation logic**.
/// The router owns every redirect, so this screen only shows the wordmark and
/// a progress indicator while `appRouterProvider` decides where the user
/// belongs.
class SplashScreen extends StatelessWidget {
  /// Creates the splash screen.
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircleAvatar(
              radius: 56,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.local_pharmacy,
                size: 96,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text('PharmaFlow', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Pharmacy management, simplified.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
