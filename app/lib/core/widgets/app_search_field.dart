/// Search input with a clear affordance, used above every list.
library;

import 'package:flutter/material.dart';

/// A plain text input styled as a search box.
///
/// Deliberately does no debouncing: the controller that consumes [onChanged]
/// owns that decision (via `Debouncer`), because the delay is a policy of the
/// query, not of the widget.
class AppSearchField extends StatefulWidget {
  /// Creates a search field.
  ///
  /// [controller], [focusNode] and [onSubmitted] are optional because most callers
  /// only need [onChanged]. A caller that has to drive the field - the counter,
  /// which clears it on a selection and puts the caret back in it - passes its own
  /// [controller] and [focusNode], and this widget then **does not dispose them**:
  /// it disposes only what it created.
  const AppSearchField({
    required this.onChanged,
    super.key,
    this.hint = 'Search',
    this.enabled = true,
    this.controller,
    this.focusNode,
    this.onSubmitted,
    this.autofocus = false,
  });

  /// Called on every keystroke with the raw field text, and with `''` on clear.
  final ValueChanged<String> onChanged;

  /// Placeholder shown while the field is empty.
  final String hint;

  /// Whether the field accepts input.
  final bool enabled;

  /// The controller to drive the field with, or `null` for one of its own.
  ///
  /// When supplied, the caller owns its lifecycle - this widget will not dispose
  /// it.
  final TextEditingController? controller;

  /// The focus node to attach, or `null` for one of the field's own.
  ///
  /// Supplied by a caller that has to put the caret back after a selection, a
  /// dialog or a refusal, which is what the counter's keyboard contract needs.
  final FocusNode? focusNode;

  /// Called when the platform submits the field (a mobile search key, a desktop
  /// Enter that the field itself consumes).
  ///
  /// A raw Enter is handled before this reaches the platform - see the counter's
  /// own `onKeyEvent` - so on a keyboard the two are not both fired for one press.
  final ValueChanged<String>? onSubmitted;

  /// Whether the field takes the caret when it is first built.
  final bool autofocus;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    // Only what this state created: an injected controller or node belongs to the
    // caller, and disposing it here would pull the field out from under them.
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  /// Empties the field and reports the cleared value to the caller.
  void _clear() {
    _controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      textInputAction: TextInputAction.search,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search),
        // Rebuilds only the suffix, so typing never rebuilds the field itself.
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, child) {
            if (value.text.isEmpty) {
              return const SizedBox.shrink();
            }
            return IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear search',
              onPressed: widget.enabled ? _clear : null,
            );
          },
        ),
      ),
    );
  }
}
