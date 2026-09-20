/// Guards [ProductsRepository.columns]: the client asks for exactly what the
/// model decodes, and never for the server-side embedding column.
library;

import 'package:app/data/models/product.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductsRepository.columns', () {
    test('never asks for the embedding column', () {
      expect(ProductsRepository.columns, isNot(contains('embedding')));
      expect(ProductsRepository.projection, isNot(contains('embedding')));
    });

    test('is the exact projection a product row decodes from', () {
      final row = <String, dynamic>{
        'id': 'p-1',
        'pharmacy_id': 'ph-1',
        'name': 'Paracetamol 500mg',
        'generic_name': 'Paracetamol',
        'brand': 'Acme',
        'manufacturer': 'Acme Labs',
        'hsn_code': '3004',
        'category': 'Analgesic',
        'gst_percent': 5.0,
        'schedule_type': 'H1',
        'pack_size': '10 tablets',
        'unit': 'strip',
        'min_stock_level': 20,
        'rack_location': 'A-1',
        'barcode': '8901234567890',
        'is_active': true,
        'created_at': '2026-09-19T09:00:00Z',
        'updated_at': '2026-09-19T09:00:00Z',
      };

      // The projection is what the repository sends, so these two sets must
      // match: a column in one and not the other is a key that silently arrives
      // absent (or a column fetched and thrown away).
      expect(row.keys.toSet(), ProductsRepository.columns.toSet());

      final product = Product.fromJson(row);
      expect(product.name, 'Paracetamol 500mg');
      expect(product.scheduleType, ScheduleType.h1);
      expect(product.minStockLevel, 20);
      expect(product.barcode, '8901234567890');
      expect(product.isActive, isTrue);
      expect(
        product.gstPercent,
        5,
        reason: 'the slab a sale line is priced from (D-075)',
      );
    });

    test('lists no column twice', () {
      expect(
        ProductsRepository.columns.toSet().length,
        ProductsRepository.columns.length,
      );
    });
  });
}
