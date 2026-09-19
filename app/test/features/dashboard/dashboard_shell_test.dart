/// Widget tests for the responsive navigation shell.
///
/// The bug these pin: the desktop rail was built from the four-destination
/// primary list, and the shell renders no `AppBar`, so the drawer it also
/// configured had nothing to open it. Seven destinations - including the
/// Suppliers and Customers masters - were unreachable on any desktop window.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/dashboard/presentation/dashboard_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Every destination label, in rail order.
const List<String> _labels = <String>[
  'Dashboard',
  'Products',
  'Suppliers',
  'Customers',
  'Inventory',
  'Purchase',
  'Sales',
  'Returns',
  'Ledger',
  'Reports',
  // The twelfth destination, and the first cross-cutting utility rather than a
  // domain: it sits after Reports and before Settings (D-048), and is not one of
  // the four the bottom bar carries.
  'Notifications',
  // The thirteenth, and the second utility: it answers about every domain, so it
  // sits beside Notifications rather than under one of them (D-054).
  'Chatbot',
  'Settings',
];

/// A router that serves every shell destination through [DashboardShell], plus
/// one nested location under Products so the prefix rule can be exercised.
GoRouter _router({String initialLocation = Routes.dashboard}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    ShellRoute(
      builder: (context, state, child) => DashboardShell(child: child),
      routes: <RouteBase>[
        for (final path in Routes.shellPaths)
          GoRoute(
            path: path,
            builder: (context, state) =>
                Scaffold(body: Text('screen for $path')),
          ),
        GoRoute(
          path: '${Routes.products}/:productId',
          builder: (context, state) => Scaffold(
            body: Text('product ${state.pathParameters['productId']}'),
          ),
        ),
      ],
    ),
  ],
);

/// Pumps the shell in a window of [size] logical pixels.
Future<void> _pumpShell(
  WidgetTester tester, {
  required Size size,
  String initialLocation = Routes.dashboard,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final router = _router(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

/// The rail currently on screen.
NavigationRail _rail(WidgetTester tester) =>
    tester.widget<NavigationRail>(find.byType(NavigationRail));

void main() {
  testWidgets('desktop lists every destination in an expanded rail', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(1200, 900));

    expect(_rail(tester).destinations, hasLength(Routes.shellPaths.length));
    expect(
      _rail(tester).extended,
      isTrue,
      reason: 'labels have to be readable on desktop',
    );

    for (final label in _labels) {
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '$label must be reachable from the rail',
      );
    }

    expect(
      find.byType(Drawer),
      findsNothing,
      reason: 'nothing opens a drawer on desktop, so there must not be one',
    );
  });

  testWidgets('the rail and the router agree on what exists', (tester) async {
    await _pumpShell(tester, size: const Size(1200, 900));

    // The count is asserted on the rail's `destinations` list in the test above,
    // because `NavigationRailDestination` is a configuration object rather than
    // a widget: there is nothing of that type in the tree to count.
    expect(
      DashboardShell.destinationPaths,
      Routes.shellPaths,
      reason: 'the rail and the router must agree on what exists',
    );
  });

  testWidgets('the utility destinations stay out of the mobile bottom bar', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(500, 900));

    expect(DashboardShell.bottomBarPaths, hasLength(4));
    expect(
      DashboardShell.bottomBarPaths.contains(Routes.notifications),
      isFalse,
      reason: 'the bar carries the four trading surfaces and no more (D-048)',
    );
    expect(
      DashboardShell.bottomBarPaths.contains(Routes.chatbot),
      isFalse,
      reason: 'the chatbot is a utility, not one of the four (D-054)',
    );
  });

  testWidgets('tapping a rail destination navigates and highlights it', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(1200, 900));

    await tester.tap(find.text('Suppliers'));
    await tester.pumpAndSettle();

    expect(find.text('screen for ${Routes.suppliers}'), findsOneWidget);
    expect(
      _rail(tester).selectedIndex,
      2,
      reason: 'Suppliers is the third destination',
    );
  });

  testWidgets('a narrow desktop window collapses the rail, keeping all of it', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(800, 900));

    expect(_rail(tester).destinations, hasLength(Routes.shellPaths.length));
    expect(
      _rail(tester).extended,
      isFalse,
      reason: 'auto-collapsed because the window is too narrow for labels',
    );
  });

  testWidgets('the rail can be collapsed and expanded by hand', (tester) async {
    await _pumpShell(tester, size: const Size(1400, 900));
    expect(_rail(tester).extended, isTrue);

    await tester.tap(find.byTooltip('Collapse menu'));
    await tester.pumpAndSettle();
    expect(_rail(tester).extended, isFalse);

    await tester.tap(find.byTooltip('Expand menu'));
    await tester.pumpAndSettle();
    expect(_rail(tester).extended, isTrue);
  });

  testWidgets('a nested location keeps its section highlighted', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      size: const Size(1200, 900),
      initialLocation: '${Routes.products}/abc',
    );

    expect(find.text('product abc'), findsOneWidget);
    expect(
      _rail(tester).selectedIndex,
      1,
      reason: 'Products stays highlighted on a child location',
    );
  });

  testWidgets('mobile keeps four destinations and the full drawer', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(500, 900));

    expect(find.byType(NavigationRail), findsNothing);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations, hasLength(4));

    // `.first` is the shell's own Scaffold: the drawer lives there, and the
    // screen's Scaffold is nested inside it.
    final shell = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      shell.drawer,
      isNotNull,
      reason: 'the drawer is the only route to the other seven destinations',
    );

    // Opened programmatically because the shell renders no AppBar, so there is
    // no hamburger to tap: on a phone the drawer is reached by edge swipe.
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();

    for (final label in _labels) {
      expect(
        find.descendant(of: find.byType(Drawer), matching: find.text(label)),
        findsOneWidget,
        reason: '$label must be listed in the drawer',
      );
    }
  });
}
