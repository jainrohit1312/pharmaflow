/// Titled card used to group related content on detail and form screens.
library;

import 'package:flutter/material.dart';

/// A card with an optional heading and an optional trailing widget.
///
/// Detail and form screens are built from these so that section spacing and
/// heading weight stay consistent without repeating `Card` + `Padding` +
/// `Text` at every call site.
class SectionCard extends StatelessWidget {
  /// Creates a section card wrapping [child].
  const SectionCard({
    required this.child,
    super.key,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
  });

  /// Content of the section.
  final Widget child;

  /// Optional heading rendered above [child].
  final String? title;

  /// Optional widget aligned to the end of the heading row.
  final Widget? trailing;

  /// Padding applied inside the card.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = title;
    final trailingWidget = trailing;

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (heading != null || trailingWidget != null) ...<Widget>[
              Row(
                children: <Widget>[
                  if (heading != null)
                    Expanded(
                      child: Text(heading, style: theme.textTheme.titleMedium),
                    ),
                  if (trailingWidget != null) trailingWidget,
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}
