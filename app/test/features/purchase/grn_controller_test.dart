/// Tests for [GrnController] and the GST-split provider it depends on.
///
/// The write order itself is not testable here - it is a sequence of SQL calls,
/// and it is verified against the live database by
/// `supabase/tests/grn_write_order.sql`. What these tests pin is the wiring
/// around it: the split that reaches the receipt, the failure that must not look
/// like success, and the fallback that must never let the split provider fail.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/application/grn_controller.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A received purchase, as the repository would return it.
Purchase _received() => Purchase(
  id: 'purchase-1',
  pharmacyId: 'ph-1',
  supplierId: 'sup-1',
  invoiceNo: 'INV-1',
  invoiceDate: DateTime(2026),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: PurchaseStatus.received,
  grandTotal: 1120,
  stockPostedAt: DateTime(2026),
);

/// Records what `receive` was called with.
class _FakePurchasesRepository implements PurchasesRepository {
  /// The id the last call used.
  String? receivedId;

  /// The split the last call was given.
  TaxSplit? receivedSplit;

  /// The lines the last call was given.
  List<PurchaseLineDraft>? receivedLines;

  /// When set, `receive` throws it instead of returning.
  Exception? errorToThrow;

  @override
  Future<Purchase> receive({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    receivedId = purchaseId;
    receivedSplit = split;
    receivedLines = lines;
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return _received();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// A pharmacy repository with a fixed answer, or a fixed failure.
class _FakePharmacyRepository implements PharmacyRepository {
  /// Creates the fake.
  _FakePharmacyRepository({this.state, this.errorToThrow});

  /// The state to report.
  final String? state;

  /// When set, reading the state throws it.
  final Exception? errorToThrow;

  @override
  Future<String?> stateFor(String pharmacyId) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return state;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// A suppliers repository that returns one supplier.
class _FakeSuppliersRepository implements SuppliersRepository {
  /// Creates the fake.
  _FakeSuppliersRepository({this.state});

  /// The state the supplier is registered in.
  final String? state;

  @override
  Future<Supplier?> byId({
    required String pharmacyId,
    required String supplierId,
  }) async => Supplier(
    id: supplierId,
    pharmacyId: pharmacyId,
    name: 'Arihant Distributors',
    state: state,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// A container with the receipt's collaborators stubbed out.
///
/// `split` is stubbed by default because most of these tests are about what
/// happens *around* the receipt; pass `split: null` to exercise the real
/// `purchaseTaxSplit` provider instead.
ProviderContainer _container({
  required _FakePurchasesRepository purchases,
  TaxSplit? split = TaxSplit.intraState,
  _FakePharmacyRepository? pharmacy,
  _FakeSuppliersRepository? suppliers,
}) {
  final container = ProviderContainer(
    overrides: [
      purchasesRepositoryProvider.overrideWithValue(purchases),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      if (split != null)
        purchaseTaxSplitProvider.overrideWith((ref, arg) => split),
      if (pharmacy != null)
        pharmacyRepositoryProvider.overrideWithValue(pharmacy),
      if (suppliers != null)
        suppliersRepositoryProvider.overrideWithValue(suppliers),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// One receivable line.
PurchaseLineDraft _line() => PurchaseLineDraft(
  qty: 10,
  freeQty: 2,
  purchaseRate: 100,
  mrp: 200,
  gstPercent: 12,
  productId: 'product-1',
  productNameRaw: 'Paracetamol 500mg',
  batchNo: 'B-1',
  expiryDate: DateTime(2027),
);

/// The header every call in this file uses.
PurchaseDraft _header() => PurchaseDraft(
  supplierId: 'sup-1',
  invoiceNo: 'INV-1',
  invoiceDate: DateTime(2026),
);

void main() {
  group('GrnController.receive', () {
    test('receives with the split it was given', () async {
      final purchases = _FakePurchasesRepository();
      final container = _container(
        purchases: purchases,
        split: TaxSplit.interState,
      );

      final received = await container
          .read(grnControllerProvider.notifier)
          .receive(
            purchaseId: 'purchase-1',
            header: _header(),
            lines: <PurchaseLineDraft>[_line()],
          );

      expect(purchases.receivedSplit, TaxSplit.interState);
      expect(received.status, PurchaseStatus.received);
      expect(container.read(grnControllerProvider).value?.id, 'purchase-1');
    });

    test('hands the lines over untouched', () async {
      final purchases = _FakePurchasesRepository();
      final container = _container(purchases: purchases);

      await container
          .read(grnControllerProvider.notifier)
          .receive(
            purchaseId: 'purchase-1',
            header: _header(),
            lines: <PurchaseLineDraft>[_line(), _line()],
          );

      expect(purchases.receivedLines, hasLength(2));
      expect(purchases.receivedLines!.first.batchNo, 'B-1');
      expect(purchases.receivedLines!.first.freeQty, 2);
    });

    test('a refused receipt records an error and earns no document', () async {
      final purchases = _FakePurchasesRepository()
        ..errorToThrow = const ValidationException(
          message: 'This purchase is received already',
        );
      final container = _container(purchases: purchases);

      await expectLater(
        container
            .read(grnControllerProvider.notifier)
            .receive(
              purchaseId: 'purchase-1',
              header: _header(),
              lines: <PurchaseLineDraft>[_line()],
            ),
        throwsA(isA<ValidationException>()),
      );

      final state = container.read(grnControllerProvider);
      expect(state.hasError, isTrue);
      expect(state.value, isNull, reason: 'no receipt happened');
    });
  });

  group('purchaseTaxSplit', () {
    test('is inter-state when the two states differ', () async {
      final container = _container(
        purchases: _FakePurchasesRepository(),
        split: null,
        pharmacy: _FakePharmacyRepository(state: 'Gujarat'),
        suppliers: _FakeSuppliersRepository(state: 'Maharashtra'),
      );

      expect(
        await container.read(purchaseTaxSplitProvider('sup-1').future),
        TaxSplit.interState,
      );
    });

    test('is intra-state when the two states match', () async {
      final container = _container(
        purchases: _FakePurchasesRepository(),
        split: null,
        pharmacy: _FakePharmacyRepository(state: 'Maharashtra'),
        suppliers: _FakeSuppliersRepository(state: 'Maharashtra'),
      );

      expect(
        await container.read(purchaseTaxSplitProvider('sup-1').future),
        TaxSplit.intraState,
      );
    });

    test(
      'falls back to intra-state rather than failing, so saves cannot hang',
      () async {
        // A failing provider here would be awaited by every write path, and in
        // Riverpod 3 a failed provider never completes that future (D-015).
        final container = _container(
          purchases: _FakePurchasesRepository(),
          split: null,
          pharmacy: _FakePharmacyRepository(
            errorToThrow: const ServerException(message: 'no pharmacy read'),
          ),
          suppliers: _FakeSuppliersRepository(state: 'Maharashtra'),
        );

        expect(
          await container.read(purchaseTaxSplitProvider('sup-1').future),
          TaxSplit.intraState,
        );
      },
    );
  });
}
