/// Application bootstrap sequence.
///
/// The boot order is fixed and must not be reordered:
///
/// 1. `dotenv.load` reads `.env`, which is declared under `assets:` in
///    `pubspec.yaml` — that declaration is what makes the file readable at
///    runtime.
/// 2. [Env] is asserted directly afterwards, so a missing or blank value fails
///    loudly during startup instead of on the first network call.
/// 3. [Supabase] is initialised with those values, which restores the persisted
///    session before the first frame.
/// 4. `runApp` mounts [PharmaFlowApp] inside a `ProviderScope`.
library;

import 'package:app/app.dart';
import 'package:app/core/constants/env.dart';
import 'package:app/core/utils/logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Loads configuration, initialises Supabase, and mounts the widget tree.
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  Env.assertLoaded();
  await Supabase.initialize(
    url: Env.supabaseUrl,
    // `anonKey` is the argument name the project spec mandates, paired with the
    // SUPABASE_ANON_KEY env var; `publishableKey` would rename that contract.
    // ignore: deprecated_member_use
    anonKey: Env.supabaseAnonKey,
  );
  FlutterError.onError = (FlutterErrorDetails details) {
    appLogger.e(
      'Uncaught Flutter error',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  runApp(const ProviderScope(child: PharmaFlowApp()));
}
