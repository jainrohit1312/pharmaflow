/// Themed single-select field for enums, filters and foreign keys.
library;

import 'package:flutter/material.dart';

/// PharmaFlow's standard dropdown.
///
/// Callers pass plain values plus a label builder instead of constructing
/// `DropdownMenuItem`s. The field is controlled: rebuilding the parent with a
/// different [value] moves the displayed selection, because the underlying
/// `DropdownButtonFormField` re-syncs whenever its initial value changes.
///
/// [T] may itself be nullable, but a null entry in [values] is never treated as
/// a selection - a null [value] shows [hint] instead. Optional fields therefore
/// use [allowNone], which renders a clear affordance that reports `null` back.
class AppDropdownField<T> extends StatelessWidget {
  /// Creates a themed dropdown.
  const AppDropdownField({
    required this.label,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    super.key,
    this.value,
    this.hint,
    this.prefixIcon,
    this.validator,
    this.enabled = true,
    this.allowNone = false,
  });

  /// Floating label describing the field.
  final String label;

  /// The selectable values, in display order.
  final List<T> values;

  /// Builds the display text for one value.
  final String Function(T value) labelOf;

  /// Called with the new selection, or `null` when cleared.
  final ValueChanged<T?> onChanged;

  /// The selected value, or `null` when nothing is selected.
  final T? value;

  /// Placeholder shown while nothing is selected.
  final String? hint;

  /// Optional leading icon.
  final IconData? prefixIcon;

  /// Form validator; receives `null` when nothing is selected.
  final FormFieldValidator<T?>? validator;

  /// Whether the field accepts input.
  final bool enabled;

  /// Whether to offer a clear button while a value is selected.
  final bool allowNone;

  @override
  Widget build(BuildContext context) {
    final prefix = prefixIcon;
    final canClear = allowNone && value != null;

    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefix == null ? null : Icon(prefix),
        suffixIcon: canClear
            ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear',
                onPressed: enabled ? () => onChanged(null) : null,
              )
            : null,
      ),
      items: <DropdownMenuItem<T>>[
        for (final item in values)
          DropdownMenuItem<T>(value: item, child: Text(labelOf(item))),
      ],
      onChanged: enabled ? onChanged : null,
      validator: validator,
    );
  }
}
