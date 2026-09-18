/// Responsive navigation shell for every authenticated destination.
library;

import 'package:app/core/constants/app_constants.dart';
import 'package:app/core/router/routes.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Navigation metadata for one destination of the shell.
class _ShellDestination {
  const _ShellDestination({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// The location opened when the destination is tapped.
  final String path;

  /// Label shown in the bottom bar, the rail, and the drawer.
  final String label;

  /// Icon shown while the destination is not selected.
  final IconData icon;

  /// Icon shown while the destination is selected.
  final IconData selectedIcon;
}

const _ShellDestination _dashboardDestination = _ShellDestination(
  path: Routes.dashboard,
  label: 'Dashboard',
  icon: Icons.dashboard_outlined,
  selectedIcon: Icons.dashboard,
);

const _ShellDestination _productsDestination = _ShellDestination(
  path: Routes.products,
  label: 'Products',
  icon: Icons.medication_outlined,
  selectedIcon: Icons.medication,
);

const _ShellDestination _inventoryDestination = _ShellDestination(
  path: Routes.inventory,
  label: 'Inventory',
  icon: Icons.inventory_2_outlined,
  selectedIcon: Icons.inventory_2,
);

const _ShellDestination _purchaseDestination = _ShellDestination(
  path: Routes.purchase,
  label: 'Purchase',
  icon: Icons.shopping_cart_outlined,
  selectedIcon: Icons.shopping_cart,
);

const _ShellDestination _salesDestination = _ShellDestination(
  path: Routes.sales,
  label: 'Sales',
  icon: Icons.point_of_sale_outlined,
  selectedIcon: Icons.point_of_sale,
);

const _ShellDestination _returnsDestination = _ShellDestination(
  path: Routes.returns,
  label: 'Returns',
  icon: Icons.assignment_return_outlined,
  selectedIcon: Icons.assignment_return,
);

const _ShellDestination _ledgerDestination = _ShellDestination(
  path: Routes.ledger,
  label: 'Ledger',
  icon: Icons.account_balance_outlined,
  selectedIcon: Icons.account_balance,
);

const _ShellDestination _reportsDestination = _ShellDestination(
  path: Routes.reports,
  label: 'Reports',
  icon: Icons.bar_chart_outlined,
  selectedIcon: Icons.bar_chart,
);

const _ShellDestination _settingsDestination = _ShellDestination(
  path: Routes.settings,
  label: 'Settings',
  icon: Icons.settings_outlined,
  selectedIcon: Icons.settings,
);

/// The four primary destinations shown in the bottom bar and the rail.
const List<_ShellDestination> _primaryDestinations = <_ShellDestination>[
  _dashboardDestination,
  _productsDestination,
  _salesDestination,
  _reportsDestination,
];

/// Every destination behind the shell; the drawer lists all of them.
const List<_ShellDestination> _allDestinations = <_ShellDestination>[
  _dashboardDestination,
  _productsDestination,
  _inventoryDestination,
  _purchaseDestination,
  _salesDestination,
  _returnsDestination,
  _ledgerDestination,
  _reportsDestination,
  _settingsDestination,
];

/// Wraps every authenticated screen in the application chrome.
///
/// Phase 0 scope: the bottom bar (mobile) and the navigation rail
/// (tablet/desktop) only carry the four primary destinations, while inventory,
/// purchase, returns, ledger, and settings live in the drawer, which lists all
/// nine [Routes.shellPaths] entries. The shell deliberately does not render an
/// `AppBar` — every screen brings its own `AppScaffold` title — so the drawer is
/// opened with an edge swipe (or programmatically with
/// `ScaffoldState.openDrawer`).
///
/// Navigation is owned by the router: tapping a destination calls `context.go`
/// and never `setState`. The only reason this widget is stateful is that the
/// shell needs a `State` to host future drawer handling.
class DashboardShell extends StatefulWidget {
  /// Creates the shell that wraps the active destination.
  const DashboardShell({required this.child, super.key});

  /// The screen the router resolved for the current location.
  final Widget child;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  /// The primary-bar index for [path], or `0` when [path] is not primary.
  int _selectedIndexFor(String path) {
    final index = _primaryDestinations.indexWhere(
      (destination) => destination.path == path,
    );
    return index < 0 ? 0 : index;
  }

  void _open(String path) => context.go(path);

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final selectedIndex = _selectedIndexFor(path);
    final width = MediaQuery.sizeOf(context).width;
    final drawer = _AppDrawer(currentPath: path);

    if (width < AppConstants.mobileBreakpoint) {
      return Scaffold(
        drawer: drawer,
        body: widget.child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (index) =>
              _open(_primaryDestinations[index].path),
          destinations: <Widget>[
            for (final destination in _primaryDestinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
          ],
        ),
      );
    }

    final extended = width >= AppConstants.extendedRailBreakpoint;
    return Scaffold(
      drawer: drawer,
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: selectedIndex,
            extended: extended,
            labelType: extended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            onDestinationSelected: (index) =>
                _open(_primaryDestinations[index].path),
            destinations: <NavigationRailDestination>[
              for (final destination in _primaryDestinations)
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
            for (final destination in _allDestinations)
              ListTile(
                leading: Icon(destination.icon),
                title: Text(destination.label),
                selected: destination.path == currentPath,
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
