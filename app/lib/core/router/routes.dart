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

  /// Post-login landing screen.
  static const String dashboard = '/dashboard';

  /// Product catalogue (Phase 1 placeholder).
  static const String products = '/products';

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
  /// only show [bottomNavPaths].
  static const List<String> shellPaths = <String>[
    dashboard,
    products,
    inventory,
    purchase,
    sales,
    returns,
    ledger,
    reports,
    settings,
  ];
}
