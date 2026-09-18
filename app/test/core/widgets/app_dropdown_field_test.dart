/// Widget tests for [AppDropdownField].
///
/// These cover the two behaviours callers depend on and that are easy to get
/// wrong: the field reports selections through `onChanged`, and a value pushed
/// in from the parent (for example a "clear filters" action) is reflected by
/// the field even though it is a form field.
///
/// Assertions read the field's own value rather than hunting for text:
/// `DropdownButton` keeps every item in the tree inside an `IndexedStack`, so
/// `find.text` cannot tell the selected entry from the others.
library;

import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a dropdown over [values] with [value] selected.
Future<void> _pumpDropdown(
  WidgetTester tester, {
  required List<int> values,
  required int? value,
  required ValueChanged<int?> onChanged,
  bool allowNone = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: AppDropdownField<int>(
        label: 'Minimum',
        values: values,
        labelOf: (item) => 'Level $item',
        value: value,
        allowNone: allowNone,
        onChanged: onChanged,
      ),
    ),
  ),
);

/// The value the form field currently holds.
int? _fieldValue(WidgetTester tester) => tester
    .state<FormFieldState<int>>(find.byType(DropdownButtonFormField<int>))
    .value;

void main() {
  testWidgets('starts on the value it was given', (tester) async {
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: 20,
      onChanged: (_) {},
    );

    expect(_fieldValue(tester), 20);
  });

  testWidgets('reports the newly selected value', (tester) async {
    int? selected = 10;
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: selected,
      onChanged: (next) => selected = next,
    );

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Level 20').last);
    await tester.pumpAndSettle();

    expect(selected, 20);
    expect(_fieldValue(tester), 20);
  });

  testWidgets('offers no clear button unless allowNone is set', (tester) async {
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: 10,
      onChanged: (_) {},
    );

    expect(find.byIcon(Icons.clear), findsNothing);
  });

  testWidgets('clearing reports null', (tester) async {
    int? selected = 10;
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: selected,
      allowNone: true,
      onChanged: (next) => selected = next,
    );

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    expect(selected, isNull);
  });

  testWidgets('follows a value pushed in from the parent', (tester) async {
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: 10,
      onChanged: (_) {},
    );
    expect(_fieldValue(tester), 10);

    // Same widget, new value from the parent: the field has to re-sync instead
    // of holding on to the value it was first built with.
    await _pumpDropdown(
      tester,
      values: const <int>[10, 20],
      value: 20,
      onChanged: (_) {},
    );

    expect(_fieldValue(tester), 20);
  });

  testWidgets('a null value shows the hint', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDropdownField<int>(
            label: 'Supplier',
            hint: 'All suppliers',
            values: const <int>[10, 20],
            labelOf: (item) => 'Level $item',
            allowNone: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('All suppliers'), findsOneWidget);
    expect(_fieldValue(tester), isNull);
  });
}
