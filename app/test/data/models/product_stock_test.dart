/// Unit tests for [ProductStock] decoding and its stock-level helpers.
library;

import 'package:app/data/models/product_stock.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProductStock].
///
/// Both quantity fields are required rather than defaulted, so every test states
/// what it is actually exercising.
ProductStock _stock({required int totalQty, required int minStockLevel}) =>
    ProductStock(
      productId: 'p-1',
      pharmacyId: 'ph-1',
      name: 'Paracetamol 500mg',
      totalQty: totalQty,
      minStockLevel: minStockLevel,
    );

void main() {
  group('ProductStock.fromJson', () {
    test('decodes a snake_case product_stock row', () {
      final stock = ProductStock.fromJson(<String, dynamic>{
        'product_id': 'p-1',
        'pharmacy_id': 'ph-1',
        'name': 'Paracetamol 500mg',
        'generic_name': 'Paracetamol',
        'brand': 'Acme',
        'min_stock_level': 20,
        'total_qty': 5,
        'stock_value_at_cost': 120.5,
        'stock_value_at_mrp': 250,
      });

      expect(stock.productId, 'p-1');
      expect(stock.pharmacyId, 'ph-1');
      expect(stock.genericName, 'Paracetamol');
      expect(stock.brand, 'Acme');
      expect(stock.minStockLevel, 20);
      expect(stock.totalQty, 5);
      expect(stock.stockValueAtCost, 120.5);
      expect(stock.stockValueAtMrp, 250);
    });

    test('accepts nulls for the optional columns', () {
      final stock = ProductStock.fromJson(<String, dynamic>{
        'product_id': 'p-1',
        'pharmacy_id': 'ph-1',
        'name': 'Paracetamol 500mg',
        'generic_name': null,
        'brand': null,
        'min_stock_level': 0,
        'total_qty': 0,
        'stock_value_at_cost': 0,
        'stock_value_at_mrp': 0,
      });

      expect(stock.genericName, isNull);
      expect(stock.brand, isNull);
      expect(stock.minStockLevel, isZero);
    });
  });

  group('ProductStockX.isLowStock', () {
    test('is true when quantity is below the reorder level', () {
      final stock = _stock(totalQty: 5, minStockLevel: 20);
      expect(stock.isLowStock, isTrue);
    });

    test('is false when quantity equals the reorder level', () {
      final stock = _stock(totalQty: 20, minStockLevel: 20);
      expect(stock.isLowStock, isFalse);
    });

    test('is false when no reorder level has been configured', () {
      final stock = _stock(totalQty: 0, minStockLevel: 0);
      expect(stock.isLowStock, isFalse);
    });
  });

  group('ProductStockX.isOutOfStock', () {
    test('is true at zero', () {
      final stock = _stock(totalQty: 0, minStockLevel: 10);
      expect(stock.isOutOfStock, isTrue);
    });

    test('is false with stock on hand', () {
      final stock = _stock(totalQty: 1, minStockLevel: 10);
      expect(stock.isOutOfStock, isFalse);
    });

    test('a product can be out of stock and low stock at the same time', () {
      final stock = _stock(totalQty: 0, minStockLevel: 10);
      expect(stock.isOutOfStock, isTrue);
      expect(stock.isLowStock, isTrue);
    });
  });
}
