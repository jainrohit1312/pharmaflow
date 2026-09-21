/// Unit tests for the document `save_product()` is handed.
///
/// The payload is a contract with a server-side function, not an implementation detail of one
/// repository method, so it is asserted here rather than through a widget: these are the keys the
/// SQL shape check reads, and the one thing a client must NOT be able to name - the action type -
/// is exactly what is absent from all of them.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_draft.dart';
import 'package:app/features/products/data/product_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// A draft with one of everything the form can collect.
const ProductDraft _full = ProductDraft(
  name: 'Azithromycin 500',
  scheduleType: ScheduleType.h1,
  minStockLevel: 4,
  isActive: false,
  genericName: 'Azithromycin',
  brand: 'Zithro',
  manufacturer: 'Cipla',
  hsnCode: '3004',
  category: 'Antibiotic',
  packSize: '10s',
  unit: 'strip',
  rackLocation: 'R-1',
  barcode: 'BAR-1',
);

void main() {
  group('create', () {
    test(
      'carries the draft and no product_id, which is what makes it a create',
      () {
        final payload = ProductPayload.create(draft: _full);

        expect(
          payload.containsKey('product_id'),
          isFalse,
          reason: 'its absence is how the server knows this is a new product',
        );
        expect(payload['name'], 'Azithromycin 500');
        expect(payload['schedule_type'], 'H1');
        expect(payload['min_stock_level'], 4);
        expect(payload['is_active'], isFalse);
        expect(payload['generic_name'], 'Azithromycin');
        expect(payload['rack_location'], 'R-1');
      },
    );

    test('echoes the idempotency key, so a double tap is one ask', () {
      expect(
        ProductPayload.create(
          draft: _full,
          idempotencyKey: 'k-1',
        )['idempotency_key'],
        'k-1',
      );
    });
  });

  group('edit', () {
    test('names the product and sends the WHOLE draft', () {
      final payload = ProductPayload.edit(productId: 'p-1', draft: _full);

      expect(payload['product_id'], 'p-1');
      expect(
        payload['barcode'],
        'BAR-1',
        reason:
            'a partial draft would make a later ask lose the earlier one, because an '
            'undecided ask about this product is refreshed rather than stacked',
      );
      expect(payload['name'], 'Azithromycin 500');
    });
  });

  group('active', () {
    test('is the flag alone, so the toggle cannot restate the master', () {
      expect(
        ProductPayload.active(productId: 'p-1', isActive: false),
        <String, dynamic>{'product_id': 'p-1', 'is_active': false},
      );
    });
  });

  group('alias', () {
    test('is a document of its own, with the text trimmed', () {
      final payload = ProductPayload.alias(
        productId: 'p-1',
        rawName: '  DOLO-650 TAB  ',
        supplierId: 's-1',
      );

      expect(payload['product_id'], 'p-1');
      expect(payload['alias'], <String, dynamic>{
        'raw_name': 'DOLO-650 TAB',
        'supplier_id': 's-1',
      });
      expect(
        payload.containsKey('name'),
        isFalse,
        reason:
            'the server refuses a payload that mixes a field change with an alias act',
      );
      expect(
        payload.containsKey('normalized_name'),
        isFalse,
        reason:
            'the database normalizes it, so one definition of the key exists',
      );
    });

    test(
      'a known supplier is null rather than absent, which is a pharmacy-wide alias',
      () {
        expect(
          (ProductPayload.alias(productId: 'p-1', rawName: 'X')['alias']
              as Map<String, dynamic>)['supplier_id'],
          isNull,
        );
      },
    );
  });

  group('removeAlias', () {
    test('names the product as well as the alias', () {
      expect(
        ProductPayload.removeAlias(productId: 'p-1', aliasId: 'a-1'),
        <String, dynamic>{'product_id': 'p-1', 'remove_alias_id': 'a-1'},
      );
    });
  });

  test(
    'no payload carries the tenant, because the server takes it from the session',
    () {
      final every = <Map<String, dynamic>>[
        ProductPayload.create(draft: _full),
        ProductPayload.edit(productId: 'p-1', draft: _full),
        ProductPayload.active(productId: 'p-1', isActive: true),
        ProductPayload.alias(productId: 'p-1', rawName: 'X'),
        ProductPayload.removeAlias(productId: 'p-1', aliasId: 'a-1'),
      ];

      for (final payload in every) {
        expect(
          payload.containsKey('pharmacy_id'),
          isFalse,
          reason: 'get_my_pharmacy_id() decides the tenant, never the caller',
        );
        expect(
          payload.containsKey('action_type'),
          isFalse,
          reason: 'the server derives the act from the document',
        );
      }
    },
  );
}
