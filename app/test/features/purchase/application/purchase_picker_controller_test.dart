/// Unit tests for the purchase picker's search and paging (I-3).
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/application/purchase_picker_controller.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchases_repository.dart';
import '../../../support/fake_suppliers_repository.dart'
    show FakeSuppliersRepository;

/// A container wired to [purchases] and [suppliers], with the picker kept alive.
ProviderContainer _container({
  required FakePurchasesRepository purchases,
  FakeSuppliersRepository? suppliers,
}) {
  final container = ProviderContainer(
    // Inferred, not `<Override>[...]`: the type lives in `riverpod`, which
    // `flutter_riverpod` does not re-export.
    overrides: [
      purchasesRepositoryProvider.overrideWithValue(purchases),
      suppliersRepositoryProvider.overrideWithValue(
        suppliers ?? FakeSuppliersRepository(suppliers: <Supplier>[]),
      ),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  // What the dialog does by watching it: without a listener the provider is
  // auto-disposed the moment a fetch awaits.
  container.listen<AsyncValue<PurchasePickerPage>>(
    purchasePickerControllerProvider,
    (previous, next) {},
    fireImmediately: true,
  );
  return container;
}

/// [count] received invoices, `INV-1` … `INV-<count>`, newest first.
List<Purchase> _received(int count) => <Purchase>[
  for (var index = 1; index <= count; index++)
    buildPurchase(
      id: 'purchase-$index',
      invoiceNo: 'INV-$index',
      status: PurchaseStatus.received,
    ).copyWith(
      invoiceDate: DateTime(2026, 6, 30).subtract(Duration(days: index)),
    ),
];

void main() {
  test('offers received invoices, and only received ones', () async {
    final purchases = FakePurchasesRepository(
      purchases: <Purchase>[
        buildPurchase(id: 'p-draft', invoiceNo: 'DRAFT-1'),
        buildPurchase(id: 'p-received', status: PurchaseStatus.received),
      ],
    );
    final container = _container(purchases: purchases);

    final page = await container.read(purchasePickerControllerProvider.future);

    expect(page.items.map((purchase) => purchase.id), <String>['p-received']);
    expect(
      purchases.lastQuery?.status,
      PurchaseStatus.received,
      reason: 'a draft has no batches, so nothing could be returned against it',
    );
  });

  test('asks for one page, and says whether another exists', () async {
    final purchases = FakePurchasesRepository(purchases: _received(45));
    final container = _container(purchases: purchases);

    final first = await container.read(purchasePickerControllerProvider.future);

    expect(first.items, hasLength(purchasePickerPageSize));
    expect(first.hasMore, isTrue);
    expect(
      purchases.lastLimit,
      purchasePickerPageSize,
      reason:
          'a picker wants a short list; what does not fit is a keystroke away '
          'or one Load more, not a 200-row page',
    );
  });

  test('loads the next page onto the one on screen, then stops', () async {
    final purchases = FakePurchasesRepository(purchases: _received(25));
    final container = _container(purchases: purchases);
    final controller = container.read(
      purchasePickerControllerProvider.notifier,
    );

    await container.read(purchasePickerControllerProvider.future);
    await controller.loadMore();

    var page = container.read(purchasePickerControllerProvider).value!;
    expect(page.items, hasLength(25), reason: '20 then 5, in one list');
    expect(page.hasMore, isFalse, reason: 'a short page is the end');
    expect(
      page.items.map((purchase) => purchase.invoiceNo).toSet(),
      hasLength(25),
      reason: 'no row is fetched twice and none is skipped',
    );

    // And asking again does nothing rather than refetching the last page.
    await controller.loadMore();
    page = container.read(purchasePickerControllerProvider).value!;
    expect(page.items, hasLength(25));
  });

  test('an invoice number finds one the first page does not hold', () async {
    final purchases = FakePurchasesRepository(purchases: _received(45));
    final container = _container(purchases: purchases);

    await container.read(purchasePickerControllerProvider.future);
    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .search('INV-31');
    final page = await container.read(purchasePickerControllerProvider.future);

    expect(
      page.items.single.invoiceNo,
      'INV-31',
      reason:
          'the 31st invoice is on page two, which is what the old 200-row '
          'dropdown could not reach at all',
    );
    expect(purchases.lastQuery?.search, 'INV-31');
    expect(
      purchases.lastOffset,
      0,
      reason: 'a search starts over rather than paging the old result set',
    );
  });

  test("a distributor's name finds their invoices", () async {
    final purchases = FakePurchasesRepository(
      purchases: <Purchase>[
        for (var index = 1; index <= 3; index++)
          buildPurchase(
            id: 'purchase-$index',
            invoiceNo: 'INV-$index',
            status: PurchaseStatus.received,
          ),
      ],
    );
    // The builder the purchase fixtures use: `id: 'sup-1'`, `name: 'Arihant
    // Distributors'` - so the name matches and no invoice number does.
    final suppliers = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier()],
    );
    final container = _container(purchases: purchases, suppliers: suppliers);

    await container.read(purchasePickerControllerProvider.future);
    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .search('arihant');
    final page = await container.read(purchasePickerControllerProvider.future);

    expect(
      page.items,
      hasLength(3),
      reason:
          'no invoice number contains "arihant" - the documents are found by who '
          'they came from, which is the third thing one box searches',
    );
    expect(purchases.lastQuery?.supplierIds, <String>['sup-1']);
    expect(suppliers.lastQuery?.search, 'arihant');
  });

  test('resolves the supplier branch once, not once per page', () async {
    final purchases = FakePurchasesRepository(purchases: _received(25));
    final suppliers = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier()],
    );
    final container = _container(purchases: purchases, suppliers: suppliers);
    final controller = container.read(
      purchasePickerControllerProvider.notifier,
    );

    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .search('arihant');
    await container.read(purchasePickerControllerProvider.future);
    await controller.loadMore();

    expect(
      suppliers.requestedOffsets,
      hasLength(1),
      reason:
          'a second resolution between two pages of one list would duplicate or '
          'skip rows',
    );
  });

  test('a date window narrows what is offered', () async {
    final purchases = FakePurchasesRepository(
      purchases: <Purchase>[
        buildPurchase(
          id: 'p-old',
          invoiceNo: 'INV-OLD',
          status: PurchaseStatus.received,
        ).copyWith(invoiceDate: DateTime(2025, 6)),
        buildPurchase(
          id: 'p-new',
          invoiceNo: 'INV-NEW',
          status: PurchaseStatus.received,
        ).copyWith(invoiceDate: DateTime(2026, 6)),
      ],
    );
    final container = _container(purchases: purchases);

    await container.read(purchasePickerControllerProvider.future);
    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .dateRange(from: DateTime(2026), to: DateTime(2026, 12));
    final page = await container.read(purchasePickerControllerProvider.future);

    expect(page.items.single.invoiceNo, 'INV-NEW');
  });

  test('clearing the term clears the supplier branch with it', () async {
    final purchases = FakePurchasesRepository(purchases: _received(3));
    final suppliers = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier()],
    );
    final container = _container(purchases: purchases, suppliers: suppliers);

    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .search('arihant');
    await container.read(purchasePickerControllerProvider.future);
    expect(purchases.lastQuery?.supplierIds, isNotEmpty);

    container.read(purchasePickerFilterControllerProvider.notifier).search('');
    await container.read(purchasePickerControllerProvider.future);

    expect(
      purchases.lastQuery?.supplierIds,
      isEmpty,
      reason:
          'those ids were resolved from the term, so they are not a filter the '
          'user asked for once the term is gone',
    );
  });

  test('a search that fails is an error, and one the user can retry', () async {
    final purchases = FakePurchasesRepository(purchases: _received(3))
      ..failNextList = true;
    final container = _container(purchases: purchases);

    await expectLater(
      container.read(purchasePickerControllerProvider.future),
      throwsA(isA<StateError>()),
    );
    expect(
      container.read(purchasePickerControllerProvider),
      isA<AsyncError<PurchasePickerPage>>(),
    );

    container
        .read(purchasePickerFilterControllerProvider.notifier)
        .search('INV-1');
    final page = await container.read(purchasePickerControllerProvider.future);
    expect(page.items.single.invoiceNo, 'INV-1');
  });

  test('a page that fails to load keeps the rows already on screen', () async {
    final purchases = FakePurchasesRepository(purchases: _received(25));
    final container = _container(purchases: purchases);
    final controller = container.read(
      purchasePickerControllerProvider.notifier,
    );

    await container.read(purchasePickerControllerProvider.future);
    purchases.failNextList = true;

    await expectLater(controller.loadMore(), throwsA(isA<StateError>()));

    final page = container.read(purchasePickerControllerProvider).value!;
    expect(page.items, hasLength(purchasePickerPageSize));
    expect(
      page.isLoadingMore,
      isFalse,
      reason: 'the spinner must not be left running on a page that failed',
    );
  });
}
