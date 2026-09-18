/// Unit tests for the PostgREST search helpers.
library;

import 'package:app/core/utils/postgrest_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeSearchTerm', () {
    test('leaves ordinary text alone', () {
      expect(sanitizeSearchTerm('Paracetamol 500mg'), 'Paracetamol 500mg');
      expect(sanitizeSearchTerm('Dolo-650'), 'Dolo-650');
    });

    test('trims and collapses runs of whitespace', () {
      expect(sanitizeSearchTerm('  para   500  '), 'para 500');
    });

    test('removes the characters that would change the query', () {
      // A comma would otherwise split the or=() filter into an extra condition.
      expect(sanitizeSearchTerm('para,cetamol'), 'para cetamol');
      // Parentheses would open a nested condition group.
      expect(sanitizeSearchTerm('a(b)c'), 'a b c');
      // A percent sign would turn user text into a wildcard.
      expect(sanitizeSearchTerm('50%'), '50');
      expect(sanitizeSearchTerm('a*b'), 'a b');
      expect(sanitizeSearchTerm(r'back\slash'), 'back slash');
      expect(sanitizeSearchTerm('say "hi"'), 'say hi');
      expect(sanitizeSearchTerm("it's"), 'it s');
    });

    test('treats an underscore as a separator, per D-014', () {
      // `_` is an SQL single-character wildcard. It carries no extra privilege
      // but D-014 lists it, so it is stripped like the rest - meaning a search
      // for an underscore-containing name becomes a two-word search.
      expect(sanitizeSearchTerm('vitamin_b'), 'vitamin b');
    });

    test('collapses a term made entirely of metacharacters to empty', () {
      expect(sanitizeSearchTerm('%%%,,,()'), '');
    });
  });

  group('buildIlikeOrFilter', () {
    test('builds one condition per column', () {
      expect(
        buildIlikeOrFilter(columns: <String>['name', 'barcode'], term: 'para'),
        'name.ilike.%para%,barcode.ilike.%para%',
      );
    });

    test('returns null when there is nothing to search for', () {
      expect(buildIlikeOrFilter(columns: <String>['name'], term: ''), isNull);
      expect(
        buildIlikeOrFilter(columns: <String>['name'], term: '   '),
        isNull,
      );
      expect(
        buildIlikeOrFilter(columns: <String>['name'], term: ',,,%%'),
        isNull,
      );
    });

    test('returns null when no columns were given', () {
      expect(
        buildIlikeOrFilter(columns: const <String>[], term: 'para'),
        isNull,
      );
    });

    test('a comma in the input cannot become a second condition', () {
      final filter = buildIlikeOrFilter(
        columns: <String>['name'],
        term: 'para,is_active.eq.false',
      );

      expect(filter, isNotNull);
      expect(filter, isNot(contains(',')));
      // Every separator - including the underscore - has become a space, so the
      // whole thing stays one ilike pattern instead of becoming filter syntax.
      expect(filter, 'name.ilike.%para is active.eq.false%');
    });
  });
}
