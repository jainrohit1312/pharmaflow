/// Router configuration for PharmaFlow.
///
/// The router owns authentication navigation: screens never push or replace
/// routes themselves. `redirect` reads the Supabase session straight from
/// [AuthRepository], and `refreshListenable` re-runs the redirect every time
/// the auth state changes.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:app/features/auth/data/auth_repository.dart';
import 'package:app/features/auth/presentation/login_screen.dart';
import 'package:app/features/auth/presentation/register_screen.dart';
import 'package:app/features/auth/presentation/splash_screen.dart';
import 'package:app/features/customers/presentation/customers_detail_screen.dart';
import 'package:app/features/customers/presentation/customers_form_screen.dart';
import 'package:app/features/customers/presentation/customers_screen.dart';
import 'package:app/features/dashboard/presentation/dashboard_home.dart';
import 'package:app/features/dashboard/presentation/dashboard_shell.dart';
import 'package:app/features/inventory/presentation/expiry_calendar_screen.dart';
import 'package:app/features/inventory/presentation/inventory_screen.dart';
import 'package:app/features/ledger/presentation/ledger_placeholder.dart';
import 'package:app/features/onboarding/presentation/onboarding_pharmacy_screen.dart';
import 'package:app/features/products/presentation/products_detail_screen.dart';
import 'package:app/features/products/presentation/products_form_screen.dart';
import 'package:app/features/products/presentation/products_screen.dart';
import 'package:app/features/purchase/presentation/grn_screen.dart';
import 'package:app/features/purchase/presentation/purchase_detail_screen.dart';
import 'package:app/features/purchase/presentation/purchase_form_screen.dart';
import 'package:app/features/purchase/presentation/purchases_screen.dart';
import 'package:app/features/reports/presentation/reports_placeholder.dart';
import 'package:app/features/returns/presentation/purchase_return_detail_screen.dart';
import 'package:app/features/returns/presentation/purchase_return_form_screen.dart';
import 'package:app/features/returns/presentation/returns_screen.dart';
import 'package:app/features/sales/presentation/sales_placeholder.dart';
import 'package:app/features/settings/presentation/settings_placeholder.dart';
import 'package:app/features/suppliers/presentation/suppliers_detail_screen.dart';
import 'package:app/features/suppliers/presentation/suppliers_form_screen.dart';
import 'package:app/features/suppliers/presentation/suppliers_screen.dart';
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
      final isOnboarding = location == Routes.onboardingPharmacy;

      if (session == null) {
        return isAuthLocation ? null : Routes.login;
      }
      if (location == Routes.splash || isAuthLocation) {
        return Routes.dashboard;
      }

      // Whether this account has a pharmacy decides where it belongs, and the
      // profile arrives after the session does. While it is still loading there
      // is no answer yet: sending a linked user into onboarding would be the
      // same mistake as reporting a loading profile as "unlinked", one layer up.
      final profileState = ref.read(authControllerProvider);
      if (profileState.isLoading && !profileState.hasValue) {
        return null;
      }
      final profile = profileState.value;
      final needsOnboarding = profile != null && profile.pharmacyId == null;

      if (needsOnboarding && !isOnboarding) {
        return Routes.onboardingPharmacy;
      }
      if (!needsOnboarding && isOnboarding) {
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
      GoRoute(
        path: Routes.onboardingPharmacy,
        name: 'onboardingPharmacy',
        builder: (context, state) => const OnboardingPharmacyScreen(),
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
            builder: (context, state) => const ProductsScreen(),
          ),
          // Declared before the parameterised routes: GoRouter matches in
          // order, so `/products/new` would otherwise be read as a product id.
          GoRoute(
            path: Routes.productForm,
            name: 'productForm',
            builder: (context, state) => const ProductsFormScreen(),
          ),
          GoRoute(
            path: Routes.productEditPattern,
            name: 'productEdit',
            builder: (context, state) => ProductsFormScreen(
              productId: state.pathParameters['productId'],
            ),
          ),
          GoRoute(
            path: Routes.productDetailPattern,
            name: 'productDetail',
            builder: (context, state) => ProductsDetailScreen(
              productId: state.pathParameters['productId']!,
            ),
          ),
          // Masters: the flat list route, then the create form, then the
          // parameterised routes - declaration order is match order.
          GoRoute(
            path: Routes.suppliers,
            name: 'suppliers',
            builder: (context, state) => const SuppliersScreen(),
          ),
          GoRoute(
            path: Routes.supplierForm,
            name: 'supplierForm',
            builder: (context, state) => const SuppliersFormScreen(),
          ),
          GoRoute(
            path: Routes.supplierEditPattern,
            name: 'supplierEdit',
            builder: (context, state) => SuppliersFormScreen(
              supplierId: state.pathParameters['supplierId'],
            ),
          ),
          GoRoute(
            path: Routes.supplierDetailPattern,
            name: 'supplierDetail',
            builder: (context, state) => SuppliersDetailScreen(
              supplierId: state.pathParameters['supplierId']!,
            ),
          ),
          GoRoute(
            path: Routes.customers,
            name: 'customers',
            builder: (context, state) => const CustomersScreen(),
          ),
          GoRoute(
            path: Routes.customerForm,
            name: 'customerForm',
            builder: (context, state) => const CustomersFormScreen(),
          ),
          GoRoute(
            path: Routes.customerEditPattern,
            name: 'customerEdit',
            builder: (context, state) => CustomersFormScreen(
              customerId: state.pathParameters['customerId'],
            ),
          ),
          GoRoute(
            path: Routes.customerDetailPattern,
            name: 'customerDetail',
            builder: (context, state) => CustomersDetailScreen(
              customerId: state.pathParameters['customerId']!,
            ),
          ),
          GoRoute(
            path: Routes.inventory,
            name: 'inventory',
            builder: (context, state) => const InventoryScreen(),
          ),
          // A child of the inventory destination, declared right after it: the
          // two share a prefix and neither is a parameterised path, so order is
          // only cosmetic here - but a reader looking for inventory routes finds
          // them together.
          GoRoute(
            path: Routes.inventoryCalendar,
            name: 'inventoryCalendar',
            builder: (context, state) => const ExpiryCalendarScreen(),
          ),
          // Purchase: the list route first, then the routes whose first
          // segment is a literal, then the parameterised ones. Declaration
          // order is match order, so `/purchase/grn` must not be read as the
          // id of a document called "grn".
          GoRoute(
            path: Routes.purchase,
            name: 'purchase',
            builder: (context, state) => const PurchasesScreen(),
          ),
          GoRoute(
            path: Routes.purchaseGrnForm,
            name: 'purchaseGrnForm',
            builder: (context, state) => const GrnScreen(),
          ),
          GoRoute(
            path: Routes.purchaseForm,
            name: 'purchaseForm',
            builder: (context, state) => const PurchaseFormScreen(),
          ),
          GoRoute(
            path: Routes.purchaseEditPattern,
            name: 'purchaseEdit',
            builder: (context, state) => PurchaseFormScreen(
              purchaseId: state.pathParameters['purchaseId'],
            ),
          ),
          GoRoute(
            path: Routes.purchaseGrnPattern,
            name: 'purchaseGrn',
            builder: (context, state) =>
                GrnScreen(purchaseId: state.pathParameters['purchaseId']),
          ),
          GoRoute(
            path: Routes.purchaseDetailPattern,
            name: 'purchaseDetail',
            builder: (context, state) => PurchaseDetailScreen(
              purchaseId: state.pathParameters['purchaseId']!,
            ),
          ),
          GoRoute(
            path: Routes.sales,
            name: 'sales',
            builder: (context, state) => const SalesPlaceholder(),
          ),
          GoRoute(
            path: Routes.returns,
            name: 'returns',
            builder: (context, state) => const ReturnsScreen(),
          ),
          // Before the parameterised pattern, so `/returns/new` is not read as
          // the id of a return called "new".
          GoRoute(
            path: Routes.returnsForm,
            name: 'returnsForm',
            builder: (context, state) => const PurchaseReturnFormScreen(),
          ),
          GoRoute(
            path: Routes.returnsDetailPattern,
            name: 'returnDetail',
            builder: (context, state) => PurchaseReturnDetailScreen(
              returnId: state.pathParameters['returnId']!,
            ),
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
    _authState = _ref.listen<AsyncValue<sb.AuthState>>(
      authStateChangesProvider,
      (previous, next) => notifyListeners(),
    );
    // The profile is listened to as well, not just the session: the redirect has
    // to know whether the account has a pharmacy, and that answer arrives after
    // the session does - including right after onboarding links one.
    _profile = _ref.listen<AsyncValue<Profile?>>(
      authControllerProvider,
      (previous, next) => notifyListeners(),
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AsyncValue<sb.AuthState>> _authState;
  late final ProviderSubscription<AsyncValue<Profile?>> _profile;

  /// Drops the provider subscriptions held by this listenable.
  void close() {
    _authState.close();
    _profile.close();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
