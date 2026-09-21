/// Widget tests for what a gated product write looks like on screen.
///
/// Phase 6.5c chunk 5 put the product master behind the owner's approval for anybody but the
/// owner: `save_product()` raises one request and **writes nothing**, so there is no product to
/// open and no edit to see. These tests drive that path, because the failing behaviour it prevents
/// is the quiet one - a form that navigated to a product it had not created, or a detail screen
/// that refreshed after a deactivation that never happened, would both show the write as done.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_products_repository.dart';
import '../../support/products_test_app.dart';

/// What every gated product write says, verbatim.
const String _sentForApproval =
    'Sent to the owner. Nothing has been recorded until he approves it.';

void main() {
  testWidgets('a staff create says it went to the owner, and opens nothing', (
    tester,
  ) async {
    final repository = FakeProductsRepository(
      products: <Product>[],
      isOwner: false,
    );
    await pumpProductsApp(
      tester,
      repository: repository,
      initialLocation: Routes.productForm,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Product name'),
      'Azithromycin 500',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create product'));
    await tester.pumpAndSettle();

    expect(
      find.text(_sentForApproval),
      findsOneWidget,
      reason: 'nothing was written, so a silence would read as a save',
    );
    expect(
      repository.stagedSubmissions,
      1,
      reason: 'the product was asked for rather than created',
    );
    expect(
      repository.writtenDrafts,
      hasLength(1),
      reason: 'the form still built the document it asked about',
    );
    expect(
      find.byTooltip('Edit product'),
      findsNothing,
      reason: 'there is no product detail to be on: it does not exist',
    );
  });

  testWidgets('the owner covers for a staff request by writing it himself', (
    tester,
  ) async {
    // The same form, the same draft, with the owner signed in: the write lands and the product's
    // detail opens. This is the pair the outcome exists to tell apart - no role check on a screen,
    // just what the server answered.
    final repository = FakeProductsRepository(products: <Product>[]);
    await pumpProductsApp(
      tester,
      repository: repository,
      initialLocation: Routes.productForm,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Product name'),
      'Azithromycin 500',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create product'));
    await tester.pumpAndSettle();

    expect(repository.stagedSubmissions, 0);
    expect(
      find.byTooltip('Edit product'),
      findsOneWidget,
      reason:
          'the owner is not gated, so the product exists and its detail opened',
    );
  });

  testWidgets('a staff deactivation leaves the product active and says so', (
    tester,
  ) async {
    final product = buildProduct('Dolo 650');
    final repository = FakeProductsRepository(
      products: <Product>[product],
      isOwner: false,
    );
    await pumpProductsApp(
      tester,
      repository: repository,
      initialLocation: Routes.productDetail(product.id),
    );

    await tester.tap(find.byTooltip('Deactivate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect(
      find.text(_sentForApproval),
      findsOneWidget,
      reason: 'the product is still active, so the toggle moved nothing',
    );
    expect(
      find.text('Active'),
      findsOneWidget,
      reason: 'and the detail still says so, because it was not re-read',
    );
    expect(repository.lastActiveAsk, isFalse);
    expect(repository.stagedSubmissions, 1);
  });
}
