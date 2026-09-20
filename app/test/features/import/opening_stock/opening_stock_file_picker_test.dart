/// What a file picker hands over, before any of it is parsed.
///
/// These are the two failures that used to have no test at all, because they
/// lived inside a class that needs a browser and a file dialog to reach: a pick
/// that arrives with no bytes in it, and a pick of a file that is not a CSV.
/// Both are refusals with a sentence now, and both are exercised here with
/// nothing but bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the options the picker is called with', () {
    test('are the base ones off the web, where there are none to set', () {
      // The mirror of `opening_stock_picker_options_web_test.dart`, and the half
      // that the ordinary `flutter test` run can make: on the Dart VM the
      // conditional import must take the default file, not the web one. A web
      // build takes the other, which `flutter build web --source-maps` shows by
      // compiling `opening_stock_picker_options_web.dart` and dropping this one.
      expect(openingStockPickerWebOptions().runtimeType, WebOptions);
    });
  });

  group('the bytes a picker hands over', () {
    test('are decoded to the file text the parser reads', () {
      final bytes = Uint8List.fromList(
        utf8.encode('item_name,qty\nDolo 650mg,2\n'),
      );

      expect(decodeOpeningStockBytes(bytes), 'item_name,qty\nDolo 650mg,2\n');
    });

    test('are refused when there are none of them', () {
      // The regression this file exists for. A pick that yields zero bytes used
      // to travel on as an empty string, so the parser answered "that file is
      // empty" - which blames a file that was fine, and, on the web, is what a
      // read that silently failed produces.
      expect(
        () => decodeOpeningStockBytes(Uint8List(0)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('not one byte'),
          ),
        ),
      );
    });

    test('are refused when they are not UTF-8 text', () {
      // 0xFF is not a valid UTF-8 lead byte.
      expect(
        () => decodeOpeningStockBytes(
          Uint8List.fromList(<int>[0xFF, 0xFE, 0x00]),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('not UTF-8'),
          ),
        ),
      );
    });
  });

  group('the name a picker hands over', () {
    test('is accepted as a CSV, whatever case it is written in', () {
      expect(() => requireOpeningStockCsvName('export.csv'), returnsNormally);
      expect(
        () => requireOpeningStockCsvName('PharmaFlow_Opening_Stock.CSV'),
        returnsNormally,
      );
    });

    test('is refused, with the way out, when it is a spreadsheet', () {
      expect(
        () => requireOpeningStockCsvName('stock.xlsx'),
        throwsA(
          isA<ValidationException>()
              .having(
                (error) => error.message,
                'message',
                contains('spreadsheet'),
              )
              .having((error) => error.code, 'code', 'import/not-a-csv'),
        ),
      );
      expect(
        () => requireOpeningStockCsvName('stock.xls'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('is refused as itself when the extension names another format', () {
      expect(
        () => requireOpeningStockCsvName('export.txt'),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('.txt'),
          ),
        ),
      );
    });

    test('is refused for having no extension at all', () {
      expect(
        () => requireOpeningStockCsvName('export'),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('no extension'),
          ),
        ),
      );
    });
  });
}
