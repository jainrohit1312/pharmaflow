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
  const AppSearchField({
    required this.onChanged,
    super.key,
    this.hint = 'Search',
    this.enabled = true,
  });

  /// Called on every keystroke with the raw field text, and with `''` on clear.
  final ValueChanged<String> onChanged;

  /// Placeholder shown while the field is empty.
  final String hint;

  /// Whether the field accepts input.
  final bool enabled;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
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
      enabled: widget.enabled,
      textInputAction: TextInputAction.search,
      onChanged: widget.onChanged,
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
