/// The opening-stock CSV reader.
///
/// The parser's job is deliberately narrow - records, quoting, encodings, blank
/// lines - because the server owns every rule about what a row *means*. These
/// tests are therefore about the shape of the file, and about the two values the
/// file's text must survive intact: leading zeros and internal spaces.
library;

import 'package:app/features/import/opening_stock/data/opening_stock_csv.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real header, spelled the way the owner's export has it.
const String header = 'item_name,batch_no,expiry_date,qty,purchase_rate,mrp';

void main() {
  group('a well-formed file', () {
    test('reads each row into its six columns, as text', () {
      final rows = parseOpeningStockCsv(
        <String>[
          header,
          'Dolo 650mg,DOBS4434,2030-03-31,1292,1.38,2.15',
          'Gastroease RD,GH6F27,2028-05-31,9726,1.20,11.00',
        ].join('\n'),
      );

      expect(rows, hasLength(2));
      expect(rows.first.itemName, 'Dolo 650mg');
      expect(rows.first.batchNo, 'DOBS4434');
      expect(rows.first.expiryDate, '2030-03-31');
      expect(rows.first.qty, '1292');
      expect(rows.first.purchaseRate, '1.38');
      expect(rows.first.mrp, '2.15');
      expect(rows.last.itemName, 'Gastroease RD');
    });

    test('numbers a row by its position among the data rows', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'A,B,,1,1.00,2.00', 'C,D,,1,1.00,2.00'].join('\n'),
      );

      expect(rows.map((row) => row.rowNumber), <int>[1, 2]);
    });

    test('sends every value as the RPC expects to read it', () {
      final rows = parseOpeningStockCsv(
        <String>[
          header,
          'Dolo 650mg,DOBS4434,2030-03-31,1292,1.38,2.15',
        ].join('\n'),
      );

      expect(rows.single.toJson(), <String, dynamic>{
        'item_name': 'Dolo 650mg',
        'batch_no': 'DOBS4434',
        'expiry_date': '2030-03-31',
        'qty': '1292',
        'purchase_rate': '1.38',
        'mrp': '2.15',
      });
    });
  });

  group('the text the file printed', () {
    test('keeps the leading zeros in a batch number', () {
      final rows = parseOpeningStockCsv(
        <String>[
          header,
          'ZIFI 200MG,0126E038,2027-10-31,136,8.16,10.51',
        ].join('\n'),
      );

      expect(rows.single.batchNo, '0126E038');
    });

    test('keeps a dummy batch number of "1" as it is', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'PROLINE NO 1,1,,15,140.00,499.00'].join('\n'),
      );

      expect(rows.single.batchNo, '1');
    });

    test('keeps the spaces inside an item name and trims the edges', () {
      const padded = '  99 F 100ML  ';

      final rows = parseOpeningStockCsv(
        <String>[
          header,
          '$padded,265I001,2027-08-31,14,27.00,375.00',
        ].join('\n'),
      );

      expect(rows.single.itemName, '99 F 100ML');
    });

    test('keeps a run of internal spaces exactly as it was printed', () {
      const spaced = 'Eupen 1gm                     INJ';

      final rows = parseOpeningStockCsv(
        <String>[
          header,
          '$spaced,289181,2028-03-31,14,120.00,1017.65',
        ].join('\n'),
      );

      expect(rows.single.itemName, spaced);
      expect(rows.single.itemName.contains('  '), isTrue);
    });

    test('reads an empty field as empty rather than as a missing column', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'AB Gel,,,0,80.00,104.00'].join('\n'),
      );

      expect(rows.single.batchNo, isEmpty);
      expect(rows.single.expiryDate, isEmpty);
      expect(rows.single.qty, '0');
    });

    test('coerces nothing: a zero rate and a zero quantity are text', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'PANTOP,,,0,0.00,57.48'].join('\n'),
      );

      expect(rows.single.qty, '0');
      expect(rows.single.purchaseRate, '0.00');
    });
  });

  group('the file itself', () {
    test('tolerates a byte-order mark and CRLF line endings', () {
      final rows = parseOpeningStockCsv(
        '\uFEFF$header\r\nDolo 650mg,DOBS4434,2030-03-31,1292,1.38,2.15\r\n',
      );

      expect(rows, hasLength(1));
      expect(rows.single.itemName, 'Dolo 650mg');
    });

    test('does not read a trailing newline as a row', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'A,B,,1,1.00,2.00', ''].join('\n'),
      );

      expect(rows, hasLength(1));
    });

    test('skips a blank line in the middle', () {
      final rows = parseOpeningStockCsv(
        <String>[header, 'A,B,,1,1.00,2.00', '', 'C,D,,1,1.00,2.00'].join('\n'),
      );

      expect(rows, hasLength(2));
      expect(rows.last.itemName, 'C');
    });

    test('reads a quoted item name containing a comma as one value', () {
      final rows = parseOpeningStockCsv(
        <String>[
          header,
          '"ACILOC, INJ",AB26058,2029-06-30,781,5.25,7.40',
        ].join('\n'),
      );

      expect(rows.single.itemName, 'ACILOC, INJ');
    });

    test('reads a doubled quote inside a quoted name as one quote', () {
      final rows = parseOpeningStockCsv(
        <String>[
          header,
          '"ACILOC ""INJ""",AB26058,2029-06-30,781,5.25,7.40',
        ].join('\n'),
      );

      expect(rows.single.itemName, 'ACILOC "INJ"');
    });
  });

  group('a file that cannot be read', () {
    test('is refused when it is empty', () {
      expect(
        () => parseOpeningStockCsv(''),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('is refused when the header is not the expected one', () {
      expect(
        () => parseOpeningStockCsv('name,batch,qty\nA,B,1\n'),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            contains('item_name,batch_no,expiry_date,qty,purchase_rate,mrp'),
          ),
        ),
      );
    });

    test('is refused when two expected columns are swapped', () {
      expect(
        () => parseOpeningStockCsv(
          'item_name,qty,batch_no,expiry_date,'
          'purchase_rate,mrp\nA,1,B,,1.00\n',
        ),
        throwsA(isA<OpeningStockCsvException>()),
      );
    });

    test('is refused when a row has the wrong number of columns', () {
      expect(
        () => parseOpeningStockCsv(
          <String>[header, 'A,B,,1,1.00,2.00', 'C,D,,1'].join('\n'),
        ),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Row 2'), contains('4 columns')),
          ),
        ),
      );
    });

    test('is refused when it has a header and no rows', () {
      expect(
        () => parseOpeningStockCsv('$header\n'),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            contains('header but no rows'),
          ),
        ),
      );
    });

    test('is refused when a quote is never closed', () {
      expect(
        () => parseOpeningStockCsv('$header\n"A,B,,1,1.00,2.00\n'),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            contains('closing quote'),
          ),
        ),
      );
    });
  });

  test('the header is compared case-insensitively but in order', () {
    final rows = parseOpeningStockCsv(
      <String>[
        'ITEM_NAME,batch_no,Expiry_Date,QTY,purchase_rate,MRP',
        'A,B,,1,1.00,2.00',
      ].join('\n'),
    );

    expect(rows, hasLength(1));
    expect(rows.single.itemName, 'A');
  });

  group('the first pass over a file', () {
    test('counts a short file exactly', () {
      final estimate = estimateOpeningStockRows(_csvOf(2));

      expect(estimate.rowCount, 2);
      expect(estimate.truncated, isFalse);
    });

    test('counts a file of exactly the limit without calling it "at least"', () {
      final estimate = estimateOpeningStockRows(
        _csvOf(openingStockEstimateRecordLimit),
      );

      // The boundary that makes the plain count usable: a file of a hundred rows
      // is a hundred rows, not "at least 100".
      expect(estimate.rowCount, 100);
      expect(estimate.truncated, isFalse);
    });

    test('stops at the limit and says the file holds more', () {
      final estimate = estimateOpeningStockRows(
        _csvOf(openingStockEstimateRecordLimit + 1),
      );

      expect(estimate.rowCount, 100);
      expect(estimate.truncated, isTrue);
    });

    test('reads its own slice and no more of a long file', () {
      final broken = <String>[
        _csvOf(200),
        'Broken,BATCH,2030-03-31,1,1.00',
      ].join('\n');

      // The fault is past the slice, so the first pass never sees it...
      expect(estimateOpeningStockRows(broken).rowCount, 100);
      // ...and the full read, which does, refuses the file on it.
      expect(
        () => parseOpeningStockCsv(broken),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.rowNumber,
            'rowNumber',
            201,
          ),
        ),
      );
    });

    test('refuses a wrong header before anything is uploaded', () {
      expect(
        () => estimateOpeningStockRows('name,batch,qty\nA,B,1\n'),
        throwsA(
          isA<OpeningStockCsvException>().having(
            (error) => error.message,
            'message',
            contains('expected columns'),
          ),
        ),
      );
    });

    test('refuses an empty file', () {
      expect(
        () => estimateOpeningStockRows(''),
        throwsA(isA<OpeningStockCsvException>()),
      );
    });

    test('names the row it read when one of them has the wrong columns', () {
      final broken = <String>[
        header,
        'A,B,,1,1.00,2.00',
        'C,D,,1,1.00,2.00',
        'E,D,,1',
      ].join('\n');

      expect(
        () => estimateOpeningStockRows(broken),
        throwsA(
          isA<OpeningStockCsvException>()
              .having((error) => error.rowNumber, 'rowNumber', 3)
              .having((error) => error.message, 'message', contains('Row 3')),
        ),
      );
    });
  });
}

/// [count] ordinary data rows under the real header.
String _csvOf(int count) => <String>[
  header,
  for (var index = 1; index <= count; index++)
    'Item $index,BATCH$index,2030-03-31,1,1.00,2.00',
].join('\n');
