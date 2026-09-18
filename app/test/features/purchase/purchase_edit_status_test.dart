/// Tests for the D-019 rule: what an edit does to a purchase's status.
///
/// These pin both halves of the decision and the boundary between them. The rule
/// is pure, so it is tested without a client - and it is deliberately the same
/// function the fake repository calls, which is what keeps the screen tests
/// honest about it.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_purchases_repository.dart';

/// A draft line matching [buildItem]'s defaults, so "unchanged" really is
/// unchanged rather than a pair of hand-written values that happen to agree.
PurchaseLineDraft _draft({
  String? productId = 'product-1',
  int qty = 10,
  int freeQty = 0,
  double rate = 100,
  double mrp = 150,
  double discountPercent = 0,
  double gstPercent = 12,
  String? batchNo,
  DateTime? expiryDate,
}) => PurchaseLineDraft(
  qty: qty,
  freeQty: freeQty,
  purchaseRate: rate,
  mrp: mrp,
  discountPercent: discountPercent,
  gstPercent: gstPercent,
  productId: productId,
  productNameRaw: 'Paracetamol 500mg',
  batchNo: batchNo,
  expiryDate: expiryDate,
);

/// Whether [lines] read as a change against the stored [items].
bool _differs(List<PurchaseLineDraft> lines, List<PurchaseItem> items) =>
    PurchasesRepository.linesDiffer(lines: lines, items: items);

void main() {
  group('linesDiffer', () {
    test('is false for the line set that is already stored', () {
      expect(
        _differs(<PurchaseLineDraft>[_draft()], <PurchaseItem>[buildItem()]),
        isFalse,
      );
    });

    test('sees a changed quantity', () {
      expect(
        _differs(
          <PurchaseLineDraft>[_draft(qty: 11)],
          <PurchaseItem>[buildItem()],
        ),
        isTrue,
      );
    });

    test('sees a changed price, discount or slab', () {
      final stored = <PurchaseItem>[buildItem()];

      expect(
        _differs(<PurchaseLineDraft>[_draft(rate: 101)], stored),
        isTrue,
        reason: 'the rate is what the supplier is owed',
      );
      expect(
        _differs(<PurchaseLineDraft>[_draft(discountPercent: 5)], stored),
        isTrue,
        reason: 'a discount changes the payable',
      );
      expect(
        _differs(<PurchaseLineDraft>[_draft(gstPercent: 5)], stored),
        isTrue,
      );
      expect(
        _differs(<PurchaseLineDraft>[_draft(freeQty: 1)], stored),
        isTrue,
        reason: 'scheme units are stock (D-011)',
      );
      expect(_differs(<PurchaseLineDraft>[_draft(mrp: 151)], stored), isTrue);
    });

    test('sees a line added or removed', () {
      final stored = <PurchaseItem>[buildItem()];

      expect(
        _differs(<PurchaseLineDraft>[
          _draft(),
          _draft(productId: 'product-2'),
        ], stored),
        isTrue,
      );
      expect(_differs(<PurchaseLineDraft>[], stored), isTrue);
    });

    test('ignores a difference below the precision the column stores', () {
      // `purchase_rate` is numeric(12,2): the database would round this away, so
      // reporting it as a change would be a revert on a document nobody touched.
      expect(
        _differs(
          <PurchaseLineDraft>[_draft(rate: 100.004)],
          <PurchaseItem>[buildItem()],
        ),
        isFalse,
      );
    });

    test('ignores the order the lines came back in', () {
      // `purchase_items.created_at` is a transaction timestamp, so rows written
      // in one statement share it and a read may return them in any order.
      final stored = <PurchaseItem>[
        buildItem(),
        buildItem(id: 'item-2', productId: 'product-2'),
      ];

      expect(
        _differs(<PurchaseLineDraft>[
          _draft(productId: 'product-2'),
          _draft(),
        ], stored),
        isFalse,
      );
    });

    test('ignores fields the order does not depend on', () {
      // The pharmacy's own counter price and the invoice's printed text are not
      // what the supplier was asked for.
      final stored = <PurchaseItem>[
        buildItem().copyWith(
          sellingRate: 200,
          productNameRaw: 'PARACETAMOL TAB',
        ),
      ];

      expect(
        _differs(<PurchaseLineDraft>[
          _draft().copyWith(sellingRate: 0, productNameRaw: 'Paracetamol'),
        ], stored),
        isFalse,
      );
    });

    test('does not care which way a batch detail is missing', () {
      // A purchased-in batch compares equal to itself; a null on one side and a
      // value on the other is a change.
      final stored = <PurchaseItem>[
        buildItem(batchNo: 'B-1', expiryDate: DateTime(2027, 5)),
      ];

      expect(
        _differs(<PurchaseLineDraft>[
          _draft(batchNo: 'B-1', expiryDate: DateTime(2027, 5)),
        ], stored),
        isFalse,
      );
      expect(
        _differs(<PurchaseLineDraft>[_draft(batchNo: 'B-1')], stored),
        isTrue,
      );
      expect(
        _differs(<PurchaseLineDraft>[
          _draft(expiryDate: DateTime(2027, 5)),
        ], stored),
        isTrue,
      );
    });
  });

  group('statusAfterEdit', () {
    test('keeps an ordered document ordered when only the header changed', () {
      expect(
        PurchasesRepository.statusAfterEdit(
          current: PurchaseStatus.ordered,
          lines: <PurchaseLineDraft>[_draft()],
          items: <PurchaseItem>[buildItem()],
        ),
        PurchaseStatus.ordered,
      );
    });

    test('returns an ordered document to draft when a line changed', () {
      expect(
        PurchasesRepository.statusAfterEdit(
          current: PurchaseStatus.ordered,
          lines: <PurchaseLineDraft>[_draft(qty: 11)],
          items: <PurchaseItem>[buildItem()],
        ),
        PurchaseStatus.draft,
      );
    });

    test('leaves a draft a draft', () {
      expect(
        PurchasesRepository.statusAfterEdit(
          current: PurchaseStatus.draft,
          lines: <PurchaseLineDraft>[_draft(qty: 11)],
          items: <PurchaseItem>[buildItem()],
        ),
        PurchaseStatus.draft,
      );
    });

    test('never invents a status the document did not have', () {
      // `received` and `cancelled` are not editable, so this should not be
      // reached - the point is that the rule is not a blanket reset if it is.
      for (final current in <PurchaseStatus>[
        PurchaseStatus.received,
        PurchaseStatus.cancelled,
      ]) {
        expect(
          PurchasesRepository.statusAfterEdit(
            current: current,
            lines: <PurchaseLineDraft>[_draft(qty: 11)],
            items: <PurchaseItem>[buildItem()],
          ),
          current,
        );
      }
    });
  });
}
