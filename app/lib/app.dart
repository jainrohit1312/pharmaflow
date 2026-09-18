/// Root widget of the PharmaFlow application.
library;

import 'package:app/core/constants/app_constants.dart';
import 'package:app/core/router/app_router.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Root of the PharmaFlow widget tree.
///
/// The widget only wires the theme and the single GoRouter exposed by
/// [appRouterProvider] into `MaterialApp.router`, so every navigation decision
/// flows through Riverpod instead of through widget state.
class PharmaFlowApp extends ConsumerWidget {
  /// Creates the application root.
  const PharmaFlowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
