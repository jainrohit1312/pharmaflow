/// Canonical route locations shared by the router, the shell, and screens.
///
/// `Routes` declares no constructor on purpose: it is an `abstract final`
/// namespace, so it can never be instantiated, extended, or implemented. Every
/// location is an absolute path, which means it can be handed to `context.go`
/// from anywhere in the widget tree.
library;

/// Every navigation location used by PharmaFlow.
abstract final class Routes {
  /// Splash screen rendered while the stored session is restored.
  static const String splash = '/splash';

  /// Email/password sign-in screen.
  static const String login = '/login';

  /// Account creation screen.
  static const String register = '/register';

  /// Pharmacy onboarding for a signed-in account that has no pharmacy yet.
  ///
  /// Outside the shell on purpose: with no pharmacy there is nothing for the
  /// navigation destinations to show, so the user is not handed chrome that can
  /// only lead to failures.
  static const String onboardingPharmacy = '/onboarding/pharmacy';

  /// Post-login landing screen.
  static const String dashboard = '/dashboard';

  /// Product catalogue list.
  static const String products = '/products';

  /// Create-product form.
  ///
  /// The router must declare this before [productDetailPattern]: GoRouter
  /// matches in declaration order, so `/products/new` would otherwise be read
  /// as the id of a product called "new".
  static const String productForm = '/products/new';

  /// Route pattern for the edit form; the router needs a pattern, not a path.
  static const String productEditPattern = '/products/:productId/edit';

  /// Route pattern for one product's detail screen.
  static const String productDetailPattern = '/products/:productId';

  /// Path of the edit form for [productId].
  ///
  /// Kept next to [productEditPattern] so the two cannot drift apart: the
  /// router consumes the pattern, callers consume the path.
  static String productEdit(String productId) => '/products/$productId/edit';

  /// Path of the detail screen for [productId].
  static String productDetail(String productId) => '/products/$productId';

  /// Supplier master list.
  static const String suppliers = '/suppliers';

  /// Create-supplier form.
  ///
  /// Before [supplierDetailPattern], for the same reason as [productForm].
  static const String supplierForm = '/suppliers/new';

  /// Route pattern for the supplier edit form.
  static const String supplierEditPattern = '/suppliers/:supplierId/edit';

  /// Route pattern for one supplier's detail screen.
  static const String supplierDetailPattern = '/suppliers/:supplierId';

  /// Path of the edit form for [supplierId].
  static String supplierEdit(String supplierId) =>
      '/suppliers/$supplierId/edit';

  /// Path of the detail screen for [supplierId].
  static String supplierDetail(String supplierId) => '/suppliers/$supplierId';

  /// Customer master list.
  static const String customers = '/customers';

  /// Create-customer form.
  static const String customerForm = '/customers/new';

  /// Route pattern for the customer edit form.
  static const String customerEditPattern = '/customers/:customerId/edit';

  /// Route pattern for one customer's detail screen.
  static const String customerDetailPattern = '/customers/:customerId';

  /// Path of the edit form for [customerId].
  static String customerEdit(String customerId) =>
      '/customers/$customerId/edit';

  /// Path of the detail screen for [customerId].
  static String customerDetail(String customerId) => '/customers/$customerId';

  /// Batch-level stock inventory (Phase 1 placeholder).
  static const String inventory = '/inventory';

  /// Purchase and goods-received entry (Phase 1 placeholder).
  static const String purchase = '/purchase';

  /// Billing and point of sale (Phase 1 placeholder).
  static const String sales = '/sales';

  /// Sales returns and credit notes (Phase 1 placeholder).
  static const String returns = '/returns';

  /// Customer and supplier ledgers (Phase 1 placeholder).
  static const String ledger = '/ledger';

  /// Reports and analytics (Phase 1 placeholder).
  static const String reports = '/reports';

  /// Application and pharmacy settings (Phase 1 placeholder).
  static const String settings = '/settings';

  /// The four primary destinations shown in the bottom bar and the
  /// navigation rail. The order of this list defines the tab order.
  static const List<String> bottomNavPaths = <String>[
    dashboard,
    products,
    sales,
    reports,
  ];

  /// Every destination that lives behind the authenticated shell.
  ///
  /// The drawer lists all of them; the bottom bar and the navigation rail
  /// only show [bottomNavPaths]. The masters sit together, directly after the
  /// dashboard, because they are what the trading screens are built on.
  static const List<String> shellPaths = <String>[
    dashboard,
    products,
    suppliers,
    customers,
    inventory,
    purchase,
    sales,
    returns,
    ledger,
    reports,
    settings,
  ];
}
