/// Themed text field with an optional obscure-text toggle.
library;

import 'package:flutter/material.dart';

/// PharmaFlow's standard form text field.
///
/// Stateful only because it owns the show/hide toggle used when [obscureText]
/// is true; everything else is forwarded to the framework's `TextFormField`.
class AppTextField extends StatefulWidget {
  /// Creates a themed text field.
  const AppTextField({
    required this.controller,
    required this.label,
    super.key,
    this.hint,
    this.prefixIcon,
    this.validator,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
    this.enabled = true,
    this.suffix,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
  });

  /// Controller holding the field's text and selection.
  final TextEditingController controller;

  /// Floating label describing the field.
  final String label;

  /// Optional placeholder shown while the field is empty.
  final String? hint;

  /// Optional leading icon, typically from `Icons`.
  final IconData? prefixIcon;

  /// Form validator called on save/validate.
  final FormFieldValidator<String>? validator;

  /// When true the value is hidden behind a show/hide toggle.
  final bool obscureText;

  /// Keyboard layout requested from the platform.
  final TextInputType? keyboardType;

  /// Action key shown on the soft keyboard.
  final TextInputAction? textInputAction;

  /// Called when the user submits the field.
  final ValueChanged<String>? onSubmitted;

  /// Autofill hints consumed by the platform's password/credential managers.
  final Iterable<String>? autofillHints;

  /// Whether the field accepts input.
  final bool enabled;

  /// Trailing widget; replaces the built-in obscure toggle when provided.
  final Widget? suffix;

  /// Maximum number of visible lines (forced to 1 while obscured).
  final int maxLines;

  /// Capitalisation applied by the soft keyboard.
  final TextCapitalization textCapitalization;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  /// Set by the eye toggle; only meaningful while [AppTextField.obscureText].
  bool _revealed = false;

  /// The effective obscure flag, kept in sync with the widget's own flag so
  /// that a parent rebuilding with a new `obscureText` value just works.
  bool get _isObscured => widget.obscureText && !_revealed;

  @override
  Widget build(BuildContext context) {
    final prefixIcon = widget.prefixIcon;
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _isObscured,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      textCapitalization: widget.textCapitalization,
      autofillHints: widget.autofillHints,
      maxLines: _isObscured ? 1 : widget.maxLines,
      validator: widget.validator,
      onFieldSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
        suffixIcon: _buildSuffix(),
      ),
    );
  }

  /// Returns the caller's [AppTextField.suffix], else the obscure toggle.
  Widget? _buildSuffix() {
    if (widget.suffix != null) {
      return widget.suffix;
    }
    if (!widget.obscureText) {
      return null;
    }
    return IconButton(
      onPressed: () => setState(() => _revealed = !_revealed),
      tooltip: _revealed ? 'Hide text' : 'Show text',
      icon: Icon(
        _revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      ),
    );
  }
}
