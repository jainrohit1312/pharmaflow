/// Responsive navigation shell for every authenticated destination.
library;

import 'package:app/core/constants/app_constants.dart';
import 'package:app/core/router/routes.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Navigation metadata for one destination of the shell.
class _NavDestination {
  const _NavDestination({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.inBottomBar = false,
  });

  /// The location opened when the destination is tapped.
  final String path;

  /// Label shown in the rail, the bottom bar and the drawer.
  final String label;

  /// Icon shown while the destination is not selected.
  final IconData icon;

  /// Icon shown while the destination is selected.
  final IconData selectedIcon;

  /// Whether this destination also earns a place in the mobile bottom bar.
  ///
  /// Only four do. Flagging it here rather than slicing the list keeps the rail
  /// free to group related screens (the masters together) without that ordering
  /// deciding what the bottom bar shows.
  final bool inBottomBar;
}

/// Every destination behind the shell, in the order the rail lists them.
///
/// The single source of truth for navigation: the rail renders all of them, the
/// drawer renders all of them, and the bottom bar renders those flagged
/// `inBottomBar`. Adding a route means adding one entry here.
///
/// The order mirrors [Routes.shellPaths], and `DashboardShell.destinationPaths`
/// exposes it so a test can hold the two together.
const List<_NavDestination> _navDestinations = <_NavDestination>[
  _NavDestination(
    path: Routes.dashboard,
    label: 'Dashboard',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    inBottomBar: true,
  ),
  _NavDestination(
    path: Routes.products,
    label: 'Products',
    icon: Icons.medication_outlined,
    selectedIcon: Icons.medication,
    inBottomBar: true,
  ),
  _NavDestination(
    path: Routes.suppliers,
    label: 'Suppliers',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
  ),
  _NavDestination(
    path: Routes.customers,
    label: 'Customers',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
  ),
  _NavDestination(
    path: Routes.inventory,
    label: 'Inventory',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
  ),
  _NavDestination(
    path: Routes.purchase,
    label: 'Purchase',
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart,
  ),
  _NavDestination(
    path: Routes.sales,
    label: 'Sales',
    icon: Icons.point_of_sale_outlined,
    selectedIcon: Icons.point_of_sale,
    inBottomBar: true,
  ),
  _NavDestination(
    path: Routes.returns,
    label: 'Returns',
    icon: Icons.assignment_return_outlined,
    selectedIcon: Icons.assignment_return,
  ),
  _NavDestination(
    path: Routes.ledger,
    label: 'Ledger',
    icon: Icons.account_balance_outlined,
    selectedIcon: Icons.account_balance,
  ),
  _NavDestination(
    path: Routes.reports,
    label: 'Reports',
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
    inBottomBar: true,
  ),
  _NavDestination(
    path: Routes.notifications,
    label: 'Notifications',
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
  ),
  _NavDestination(
    path: Routes.settings,
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

/// The destinations the mobile bottom bar carries, in bar order.
final List<_NavDestination> _bottomBarDestinations = _navDestinations
    .where((destination) => destination.inBottomBar)
    .toList(growable: false);

/// Whether [path] is [destination]'s own location or one of its children.
///
/// Prefix rather than equality, so a screen nested under a section
/// (`/products/123`) still highlights that section. Shared by the rail, the
/// bottom bar and the drawer so they cannot disagree about where the user is.
bool _belongsTo(String path, String destination) =>
    path == destination || path.startsWith('$destination/');

/// Wraps every authenticated screen in the application chrome.
///
/// Desktop and tablet (>= [AppConstants.mobileBreakpoint]) get a
/// [NavigationRail] carrying **all** destinations, expanded so the labels are
/// readable: a pharmacy's desktop work moves constantly between billing, stock
/// and masters, and hiding seven screens behind a hamburger - a phone pattern
/// that this shell has no hamburger for - made them unreachable. A toggle pins
/// the rail collapsed for narrow desktop windows.
///
/// Mobile keeps the four-destination bottom bar plus the full drawer, because a
/// phone is held for the counter flows and a five-item-or-more bottom bar is not
/// usable.
///
/// The shell deliberately does not render an `AppBar` — every screen brings its
/// own `AppScaffold` title — so on mobile the drawer is opened by edge swipe.
class DashboardShell extends StatefulWidget {
  /// Creates the shell that wraps the active destination.
  const DashboardShell({required this.child, super.key});

  /// The screen the router resolved for the current location.
  final Widget child;

  /// The paths behind the shell, in the order the rail lists them.
  ///
  /// Exposed so a test can assert it matches [Routes.shellPaths]. The two lists
  /// are parallel by necessity - the router cannot depend on a widget's icons -
  /// and drift between them is exactly the bug where a destination exists but
  /// nothing leads to it.
  @visibleForTesting
  static List<String> get destinationPaths => _navDestinations
      .map((destination) => destination.path)
      .toList(growable: false);

  /// The paths the mobile bottom bar carries, in bar order.
  ///
  /// Exposed for the same reason as [destinationPaths]: the router's
  /// [Routes.bottomNavPaths] and this list have to agree, and a silent
  /// disagreement is a destination that vanishes on a phone.
  @visibleForTesting
  static List<String> get bottomBarPaths => _bottomBarDestinations
      .map((destination) => destination.path)
      .toList(growable: false);

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  /// Whether the rail is expanded, or `null` while the width decides.
  ///
  /// `null` means "expand when there is room for labels". Once the user toggles
  /// it, their choice wins for the rest of the session.
  bool? _railExpandedByUser;

  /// Whether the rail should show labels at [width].
  bool _isRailExpanded(double width) =>
      _railExpandedByUser ?? width >= AppConstants.extendedRailBreakpoint;

  /// The index of [path] among all destinations, or `0` when it matches none.
  int _selectedIndex(String path) {
    final index = _navDestinations.indexWhere(
      (destination) => _belongsTo(path, destination.path),
    );
    return index < 0 ? 0 : index;
  }

  /// The bottom-bar index for [path], or `0` when it is not in the bar.
  int _bottomBarIndex(String path) {
    final index = _bottomBarDestinations.indexWhere(
      (destination) => _belongsTo(path, destination.path),
    );
    return index < 0 ? 0 : index;
  }

  void _open(String path) => context.go(path);

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final width = MediaQuery.sizeOf(context).width;

    if (width < AppConstants.mobileBreakpoint) {
      return Scaffold(
        drawer: _AppDrawer(currentPath: path),
        body: widget.child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _bottomBarIndex(path),
          onDestinationSelected: (index) =>
              _open(_bottomBarDestinations[index].path),
          destinations: <Widget>[
            for (final destination in _bottomBarDestinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
          ],
        ),
      );
    }

    final isExpanded = _isRailExpanded(width);
    return Scaffold(
      // No drawer on desktop: every destination is already in the rail, and the
      // shell renders no AppBar, so a drawer here would be a second copy of the
      // same list that nothing could open.
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _selectedIndex(path),
            extended: isExpanded,
            // `extended` draws the labels itself, so asking for them again here
            // would be redundant (and mismatched combinations assert). `null` is
            // the rail's default, which is "no labels" - what extended mode
            // wants.
            labelType: isExpanded ? null : NavigationRailLabelType.all,
            // Twelve destinations do not fit a short window: without this the
            // rail overflows rather than scrolling.
            scrollable: true,
            // `leading` is pinned above the scroll area by default, so the
            // collapse control stays put while the destinations scroll.
            leading: _RailToggle(
              isExpanded: isExpanded,
              onPressed: () =>
                  setState(() => _railExpandedByUser = !isExpanded),
            ),
            onDestinationSelected: (index) =>
                _open(_navDestinations[index].path),
            destinations: <NavigationRailDestination>[
              for (final destination in _navDestinations)
                NavigationRailDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

/// Collapse / expand control pinned above the rail's destinations.
class _RailToggle extends StatelessWidget {
  const _RailToggle({required this.isExpanded, required this.onPressed});

  /// Whether the rail is currently showing labels.
  final bool isExpanded;

  /// Called to flip that.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: IconButton(
      icon: Icon(isExpanded ? Icons.chevron_left : Icons.chevron_right),
      tooltip: isExpanded ? 'Collapse menu' : 'Expand menu',
      onPressed: onPressed,
    ),
  );
}

/// Drawer that lists every destination behind the shell.
class _AppDrawer extends StatelessWidget {
  const _AppDrawer({required this.currentPath});

  /// The location the router is currently showing.
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            DrawerHeader(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Icon(
                    Icons.local_pharmacy,
                    size: 32,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppConstants.appName,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            for (final destination in _navDestinations)
              ListTile(
                leading: Icon(destination.icon),
                title: Text(destination.label),
                selected: _belongsTo(currentPath, destination.path),
                onTap: () {
                  Navigator.of(context).pop();
                  context.go(destination.path);
                },
              ),
          ],
        ),
      ),
    );
  }
}
