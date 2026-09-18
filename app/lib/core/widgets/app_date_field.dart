/// Themed date picker field that participates in its enclosing [Form].
library;

import 'package:app/core/utils/formatters.dart';
import 'package:flutter/material.dart';

/// PharmaFlow's standard date field: a tappable field that opens a picker.
///
/// Wrapped in a `FormField` rather than left as a bare `InkWell`, so that a
/// required date is reported by `Form.validate()` alongside the text fields
/// around it. A receipt that is only missing an expiry date should say so at
/// that field, not through a SnackBar raised by the write one layer away.
///
/// The value is always a `DateTime`: the picker returns one, and the field
/// forwards it unchanged.
class AppDateField extends StatelessWidget {
  /// Creates a date field.
  const AppDateField({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
    this.isRequired = false,
    this.hint = 'Choose a date',
    this.prefixIcon = Icons.event_outlined,
    this.firstDate,
    this.lastDate,
    this.enabled = true,
  });

  /// Floating label describing the field; also used in the error message.
  final String label;

  /// The chosen date, or `null` when nothing is selected.
  final DateTime? value;

  /// Called with the chosen date, or `null` when cleared.
  final ValueChanged<DateTime?> onChanged;

  /// Whether a missing value should block the form.
  final bool isRequired;

  /// Placeholder shown while nothing is selected.
  final String hint;

  /// Optional leading icon.
  final IconData? prefixIcon;

  /// Earliest selectable date; defaults to fifteen years back, which covers a
  /// manufacturing date printed on stock that is still in the market.
  final DateTime? firstDate;

  /// Latest selectable date; defaults to thirty years forward, which covers a
  /// long-dated batch's expiry.
  final DateTime? lastDate;

  /// Whether the field accepts input.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = prefixIcon;

    return FormField<DateTime>(
      initialValue: value,
      validator: isRequired
          ? (date) => date == null ? '$label is required' : null
          : null,
      builder: (field) {
        // Read from the field rather than from `value`, so the displayed text
        // and the validated value cannot disagree: `didChange` updates the field
        // immediately, while the parent's new `value` only arrives on the next
        // build.
        final selected = field.value;

        return InkWell(
          onTap: enabled ? () => _pick(context, field) : null,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: icon == null ? null : Icon(icon),
              errorText: field.errorText,
              suffixIcon: selected == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear $label',
                      onPressed: enabled
                          ? () {
                              field.didChange(null);
                              onChanged(null);
                            }
                          : null,
                    ),
            ),
            child: Text(
              selected == null ? hint : Formatters.dateDdMmmYyyy(selected),
              style: selected == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : theme.textTheme.bodyLarge,
            ),
          ),
        );
      },
    );
  }

  /// Opens the picker and reports whatever was chosen.
  Future<void> _pick(
    BuildContext context,
    FormFieldState<DateTime> field,
  ) async {
    final now = DateTime.now();
    final first = firstDate ?? DateTime(now.year - 15);
    final last = lastDate ?? DateTime(now.year + 30);

    // The initial date has to sit inside the window, which a caller's tighter
    // bounds can violate (`showDatePicker` asserts on it otherwise).
    var initial = field.value ?? now;
    if (initial.isBefore(first)) {
      initial = first;
    }
    if (initial.isAfter(last)) {
      initial = last;
    }

    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDate: initial,
    );
    if (picked == null) {
      return;
    }
    field.didChange(picked);
    onChanged(picked);
  }
}
