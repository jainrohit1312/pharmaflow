/// Unit tests for the two lists applying a deposit needs.
///
/// The shapes here are the ones the server actually sends: `open_bills()` answers a `jsonb`
/// envelope whose money arrives as a JSON number or a string depending on how PostgREST rendered
/// the `numeric`, and a receipt comes from a plain table read with its `payment_allocations`
/// embedded. Both are decoded in one place, so both are pinned here.
library;

import 'package:app/data/models/party_deposits.dart';
import 'package:app/data/models/sale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenBill', () {
    test(
      'decodes an open_bills entry, whose money may be a string or a number',
      () {
        final bill = OpenBill.fromJson(<String, dynamic>{
          'sale_id': 'sale-1',
          'invoice_no': 'SL260918-0001',
          'sale_date': '2026-09-18T00:00:00',
          'sale_type': 'ipd_admission',
          'grand_total': '1050.00',
          'returned_total': 0,
          'allocated_total': '945.00',
          'outstanding': 105.0,
        });

        expect(bill.saleId, 'sale-1');
        expect(bill.invoiceNo, 'SL260918-0001');
        expect(bill.saleDate, DateTime(2026, 9, 18));
        expect(bill.saleType, SaleType.ipdAdmission);
        expect(bill.grandTotal, 1050);
        expect(bill.allocatedTotal, 945);
        expect(
          bill.outstanding,
          105,
          reason: "the outstanding is the server's, read as it arrives",
        );
      },
    );

    test('reads an unrecognised sale type as a counter sale', () {
      final bill = OpenBill.fromJson(<String, dynamic>{'sale_id': 'sale-1'});

      expect(bill.saleType, SaleType.counter);
      expect(
        bill.invoiceNo,
        '—',
        reason: 'a bill the server sent without a number still has to render',
      );
      expect(bill.saleDate, isNull);
    });
  });

  group('DepositReceipt', () {
    test(
      'sums the allocations embedded in the row to find what is still held',
      () {
        final receipt = DepositReceipt.fromJson(<String, dynamic>{
          'id': 'payment-1',
          'payment_date': '2026-09-18',
          'mode': 'upi',
          'reference_no': 'ZZTEST-UPI-1',
          'amount': '500.00',
          'payment_allocations': <dynamic>[
            <String, dynamic>{'amount': '105.00'},
            <String, dynamic>{'amount': 95},
          ],
        });

        expect(receipt.mode, PaymentMode.upi);
        expect(receipt.referenceNo, 'ZZTEST-UPI-1');
        expect(receipt.amount, 500);
        expect(receipt.applied, 200);
        expect(receipt.held, 300, reason: 'amount − applied, and nothing else');
        expect(receipt.hasHeld, isTrue);
      },
    );

    test('a receipt with nothing applied holds all of it', () {
      final receipt = DepositReceipt.fromJson(<String, dynamic>{
        'id': 'payment-1',
        'amount': 500,
      });

      expect(receipt.applied, 0);
      expect(receipt.held, 500);
      expect(receipt.hasHeld, isTrue);
    });

    test('a receipt applied in full does NOT count as held', () {
      final receipt = DepositReceipt.fromJson(<String, dynamic>{
        'id': 'payment-1',
        'amount': 500,
        'payment_allocations': <dynamic>[
          <String, dynamic>{'amount': 500},
        ],
      });

      expect(receipt.held, 0);
      expect(
        receipt.hasHeld,
        isFalse,
        reason:
            'this is the filter the reader applies, so a receipt with nothing left is never '
            'offered to the sheet at all',
      );
    });

    test(
      'an over-applied receipt holds a negative, which is not offered either',
      () {
        final receipt = DepositReceipt.fromJson(<String, dynamic>{
          'id': 'payment-1',
          'amount': 500,
          'payment_allocations': <dynamic>[
            <String, dynamic>{'amount': 600},
          ],
        });

        expect(
          receipt.hasHeld,
          isFalse,
          reason:
              'the lock prevents this, and the reader would not offer it if it happened',
        );
      },
    );
  });
}
