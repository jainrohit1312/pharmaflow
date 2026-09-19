/// Widget tests for the OCR screen: the pick, the verify form, the retry and the
/// save.
///
/// The scanner and the picker are fakes, but the *rules* they are held to are the
/// real ones — `FakePurchaseOcrRepository` runs `validatePick` and builds the real
/// path shape, and the save goes through the real `PurchaseFormController` over
/// the purchase fake, so a screen that skipped a check the write enforces fails
/// here rather than in front of a user.
library;

import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/presentation/widgets/product_picker_field.dart';
import 'package:app/features/purchase_ocr/presentation/purchase_ocr_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_bill_picker.dart';
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
}
