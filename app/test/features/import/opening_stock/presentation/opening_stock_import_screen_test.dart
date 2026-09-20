/// The opening stock import screen, end to end through its own controller.
///
/// The picker, the repository and the saver are the three seams the screen
/// reaches the outside world through, so overriding those three is enough to
/// drive the whole flow: choose a file, read what it is, upload it, commit, and
/// save the audit - with no Supabase client and no file dialog.
///
/// The file is chosen and then *uploaded* as two acts, so the helper below is
/// what most of these tests start with. The ones that are about either act on its
/// own - what the confirmed step shows, what happens while the server is working -
/// drive the steps themselves rather than going through it.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_opening_stock_file_picker.dart';
import '../../../../support/fake_opening_stock_repository.dart';
import '../../../../support/opening_stock_test_app.dart';

/// Chooses the file and uploads it, which is how an import starts.
Future<void> pickAndUpload(WidgetTester tester) async {
  await tester.tap(find.text('Choose the CSV file'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Upload & Preview'));
  await tester.pumpAndSettle();
}

/// A file of [count] ordinary rows, for the tests about how many there are.
String csvOfRows(int count) => openingStockCsv(<String>[
  for (var index = 1; index <= count; index++)
    'Item $index,BATCH$index,2030-03-31,1,1.00,2.00',
]);

void main() {
  testWidgets('offers the file picker before anything is chosen', (
    tester,
  ) async {
    await pumpOpeningStockApp(tester, repository: FakeOpeningStockRepository());

    expect(find.text('Choose the CSV file'), findsOneWidget);
    expect(find.text('Opening stock import'), findsOneWidget);
  });

  testWidgets('shows the chosen file, its size and a count of its rows', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();
    final picker = FakeOpeningStockFilePicker(
      file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
    );

    await pumpOpeningStockApp(tester, repository: repository, picker: picker);

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    // Nothing has been sent: choosing a file is not uploading it.
    expect(repository.previewed, isEmpty);
    expect(find.text('PharmaFlow_Opening_Stock.csv'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
    expect(find.text('Rows detected'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Not sent yet'), findsOneWidget);
    expect(find.text('Upload & Preview'), findsOneWidget);
  });

  testWidgets('says "at least" when the first pass hits its own limit', (
    tester,
  ) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: csvOfRows(150)),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    // 150 rows is more than the first pass reads, so it says so rather than
    // counting only the slice it read.
    expect(find.text('at least 100'), findsOneWidget);
  });

  testWidgets('cancels the chosen file back to the offer', (tester) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Choose the CSV file'), findsOneWidget);
    expect(repository.previewed, isEmpty);
  });

  testWidgets('walks the upload through its three steps while it works', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repository = FakeOpeningStockRepository()..previewGate = gate;

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload & Preview'));
    await tester.pump();

    // The read and the send are over the moment the request exists - the send
    // of a two-row payload has nowhere to be - so the step the screen is waiting
    // on is the server's, and the two behind it are ticked.
    expect(find.text('Reading the file'), findsOneWidget);
    expect(find.text('Sending to the server'), findsOneWidget);
    expect(find.text('Classifying the products'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Working… 0s elapsed'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Working… 4s elapsed'), findsOneWidget);

    // The back button is greyed while the upload is in flight.
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Classifying the products'), findsNothing);
    expect(find.text('Ready to import'), findsOneWidget);
  });

  testWidgets('draws the preview once the server has classified the file', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository(
      previewResult: buildPreview(
        summary: realExportSummary(),
        rows: [buildPreviewRow()],
      ),
    );
    final picker = FakeOpeningStockFilePicker(
      file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
    );

    await pumpOpeningStockApp(tester, repository: repository, picker: picker);
    await pickAndUpload(tester);

    expect(picker.pickCount, 1);
    expect(repository.previewed, hasLength(1));
    expect(repository.previewed.single, hasLength(2));
    expect(find.text('PharmaFlow_Opening_Stock.csv'), findsOneWidget);
    expect(find.text('61360'), findsOneWidget);
    expect(find.text('₹6,04,832.90'), findsOneWidget);
    expect(find.text('138'), findsOneWidget);
    expect(find.text('145'), findsOneWidget);
    expect(find.text('53'), findsOneWidget);
  });

  testWidgets('labels the button with the number of rows it will write', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository(
      previewResult: buildPreview(
        summary: realExportSummary(),
        rows: [buildPreviewRow()],
      ),
    );

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    expect(find.text('Import 314 rows'), findsOneWidget);
    expect(find.text('Ready to import'), findsOneWidget);
  });

  testWidgets('asks once and then commits the previewed rows', (tester) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();

    // Nothing is written until the confirmation is answered.
    expect(repository.committed, isEmpty);
    expect(find.text('Import now?'), findsOneWidget);

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(repository.committed, hasLength(1));
    expect(repository.committed.single, hasLength(2));
    expect(
      repository.committedFileNames.single,
      'PharmaFlow_Opening_Stock.csv',
    );
    expect(find.text('Import finished'), findsOneWidget);
  });

  testWidgets('shows what the commit wrote, and links onward', (tester) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Products created'), findsOneWidget);
    expect(find.text('Batches'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('₹100.00'), findsOneWidget);

    await tester.tap(find.text('Go to inventory'));
    await tester.pumpAndSettle();

    expect(find.text(inventoryStubText), findsOneWidget);
  });

  testWidgets('saves the audit CSV the database holds, not the preview', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();
    final saver = FakeOpeningStockCsvSaver();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      saver: saver,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download the audit CSV'));
    await tester.pumpAndSettle();

    // Reading the job back is what the audit is rendered from, so the trail can
    // never show more than the database wrote.
    expect(repository.jobsRead, <String>['job-1']);
    expect(saver.savedFileNames.single, 'opening-stock-audit-2026-09-20.csv');
    expect(
      saver.savedContents.single,
      contains('row_number,item_name,batch_no'),
    );
    expect(saver.savedContents.single, contains('Dolo 650mg'));
  });

  testWidgets('lists the rows that cannot be imported, by line', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository(
      previewResult: buildPreview(
        summary: buildSummary(
          rowCount: 3,
          errorRowCount: 1,
          ambiguousRowCount: 1,
        ),
        rows: [
          buildPreviewRow(),
          buildPreviewRow(
            rowNumber: 2,
            itemName: 'ZZCOL TAB',
            outcome: OpeningStockOutcome.ambiguous,
            productNames: <String>['ZZCOL TAB', 'zzcol tab,'],
            errorNote:
                '2 catalogue products share this name - resolve it in the '
                'catalogue first',
          ),
          buildPreviewRow(
            rowNumber: 3,
            itemName: 'ZZBAD TAB',
            qty: null,
            outcome: OpeningStockOutcome.error,
            errorNote: 'qty "abc" is not a whole number',
          ),
        ],
      ),
    );

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    expect(find.text('Rows that cannot be imported'), findsOneWidget);
    expect(find.text('Row 2'), findsOneWidget);
    expect(find.text('Row 3'), findsOneWidget);
    expect(find.text('qty "abc" is not a whole number'), findsOneWidget);
    expect(
      find.text('Catalogue matches: ZZCOL TAB, zzcol tab,'),
      findsOneWidget,
    );
    expect(find.text('Cannot be imported yet'), findsOneWidget);

    final write = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Nothing to import'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(write.onPressed, isNull);
    expect(repository.committed, isEmpty);
  });

  testWidgets('says so when the same content is already in the database', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository(
      previewResult: buildPreview(
        summary: realExportSummary(),
        rows: [buildPreviewRow()],
        existingJob: ExistingImportJob(
          jobId: 'job-1',
          rowCount: 314,
          status: 'committed',
          committedAt: DateTime(2026, 9, 20),
        ),
      ),
    );

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    expect(
      find.textContaining('already been imported on 20 Sep 2026'),
      findsOneWidget,
    );
    expect(find.text('Nothing to import'), findsOneWidget);
  });

  testWidgets('a file it cannot read is named, and never reaches the server', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: 'name,batch,qty\nA,B,1\n'),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    // Refused on the way in, with the step named: the wrong header is visible in
    // the first records, so waiting for an upload would be waiting for nothing.
    expect(find.text('The file could not be read'), findsOneWidget);
    expect(find.textContaining('expected columns'), findsOneWidget);
    expect(repository.previewed, isEmpty);
  });

  testWidgets('refuses a file that arrived with no content at all', (
    tester,
  ) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: ''),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    // Not a silent no-op and not an import of nothing: an empty read is a
    // failure with a sentence.
    expect(find.text('The file could not be read'), findsOneWidget);
    expect(find.textContaining('empty'), findsOneWidget);
  });

  testWidgets('names the row when the fault is past the first pass', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();
    final broken = <String>[
      for (var index = 1; index <= 149; index++)
        'Item $index,BATCH$index,2030-03-31,1,1.00,2.00',
      'Broken,BATCH150,2030-03-31,1,1.00',
    ];

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(broken)),
      ),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    // The first pass read only the start of the file, so this fault is the full
    // read's to find - and it names the line it is on.
    expect(find.text('at least 100'), findsOneWidget);

    await tester.tap(find.text('Upload & Preview'));
    await tester.pumpAndSettle();

    expect(find.text('The file could not be read'), findsOneWidget);
    expect(find.text('Row 150'), findsOneWidget);
    expect(find.textContaining('5 columns'), findsOneWidget);
    expect(repository.previewed, isEmpty);
  });

  testWidgets('a server refusal names the step and can be tried again', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository()
      ..previewErrorToThrow = const ServerException(
        message: 'That file could not be checked.',
      );
    final picker = FakeOpeningStockFilePicker(
      file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
    );

    await pumpOpeningStockApp(tester, repository: repository, picker: picker);
    await pickAndUpload(tester);

    expect(find.text('The server could not check the file'), findsOneWidget);
    expect(find.text('That file could not be checked.'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);

    // Trying again does not ask for the file a second time: it is still in hand.
    repository.previewErrorToThrow = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(picker.pickCount, 1);
    expect(find.text('Ready to import'), findsOneWidget);
  });

  testWidgets('a request that timed out says the file was never sent', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository()
      ..previewErrorToThrow = const NetworkException(
        message:
            'The server did not answer in time, so the file has not been '
            'checked. Check the connection and try again.',
        code: 'net/timeout',
      );

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    // Not "the server refused": nothing came back at all, and the advice differs.
    expect(find.text('The file could not be sent'), findsOneWidget);
    expect(find.textContaining('did not answer in time'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a refusal from the commit names the row and can be retried', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository()
      ..commitErrorToThrow = const ValidationException(
        message:
            'the opening stock import was refused - 1 row(s) cannot be '
            'imported:\nrow 3: batch DOBS4434 already exists for this product',
      );

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    // The sentence the server wrote for the owner, row number and all.
    expect(find.text('The import could not be written'), findsOneWidget);
    expect(find.textContaining('row 3: batch DOBS4434'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a cancelled pick leaves the screen where it was', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(),
    );

    await tester.tap(find.text('Choose the CSV file'));
    await tester.pumpAndSettle();

    expect(find.text('Choose the CSV file'), findsOneWidget);
    expect(repository.previewed, isEmpty);
  });

  testWidgets('going back to file selection drops the preview', (tester) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    expect(find.text('Import 2 rows'), findsOneWidget);

    await tester.tap(find.text('Back to file selection'));
    await tester.pumpAndSettle();

    expect(find.text('Choose the CSV file'), findsOneWidget);
  });

  testWidgets('parsed rows carry the file name into the commit', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();
    final picker = FakeOpeningStockFilePicker(
      file: pickedOpeningStockCsv(
        fileName: 'renamed-export.csv',
        content: openingStockCsv(twoRowCsvBody),
      ),
    );

    await pumpOpeningStockApp(tester, repository: repository, picker: picker);
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(repository.committedFileNames.single, 'renamed-export.csv');
  });

  testWidgets('the rows sent are the rows that were previewed', (tester) async {
    final repository = FakeOpeningStockRepository();

    await pumpOpeningStockApp(
      tester,
      repository: repository,
      picker: FakeOpeningStockFilePicker(
        file: pickedOpeningStockCsv(content: openingStockCsv(twoRowCsvBody)),
      ),
    );
    await pickAndUpload(tester);

    await tester.tap(find.text('Import 2 rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    final previewed = repository.previewed.single;
    final committed = repository.committed.single;
    expect(committed, hasLength(previewed.length));
    expect(committed.first.itemName, 'Dolo 650mg');
    expect(committed.last.batchNo, isEmpty);
  });

  testWidgets('a row of the file with a leading-zero batch survives the trip', (
    tester,
  ) async {
    final repository = FakeOpeningStockRepository();
    final picker = FakeOpeningStockFilePicker(
      file: pickedOpeningStockCsv(
        content: openingStockCsv(<String>[
          'ZIFI 200MG,0126E038,2027-10-31,136,8.16,10.51',
        ]),
      ),
    );

    await pumpOpeningStockApp(tester, repository: repository, picker: picker);
    await pickAndUpload(tester);

    final sent = repository.previewed.single;
    expect(sent.single.batchNo, '0126E038');
    expect(sent.single.qty, '136');
    expect(sent.single.mrp, '10.51');
  });

  testWidgets('the route is the one the settings entry points at', (
    tester,
  ) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      initialLocation: Routes.settings,
    );

    expect(find.text('Opening stock import'), findsOneWidget);

    await tester.tap(find.text('Opening stock import'));
    await tester.pumpAndSettle();

    expect(find.text('Choose the CSV file'), findsOneWidget);
  });
}
