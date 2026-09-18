/// Themed button with filled, outlined and text variants.
library;

import 'package:flutter/material.dart';

/// Visual styles supported by [AppButton].
enum _AppButtonVariant { primary, outlined, text }

/// Primary interaction control used across PharmaFlow screens.
///
/// All variants share the same label/icon layout, loading behaviour and
/// full-width option, and take their colours from the app theme.
class AppButton extends StatelessWidget {
  /// Filled button that carries the theme's primary colour.
  const AppButton.primary({
    required this.label,
    super.key,
    this.onPressed,
    this.isLoading = false,
    this.icon,
    this.expand = true,
  }) : _variant = _AppButtonVariant.primary;

  /// Outlined button for secondary actions.
  const AppButton.outlined({
    required this.label,
    super.key,
    this.onPressed,
    this.isLoading = false,
    this.icon,
    this.expand = true,
  }) : _variant = _AppButtonVariant.outlined;

  /// Text button for low-emphasis actions.
  const AppButton.text({
    required this.label,
    super.key,
    this.onPressed,
    this.isLoading = false,
    this.icon,
    this.expand = true,
  }) : _variant = _AppButtonVariant.text;

  /// Text shown inside the button.
  final String label;

  /// Callback fired on tap; `null` renders the button disabled.
  final VoidCallback? onPressed;

  /// When true a spinner replaces the content and taps are ignored.
  final bool isLoading;

  /// Optional icon rendered before the label.
  final IconData? icon;

  /// When true the button stretches to the width of its parent.
  final bool expand;

  final _AppButtonVariant _variant;

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed = isLoading ? null : onPressed;
    final content = _buildContent(context);

    final button = switch (_variant) {
      _AppButtonVariant.primary => ElevatedButton(
        onPressed: effectiveOnPressed,
        child: content,
      ),
      _AppButtonVariant.outlined => OutlinedButton(
        onPressed: effectiveOnPressed,
        child: content,
      ),
      _AppButtonVariant.text => TextButton(
        onPressed: effectiveOnPressed,
        child: content,
      ),
    };

    if (!expand) {
      return button;
    }
    return SizedBox(width: double.infinity, child: button);
  }

  /// Builds the spinner, or the icon + label pair when idle.
  Widget _buildContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (isLoading) {
      final loaderColor = _variant == _AppButtonVariant.primary
          ? colorScheme.onPrimary
          : colorScheme.primary;
      return SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(loaderColor),
        ),
      );
    }

    final labelWidget = Text(label);
    final buttonIcon = icon;
    if (buttonIcon == null) {
      return labelWidget;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(buttonIcon, size: 18),
        const SizedBox(width: 8),
        labelWidget,
      ],
    );
  }
}
