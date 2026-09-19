/// Widget tests for the OCR screen: the pick, the verify form, the retry and the
/// save.
///
/// The scanner and the picker are fakes, but the *rules* they are held to are the
/// real ones — `FakePurchaseOcrRepository` runs `validatePick` and builds the real
/// path shape, and the save goes through the real `PurchaseFormController` over
/// the purchase fake, so a screen that skipped a check the write enforces fails
/// here rather than in front of a user.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_match.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/presentation/widgets/product_picker_field.dart';
import 'package:app/features/purchase_ocr/presentation/purchase_ocr_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_bill_picker.dart';
import '../../../support/fake_match_service.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_purchase_ocr_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_ocr_test_app.dart';

/// Picks the gallery file, the way the screen's own button does.
Future<void> chooseAFile(WidgetTester tester) async {
  await tester.tap(find.text('Choose a file'));
  await tester.pumpAndSettle();
}

/// Chooses [name] in the supplier dropdown, as the manual form's test does.
Future<void> chooseSupplier(WidgetTester tester, String name) async {
  await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Picks the product [name] on the first line.
///
/// The field shows either the picker's hint or the name the reader saw, so the
/// tap targets the widget rather than its text — and the dialog lists the
/// catalogue as soon as it opens, no search term needed.
Future<void> chooseProduct(WidgetTester tester, String name) async {
  await tapVisible(tester, find.byType(ProductPickerField).first);
  await tapVisible(tester, find.text(name));
}

/// A bill with [names] printed on it, one line each, ready to be received.
OcrPurchaseBill billOfLines(List<String> names) => buildOcrBill(
  lines: <OcrLine>[
    for (final name in names)
      OcrLine(
        rawName: name,
        qty: 10,
        rate: 100,
        mrp: 150,
        gstPercent: 12,
        batchNo: 'B-1',
        expiryDate: DateTime(2027, 6, 30),
      ),
  ],
);

/// Taps [finder] without waiting for the tree to settle.
///
/// The in-flight note carries a spinner, and a spinner never settles - so a test
/// that has to act *while the matcher is out* cannot use `pumpAndSettle` to get
/// there.
Future<void> tapWhileBusy(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Chooses [name] in the supplier dropdown, for the same reason: the dropdown's
/// own animation is pumped through by hand rather than awaited.
Future<void> chooseSupplierWhileBusy(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(name).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Picks the product [name] on the first line, for the same reason again.
///
/// This is what a human does while the matcher is still out: the search dialog
/// works whether or not the catalogue has answered, which is what keeps a bill
/// saveable during the call.
Future<void> chooseProductWhileBusy(WidgetTester tester, String name) async {
  await tester.tap(find.byType(ProductPickerField).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(name).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('offers both ways to choose a bill, and says what it needs', (
    tester,
  ) async {
    await pumpPurchaseOcrApp(tester, scanner: FakePurchaseOcrRepository());

    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Choose a file'), findsOneWidget);
    expect(find.textContaining('filling the frame'), findsOneWidget);
    expect(find.textContaining('10 MB'), findsOneWidget);
  });

  testWidgets('reads a picked bill into a form that can be corrected', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    await pumpPurchaseOcrApp(tester, scanner: scanner);

    await chooseAFile(tester);

    expect(scanner.uploads, 1);
    expect(
      scanner.lastMimeType,
      'image/jpeg',
      reason: 'the picker reported it',
    );

    // What was read, beside the bill itself.
    expect(find.text('What the reader saw'), findsOneWidget);
    expect(find.text('ARIHANT DISTRIBUTORS'), findsWidgets);
    expect(find.text('Invoice INV-2026-0042'), findsOneWidget);

    // The verify form, pre-filled from the parse.
    expect(find.text('The bill'), findsOneWidget);
    expect(find.text('Invoice number'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'INV-2026-0042'), findsOneWidget);
    expect(find.text('Lines read from the bill'), findsOneWidget);
    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('Save as a draft'), findsOneWidget);
  });

  testWidgets(
    'shows what the reader was unsure about, and that it stopped early',
    (tester) async {
      final scanner = FakePurchaseOcrRepository(
        bill: buildOcrBill(
          meta: const OcrMeta(
            warnings: <String>['Line 2: quantity 2.5 was rounded to 3.'],
            finishReason: 'MAX_TOKENS',
          ),
        ),
      );
      await pumpPurchaseOcrApp(tester, scanner: scanner);

      await chooseAFile(tester);

      expect(
        find.text('Line 2: quantity 2.5 was rounded to 3.'),
        findsOneWidget,
      );
      expect(find.textContaining('stopped before the end'), findsOneWidget);
    },
  );

  testWidgets('says it is retrying while a busy reader is given its second go', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    scanner.parseFailures.addAll(<Exception?>[busyReaderFailure(), null]);
    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      // Long enough to be seen: the retry is what is under test, so the test has
      // to stand inside it rather than after it.
      retryDelay: const Duration(seconds: 2),
    );

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('The bill reader is busy — retrying…'),
      findsOneWidget,
      reason:
          'a wait with no words is a wait a user interrupts by tapping again',
    );

    await tester.pumpAndSettle();

    expect(scanner.parses, 2, reason: 'one attempt, one retry');
    expect(scanner.uploads, 1);
    expect(find.text('Save as a draft'), findsOneWidget);
  });

  testWidgets('offers another go when the reader was busy twice', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    scanner.parseFailures.add(busyReaderFailure());
    await pumpPurchaseOcrApp(tester, scanner: scanner);

    await chooseAFile(tester);

    expect(find.text('That bill could not be read'), findsOneWidget);
    expect(find.text('Read it again'), findsOneWidget);
    expect(
      find.textContaining('worth trying again'),
      findsOneWidget,
      reason:
          'a busy reader is not an unreadable bill, and must not read as one',
    );
    expect(
      scanner.parses,
      2,
      reason: 'the automatic retry is the limit, not a loop',
    );
  });

  testWidgets('turns away a file the reader cannot open, before any upload', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final picker = FakeBillPicker(
      bill: pickedUntyped(fileName: 'IMG_0044.HEIC'),
    );
    await pumpPurchaseOcrApp(tester, scanner: scanner, picker: picker);

    await chooseAFile(tester);

    expect(find.text('That bill did not upload'), findsOneWidget);
    expect(find.textContaining('no type'), findsOneWidget);
    expect(
      scanner.uploads,
      0,
      reason: 'nothing to upload, and nothing to read',
    );
  });

  testWidgets('saves a draft through the purchase controller and opens it', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
    final products = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      purchases: purchases,
      suppliers: <Supplier>[
        // The builder's defaults are `id: 'sup-1'` and `name: 'Arihant
        // Distributors'`, which is what the assertions below name.
        buildSupplier(),
      ],
      products: products,
    );

    await chooseAFile(tester);
    await chooseSupplier(tester, 'Arihant Distributors');
    await chooseProduct(tester, 'Dolo 650');
    await tapVisible(tester, find.text('Save as a draft'));

    expect(purchases.lastHeader?.supplierId, 'sup-1');
    expect(purchases.lastHeader?.invoiceNo, 'INV-2026-0042');
    expect(purchases.lastLines, hasLength(1));
    expect(purchases.lastLines!.single.productId, 'id-Dolo 650');
    expect(purchases.lastLines!.single.qty, 10);
    expect(purchases.lastLines!.single.freeQty, 1);
    expect(purchases.lastLines!.single.batchNo, 'D650-A21');
    expect(purchases.lastLines!.single.expiryDate, DateTime(2027, 6, 30));

    // The screen hands the user to the document it wrote, where the receipt is
    // one tap away — the same place the manual form sends them.
    expect(find.text('Next step'), findsOneWidget);
    expect(find.byType(PurchaseOcrScreen), findsNothing);
  });

  testWidgets(
    'asks the catalogue once for the whole bill, when the human names '
    'the supplier',
    (tester) async {
      final scanner = FakePurchaseOcrRepository(
        bill: billOfLines(<String>['Dolo 650 Tab 15s', 'Cetzine 10mg']),
      );
      final matcher = FakeMatchService()
        ..candidatesByLine = <List<MatchCandidate>>[
          <MatchCandidate>[buildCandidate('Dolo 650')],
          const <MatchCandidate>[],
        ];
      await pumpPurchaseOcrApp(
        tester,
        scanner: scanner,
        matcher: matcher,
        suppliers: <Supplier>[buildSupplier()],
      );

      await chooseAFile(tester);

      expect(find.text('Line 2'), findsOneWidget);
      expect(
        matcher.matchCalls,
        isEmpty,
        reason:
            'the alias leg is scoped by the supplier, and the supplier is a '
            'human choice the matcher cannot make',
      );
      expect(
        find.textContaining('Choose the supplier and these lines'),
        findsOneWidget,
        reason: 'nothing happening needs a sentence, or it looks broken',
      );

      await chooseSupplier(tester, 'Arihant Distributors');

      expect(
        matcher.matchCalls,
        hasLength(1),
        reason: 'twenty lines are one round trip and one embedding request',
      );
      expect(matcher.matchCalls.single, hasLength(2));
      expect(matcher.matchCalls.single.first.rawName, 'Dolo 650 Tab 15s');
      expect(
        matcher.matchCalls.single.first.supplierId,
        'sup-1',
        reason: 'what scopes a learned alias',
      );
      expect(matcher.matchCalls.single.last.rawName, 'Cetzine 10mg');
    },
  );

  testWidgets(
    'offers a candidate for a line, and fills it only when accepted',
    (tester) async {
      final scanner = FakePurchaseOcrRepository();
      final matcher = FakeMatchService()
        ..candidatesByLine = <List<MatchCandidate>>[
          <MatchCandidate>[
            buildCandidate(
              'Dolo 650',
              reason: MatchReason.alias,
              score: 1,
              aliasName: 'DOLO-650 TAB',
            ),
          ],
        ];
      final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
      final products = FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650')],
      );

      await pumpPurchaseOcrApp(
        tester,
        scanner: scanner,
        matcher: matcher,
        purchases: purchases,
        products: products,
        suppliers: <Supplier>[buildSupplier()],
      );

      await chooseAFile(tester);
      await chooseSupplier(tester, 'Arihant Distributors');

      expect(find.text('Also called DOLO-650 TAB'), findsOneWidget);

      await tapVisible(tester, find.text('Also called DOLO-650 TAB'));

      expect(
        find.text('Also called DOLO-650 TAB'),
        findsNothing,
        reason:
            'a line that has a product does not need advice about which one',
      );
      expect(
        find.widgetWithText(InputDecorator, 'Dolo 650'),
        findsOneWidget,
        reason: 'the catalogue name is what the field shows once it is chosen',
      );

      await tapVisible(tester, find.text('Save as a draft'));

      expect(purchases.lastLines!.single.productId, 'id-Dolo 650');
    },
  );

  testWidgets('saves a bill while the catalogue is still being searched', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final matcher = FakeMatchService()..gate = Completer<void>();
    final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
    final products = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      purchases: purchases,
      products: products,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    await chooseSupplierWhileBusy(tester, 'Arihant Distributors');

    expect(find.textContaining('Looking these lines up'), findsOneWidget);
    expect(matcher.matchCalls, hasLength(1), reason: 'the answer is still out');

    // A human picks the products while the catalogue is still thinking — the
    // search dialog does not depend on the matcher — and then saves.
    await chooseProductWhileBusy(tester, 'Dolo 650');
    await tapWhileBusy(tester, find.text('Save as a draft'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      purchases.lastLines,
      isNotNull,
      reason: 'the draft is written with the matcher still out',
    );
    expect(
      matcher.gate!.isCompleted,
      isFalse,
      reason: 'the save did not wait for an answer it does not need',
    );
    expect(purchases.lastHeader?.supplierId, 'sup-1');
    expect(purchases.lastLines!.single.productId, 'id-Dolo 650');
    expect(purchases.lastLines!.single.qty, 10);

    matcher.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Next step'), findsOneWidget);
  });

  testWidgets('says so when the catalogue cannot be searched, and stays usable', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final matcher = FakeMatchService()
      ..matchFailures.add(unreachableMatcherFailure());
    final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
    final products = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      purchases: purchases,
      products: products,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    await chooseSupplier(tester, 'Arihant Distributors');

    expect(find.textContaining('could not be searched'), findsOneWidget);
    expect(find.textContaining('Could not reach'), findsOneWidget);
    expect(
      find.textContaining('Nothing else about this bill is affected'),
      findsOneWidget,
      reason: 'no suggestion is not a failure, and must not read like one',
    );

    // The retry is the human's: a second request is spent on purpose or not at all.
    await tapVisible(tester, find.text('Look again'));
    expect(matcher.matchCalls, hasLength(2));

    // And the bill is still a bill: the form was never blocked, so it saves.
    await chooseProduct(tester, 'Dolo 650');
    await tapVisible(tester, find.text('Save as a draft'));
    expect(purchases.lastLines!.single.productId, 'id-Dolo 650');
  });

  testWidgets('shows what the server said it could not do', (tester) async {
    final scanner = FakePurchaseOcrRepository();
    final matcher = FakeMatchService()
      ..meta = const MatchMeta(
        warnings: <String>[
          'The lines could not be embedded (the embedding model was busy), so they were matched by name and alias only.',
        ],
      );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    await chooseSupplier(tester, 'Arihant Distributors');

    expect(
      find.textContaining('could not be embedded'),
      findsOneWidget,
      reason:
          'a narrower answer has to say so, or "no suggestion" reads as "your '
          'catalogue does not have it"',
    );
  });

  testWidgets('records what the human confirmed, once for the bill', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final matcher = FakeMatchService()
      ..candidatesByLine = <List<MatchCandidate>>[
        <MatchCandidate>[buildCandidate('Dolo 650')],
      ];
    final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
    final products = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      purchases: purchases,
      products: products,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    await chooseSupplier(tester, 'Arihant Distributors');
    await tapVisible(tester, find.text('87% similar'));
    await tapVisible(tester, find.text('Save as a draft'));

    expect(matcher.learnCalls, hasLength(1));
    final alias = matcher.learnCalls.single.single;
    expect(
      alias.rawName,
      'Dolo 650 Tab 15s',
      reason:
          'the text the bill printed, not the catalogue name the field now '
          'shows - a catalogue name is not what the next bill will say',
    );
    expect(alias.productId, 'id-Dolo 650');
    expect(alias.supplierId, 'sup-1');
  });

  testWidgets('a learning write that fails does not fail the save', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    final matcher = FakeMatchService()
      ..candidatesByLine = <List<MatchCandidate>>[
        <MatchCandidate>[buildCandidate('Dolo 650')],
      ]
      ..learnFailures.add(
        const ServerException(message: 'Unable to record that.'),
      );
    final purchases = FakePurchasesRepository(purchases: <Purchase>[]);
    final products = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      purchases: purchases,
      products: products,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    await chooseSupplier(tester, 'Arihant Distributors');
    await tapVisible(tester, find.text('Dolo 650'));
    await tapVisible(tester, find.text('Save as a draft'));

    // The document is saved and the user is handed to it: what a failed learning
    // write costs is the *next* bill's head start, and nothing else.
    expect(matcher.learnCalls, hasLength(1));
    expect(purchases.lastLines!.single.productId, 'id-Dolo 650');
    expect(find.text('Next step'), findsOneWidget);
    expect(find.byType(PurchaseOcrScreen), findsNothing);
  });

  testWidgets('a second read replaces the lines rather than the first parse', (
    tester,
  ) async {
    final scanner = FakePurchaseOcrRepository();
    scanner.parseFailures.add(busyReaderFailure());
    final matcher = FakeMatchService();

    await pumpPurchaseOcrApp(
      tester,
      scanner: scanner,
      matcher: matcher,
      suppliers: <Supplier>[buildSupplier()],
    );

    await chooseAFile(tester);
    expect(find.text('That bill could not be read'), findsOneWidget);

    // The reader gets a better look this time, and the second answer is a longer
    // bill. The form seeds its lines once, so this is the case that used to keep
    // showing the first parse.
    scanner.bill = billOfLines(<String>['Dolo 650 Tab 15s', 'Cetzine 10mg']);
    scanner.parseFailures.clear();
    await tapVisible(tester, find.text('Read it again'));

    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('Line 2'), findsOneWidget);
    expect(find.text('Cetzine 10mg'), findsOneWidget);
    expect(
      matcher.matchCalls,
      isEmpty,
      reason: 'the re-read starts an unasked form, like the first read did',
    );
  });
}
