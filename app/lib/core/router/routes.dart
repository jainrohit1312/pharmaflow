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

  /// Route pattern for one admission episode's account.
  ///
  /// Top-level rather than nested under the customer, because an episode is reached
  /// from two places that are not its parent - the patient's detail and the bill a stay
  /// was charged to - and a nested path would tie it to one of them.
  static const String admissionPattern = '/admissions/:admissionId';

  /// Path of the account for [admissionId].
  static String admission(String admissionId) => '/admissions/$admissionId';

  /// Stock, reorder levels and expiry. Also the shell's Inventory destination.
  static const String inventory = '/inventory';

  /// Expiry calendar: a month of shelf life, by day.
  ///
  /// A child of the inventory destination rather than a shell destination of its
  /// own: it answers a question about the inventory, and the shell has no room
  /// for a twelfth entry that only reads the same rows.
  static const String inventoryCalendar = '/inventory/calendar';

  /// Purchase document list. Also the shell's Purchase destination.
  static const String purchase = '/purchase';

  /// Reads a supplier bill into a purchase draft (Phase 5's OCR flow).
  ///
  /// Before [purchaseDetailPattern], like [purchaseGrnForm]: GoRouter matches in
  /// declaration order, so `/purchase/ocr` must not be read as the id of a
  /// document called "ocr".
  static const String purchaseOcr = '/purchase/ocr';

  /// Standalone goods receipt, for goods that arrive without a purchase order.
  ///
  /// Declared before [purchaseDetailPattern], for the same reason as
  /// [productForm]: GoRouter matches in declaration order, so `/purchase/grn`
  /// would otherwise be read as the id of a document called "grn".
  static const String purchaseGrnForm = '/purchase/grn';

  /// Create-purchase form.
  ///
  /// Before [purchaseDetailPattern] as well, so `/purchase/new` is not read as
  /// an id.
  static const String purchaseForm = '/purchase/new';

  /// Route pattern for the purchase edit form.
  static const String purchaseEditPattern = '/purchase/:purchaseId/edit';

  /// Route pattern for one document's goods receipt.
  static const String purchaseGrnPattern = '/purchase/:purchaseId/grn';

  /// Route pattern for one purchase's detail screen.
  static const String purchaseDetailPattern = '/purchase/:purchaseId';

  /// Path of the edit form for [purchaseId].
  static String purchaseEdit(String purchaseId) => '/purchase/$purchaseId/edit';

  /// Path of the goods receipt for [purchaseId].
  static String purchaseGrn(String purchaseId) => '/purchase/$purchaseId/grn';

  /// Path of the detail screen for [purchaseId].
  static String purchaseDetail(String purchaseId) => '/purchase/$purchaseId';

  /// Billing and point of sale. Also the shell's Sales destination.
  static const String sales = '/sales';

  /// The counter: search, basket, payment.
  ///
  /// Declared before [saleDetailPattern], for the same reason as [productForm]:
  /// GoRouter matches in declaration order, so `/sales/new` would otherwise be read
  /// as the id of a sale called "new".
  static const String pos = '/sales/new';

  /// Route pattern for one sale's bill.
  static const String saleDetailPattern = '/sales/:saleId';

  /// Path of the bill for [saleId].
  static String saleDetail(String saleId) => '/sales/$saleId';

  /// Sales returns and credit notes (Phase 1 placeholder).
  ///
  /// Also the purchase returns list: a pharmacy has one Returns door, and the
  /// sale side of it arrives in Phase 3.
  static const String returns = '/returns';

  /// Create-purchase-return form.
  ///
  /// Declared before [returnsDetailPattern], for the same reason as
  /// [productForm]: GoRouter matches in declaration order, so `/returns/new`
  /// would otherwise be read as the id of a return called "new".
  static const String returnsForm = '/returns/new';

  /// Create-sale-return form, for goods a customer brought back.
  static const String saleReturnForm = '/returns/sale/new';

  /// Route pattern for one purchase return.
  static const String returnsDetailPattern = '/returns/:returnId';

  /// Path of the detail screen for [returnId].
  static String returnDetail(String returnId) => '/returns/$returnId';

  /// Customer and supplier ledgers: what each party owes, and the entries behind it.
  static const String ledger = '/ledger';

  /// Reports and analytics: one summary per window, plus the way to expenses.
  static const String reports = '/reports';

  /// Expenses: what the pharmacy spent, and the sheet that records it.
  ///
  /// Nested under [reports] rather than given a top-level `/expenses`, for the
  /// reason `/inventory/calendar` is nested under inventory: it is a child of
  /// that destination, reached from the summary it feeds, and the shell
  /// highlights a destination by prefix (`_belongsTo`). A top-level path would be
  /// the first route matching no destination, so the rail would sit on Dashboard
  /// while the user was reading their expenses. Twelve destinations in the rail
  /// is not what this needs either.
  static const String expenses = '/reports/expenses';

  /// The in-app notification list, and the alerts beside it.
  ///
  /// A **top-level destination** rather than a child of any one module (D-048):
  /// notifications span every domain - a low-stock alert is inventory, an expiry
  /// alert is stock, a payable reminder is a purchase, a payment receipt is sales -
  /// so nesting the list under whichever module was chosen first would make the
  /// others look like second-class answers. It sits with `/settings` as a
  /// cross-cutting utility instead.
  ///
  /// Phase 6 and later nest *under* it: dispatch settings and notification
  /// preferences go at `/notifications/…`, the way `/reports/expenses` does, so the
  /// rail keeps highlighting this destination.
  static const String notifications = '/notifications';

  /// The chatbot: questions about this pharmacy's stock, sales and expiry,
  /// answered from its own numbers.
  ///
  /// A **top-level destination** for [notifications]' reason (D-048), applied again
  /// (D-054): the reports it answers from span every domain — a low-stock question
  /// is inventory, what sells best is sales, what is expiring is stock, what is
  /// still owed is purchases and the ledger — so nesting it under whichever module
  /// was chosen first would make the others look like second-class answers. It sits
  /// with `/notifications` and `/settings` in the utility group at the foot of the
  /// rail, and is not one of the four the bottom bar carries.
  static const String chatbot = '/chatbot';

  /// Application and pharmacy settings (Phase 1 placeholder).
  static const String settings = '/settings';

  /// The one-time opening stock import (Phase 6.5a): a CSV of the pharmacy's
  /// existing stock, read into products and batches.
  ///
  /// Nested under [settings] rather than given a top-level `/import/opening-stock`,
  /// for the reason `/reports/expenses` is nested under reports (D-022): the shell
  /// lights a destination by prefix, so a path matching none of them would leave
  /// the rail sitting on Dashboard while the owner was reading their import. It is
  /// also not a destination of its own - it is a one-time migration the owner runs
  /// once, reached from the settings it belongs to.
  static const String openingStockImport = '/settings/import/opening-stock';

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
    notifications,
    chatbot,
    settings,
  ];
}
