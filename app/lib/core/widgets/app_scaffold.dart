/// Consistent [Scaffold] wrapper used by every PharmaFlow screen.
library;

import 'package:flutter/material.dart';

/// Page shell that applies the app's app-bar and body-padding conventions.
class AppScaffold extends StatelessWidget {
  /// Creates a page scaffold.
  const AppScaffold({
    super.key,
    this.title,
    this.body,
    this.actions,
    this.leading,
    this.floatingActionButton,
    this.drawer,
    this.bottomNavigationBar,
    this.padding,
  });

  /// Title rendered in the app bar.
  ///
  /// The app bar is omitted entirely when [title], [actions] and [leading] are
  /// all `null`, so full-bleed pages do not reserve an empty toolbar.
  final String? title;

  /// Page content.
  final Widget? body;

  /// Widgets placed after the title in the app bar.
  final List<Widget>? actions;

  /// App-bar leading widget; defaults to the drawer menu button when a
  /// [drawer] is supplied.
  final Widget? leading;

  /// Floating action button for the page.
  final Widget? floatingActionButton;

  /// Drawer opened from the app bar or by edge swipe.
  final Widget? drawer;

  /// Bottom navigation bar, or any other widget pinned below the body.
  final Widget? bottomNavigationBar;

  /// Padding applied around [body].
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final appBarTitle = title;
    final bodyContent = body ?? const SizedBox.shrink();
    final bodyPadding = padding;
    final hasAppBar = appBarTitle != null || actions != null || leading != null;

    return Scaffold(
      appBar: hasAppBar
          ? AppBar(
              title: appBarTitle == null ? null : Text(appBarTitle),
              leading: leading,
              actions: actions,
            )
          : null,
      body: bodyPadding == null
          ? bodyContent
          : Padding(padding: bodyPadding, child: bodyContent),
      floatingActionButton: floatingActionButton,
      drawer: drawer,
      bottomNavigationBar: bottomNavigationBar,
    );
  }
}
