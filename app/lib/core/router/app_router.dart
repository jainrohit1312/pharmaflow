/// Router configuration for PharmaFlow.
///
/// The router owns authentication navigation: screens never push or replace
/// routes themselves. `redirect` reads the Supabase session straight from
/// [AuthRepository], and `refreshListenable` re-runs the redirect every time
/// the auth state changes.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:app/features/auth/data/auth_repository.dart';
import 'package:app/features/auth/presentation/login_screen.dart';
import 'package:app/features/auth/presentation/register_screen.dart';
import 'package:app/features/auth/presentation/splash_screen.dart';
import 'package:app/features/dashboard/presentation/dashboard_home.dart';
import 'package:app/features/dashboard/presentation/dashboard_shell.dart';
import 'package:app/features/inventory/presentation/inventory_placeholder.dart';
import 'package:app/features/ledger/presentation/ledger_placeholder.dart';
import 'package:app/features/products/presentation/products_placeholder.dart';
import 'package:app/features/purchase/presentation/purchase_placeholder.dart';
import 'package:app/features/reports/presentation/reports_placeholder.dart';
import 'package:app/features/returns/presentation/returns_placeholder.dart';
import 'package:app/features/sales/presentation/sales_placeholder.dart';
import 'package:app/features/settings/presentation/settings_placeholder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// The single [GoRouter] instance used by the application.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(authRepositoryProvider).currentSession;
      final location = state.uri.path;
      final isAuthLocation =
          location == Routes.login || location == Routes.register;

      if (session == null) {
        return isAuthLocation ? null : Routes.login;
      }
      if (location == Routes.splash || isAuthLocation) {
        return Routes.dashboard;
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: Routes.splash,
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.login,
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.register,
        name: 'register',
        builder: (context, state) => const RegisterScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => DashboardShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: Routes.dashboard,
            name: 'dashboard',
            builder: (context, state) => const DashboardHome(),
          ),
          GoRoute(
            path: Routes.products,
            name: 'products',
            builder: (context, state) => const ProductsPlaceholder(),
          ),
          GoRoute(
            path: Routes.inventory,
            name: 'inventory',
            builder: (context, state) => const InventoryPlaceholder(),
          ),
          GoRoute(
            path: Routes.purchase,
            name: 'purchase',
            builder: (context, state) => const PurchasePlaceholder(),
          ),
          GoRoute(
            path: Routes.sales,
            name: 'sales',
            builder: (context, state) => const SalesPlaceholder(),
          ),
          GoRoute(
            path: Routes.returns,
            name: 'returns',
            builder: (context, state) => const ReturnsPlaceholder(),
          ),
          GoRoute(
            path: Routes.ledger,
            name: 'ledger',
            builder: (context, state) => const LedgerPlaceholder(),
          ),
          GoRoute(
            path: Routes.reports,
            name: 'reports',
            builder: (context, state) => const ReportsPlaceholder(),
          ),
          GoRoute(
            path: Routes.settings,
            name: 'settings',
            builder: (context, state) => const SettingsPlaceholder(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => ErrorView(
      message: 'No screen matches ${state.uri.path}.',
      onRetry: () => context.go(Routes.dashboard),
    ),
  );
});

/// Bridges the auth state stream into a [Listenable] for [GoRouter].
class _AuthRouterRefresh extends ChangeNotifier {
  _AuthRouterRefresh(this._ref) {
    _subscription = _ref.listen<AsyncValue<sb.AuthState>>(
      authStateChangesProvider,
      (previous, next) => notifyListeners(),
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AsyncValue<sb.AuthState>> _subscription;

  /// Drops the provider subscription held by this listenable.
  void close() {
    _subscription.close();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
