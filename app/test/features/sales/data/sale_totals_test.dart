/// Tests for the sale money math.
///
/// These figures are what the customer is charged and what the ledger posts, so the
/// rules under test are the two the purchase path agreed to (and that `SaleTotals`
/// deliberately shares rather than re-implements): round each figure to two decimals
/// *before* summing, and round half away from zero with an epsilon so `1.005` does
/// not come out a paisa short of what Postgres `numeric` would store.
///
/// **The basis changed to tax-inclusive on 2026-09-20 (D-075).** Every assertion in
/// the first two groups was re-expressed from "quantity x rate, plus tax on top" to
/// "the price on the shelf, with the tax extracted from it" - e.g. 3 x 40 at 12% was
/// taxable 120 / tax 14.40 / total 134.40 and is now, at the owner's 5% slab,
/// taxable 114.29 / tax 5.71 / total 120.00. The rounding rule the last test of the
/// first group covers is unchanged; only the formula it is reached through moved.
///
/// The last group is anchored to the server's own figures: the values
/// `supabase/tests/phase7a_sale_types.sql` asserts of a stored row, reproduced here
/// so a client that previews a total cannot be wrong about the column it becomes.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cart line with only the fields a money assertion cares about.
SaleCartLine _line({
  String productId = 'product-1',
  String batchId = 'batch-1',
  int qty = 1,
  double rate = 100,
  double discountPercent = 0,
  double gstPercent = 0,
}) => SaleCartLine(
  productId: productId,
  productName: 'Dolo 650',
  scheduleType: ScheduleType.otc,
  batchId: batchId,
  batchNo: 'B-1',
  qty: qty,
  rate: rate,
  discountPercent: discountPercent,
  gstPercent: gstPercent,
);

/// One line's breakdown, on the commonest basis: a counter sale, intra-state.
///
/// No bill-level discount: that is a figure about the whole document, so the group that
/// tests it prices whole baskets rather than single lines.
SaleLineTotals _counter(
  SaleCartLine line, {
  TaxSplit split = TaxSplit.intraState,
}) => SaleTotals.forLine(
  line,
  split: split,
  saleType: SaleType.counter,
  discountShare: 0,
);

void main() {
  group('a line', () {
    test('is the price on the shelf when nothing is discounted', () {
      // 3 x 40 = 120 charged. At the owner's 5% slab, 120 / 1.05 = 114.29 of value
      // and 5.71 of tax - the tax the price *contains*, not 6.00 on top.
      final totals = _counter(_line(qty: 3, rate: 40, gstPercent: 5));

      expect(totals.discount, 0);
      expect(totals.total, 120);
      expect(totals.taxable, 114.29);
      expect(totals.tax, 5.71);
    });

    test('takes the discount off the price the customer pays', () {
      final totals = _counter(
        _line(qty: 10, discountPercent: 10, gstPercent: 5),
      );

      // 1000 shelf price, 100 off, so the customer pays 900 - and the tax comes out
      // of that 900 rather than being charged on top of it.
      expect(totals.discount, 100);
      expect(totals.total, 900);
      expect(totals.taxable, 857.14);
      expect(totals.tax, 42.86);
    });

    test('splits the tax into CGST and SGST for an intra-state supply', () {
      // The owner's own worked example, and the server's: 105 at 5% is 100 + 5,
      // and the two heads are 2.50 each.
      final totals = _counter(_line(rate: 105, gstPercent: 5));

      expect(totals.taxable, 100);
      expect(totals.tax, 5);
      expect(totals.cgst, 2.5);
      expect(totals.sgst, 2.5);
      expect(totals.igst, 0);
    });

    test('charges IGST, and no CGST or SGST, for an inter-state supply', () {
      final totals = _counter(
        _line(rate: 105, gstPercent: 5),
        split: TaxSplit.interState,
      );

      expect(totals.cgst, 0);
      expect(totals.sgst, 0);
      expect(totals.igst, 5);
    });

    test('the two halves always add back to the tax', () {
      // 105.21 at 5% is 100.20 of value and 5.01 of tax, which has no exact half.
      // Splitting it by rounding each half independently would give 2 + 3 paise of
      // the head and charge a paisa that was never due - which is why the second
      // half is the difference.
      final totals = _counter(_line(rate: 105.21, gstPercent: 5));

      expect(totals.tax, 5.01);
      expect(totals.cgst, 2.51);
      expect(totals.sgst, 2.5);
      expect(PurchaseTotals.round2(totals.cgst + totals.sgst), totals.tax);
    });

    test('rounds a half away from zero, as Postgres numeric does', () {
      // A naive `round()` reads 1.005 as 1.00499999... and gives 1.00; the epsilon
      // in the shared rule is what makes this 1.01, and a sale that disagreed with
      // the column it is stored in would be a stored figure that does not match its
      // own arithmetic.
      expect(
        SaleTotals.taxableFromInclusive(total: 2.01, gstPercent: 100),
        1.01,
      );
      expect(SaleTotals.taxFromInclusive(total: 2.01, gstPercent: 100), 1);
    });
  });

  group('the rate, per sale type', () {
    test(
      'a pharmacy sale is priced at the caller, then the batch, then the MRP',
      () {
        // The same resolution `checkout_sale()` makes: a rate the counter typed, else
        // the batch's counter price, else its MRP. A zero is not a rate.
        expect(
          SaleTotals.retailRate(rate: 150, sellingRate: 200, mrp: 250),
          150,
        );
        expect(
          SaleTotals.retailRate(rate: 0, sellingRate: 200, mrp: 250),
          200,
          reason: 'a zero rate is no rate, and the batch has a counter price',
        );
        expect(
          SaleTotals.retailRate(sellingRate: 0, mrp: 250),
          250,
          reason: 'a product never given a counter price is still billable',
        );
      },
    );

    test('a package sale is the purchase rate plus the markup', () {
      // The server's own fixture: a batch whose purchase rate is 80 and whose landed
      // cost is 100 prices at 96 under a 20% markup, not at 120 - the basis is
      // deliberately the purchase rate (D-070).
      expect(SaleTotals.packageRate(purchaseRate: 80, markupPercent: 20), 96);
      expect(SaleTotals.packageRate(purchaseRate: 80, markupPercent: 7.5), 86);
      expect(
        SaleTotals.packageRate(purchaseRate: 80, markupPercent: 0),
        80,
        reason: 'a configured zero is a real deal, not a missing one (D-068)',
      );
    });

    test('a transfer is plain cost, with no markup', () {
      expect(SaleTotals.transferRate(purchaseRate: 80), 80);
    });
  });

  group('a package sale', () {
    test('extracts the tax from the cost-plus figure', () {
      // One unit at the 96 the markup produced, at the product's 5% slab.
      final totals = SaleTotals.forLine(
        _line(rate: 96, gstPercent: 5),
        split: TaxSplit.intraState,
        saleType: SaleType.package,
        discountShare: 0,
      );

      expect(totals.total, 96);
      expect(totals.taxable, 91.43);
      expect(totals.tax, 4.57);
      expect(totals.cgst, 2.29);
      expect(totals.sgst, 2.28);
    });

    test('is computed with no discount, because the type has none', () {
      // A line that carries one must not be sent - `discountRefusal` refuses it and
      // so does the server - but the preview must not quietly apply it either, or
      // the counter would show a price the server would never store.
      final totals = SaleTotals.forLine(
        _line(rate: 96, discountPercent: 10, gstPercent: 5),
        split: TaxSplit.intraState,
        saleType: SaleType.package,
        discountShare: 0,
      );

      expect(totals.discount, 0);
      expect(totals.total, 96);
    });
  });

  group('a transfer', () {
    test('charges no tax and takes no discount', () {
      final totals = SaleTotals.forLine(
        _line(qty: 2, rate: 80, discountPercent: 10, gstPercent: 5),
        split: TaxSplit.intraState,
        saleType: SaleType.transfer,
        discountShare: 0,
      );

      expect(totals.discount, 0);
      expect(totals.total, 160);
      expect(totals.taxable, 160);
      expect(totals.tax, 0);
      expect(totals.cgst, 0);
      expect(totals.sgst, 0);
      expect(totals.igst, 0);
    });
  });

  group('the discount cap', () {
    test('exactly 10% proceeds on a pharmacy sale', () {
      expect(
        SaleTotals.discountRefusal(
          saleType: SaleType.counter,
          discountPercent: 10,
        ),
        isNull,
      );
      expect(
        SaleTotals.discountRefusal(
          saleType: SaleType.ipdAdmission,
          discountPercent: 10,
        ),
        isNull,
      );
    });

    test('above 10% is refused, naming the approval that does not exist', () {
      final refusal = SaleTotals.discountRefusal(
        saleType: SaleType.counter,
        discountPercent: 10.5,
      );

      expect(refusal, isNotNull);
      expect(refusal, contains('above 10%'));
      expect(
        refusal,
        contains('approval'),
        reason:
            'the cap is real rather than a prompt, so the refusal says what is '
            'missing instead of offering a workflow that was never built',
      );
    });

    test('a package or transfer sale has no discount at all', () {
      for (final type in <SaleType>[SaleType.package, SaleType.transfer]) {
        expect(
          SaleTotals.discountRefusal(saleType: type, discountPercent: 5),
          isNotNull,
        );
        expect(
          SaleTotals.discountRefusal(saleType: type, discountPercent: 0),
          isNull,
          reason: 'no discount is always acceptable: it is the absence of one',
        );
      }
    });

    test(
      'a percentage off the scale is refused before the cap is considered',
      () {
        expect(
          SaleTotals.discountRefusal(
            saleType: SaleType.counter,
            discountPercent: -1,
          ),
          isNotNull,
        );
        expect(
          SaleTotals.discountRefusal(
            saleType: SaleType.counter,
            discountPercent: 101,
          ),
          isNotNull,
        );
      },
    );
  });

  group('the MRP ceiling', () {
    test('a retail rate above MRP is refused, naming the product', () {
      final refusal = SaleTotals.rateRefusal(
        saleType: SaleType.counter,
        rate: 260,
        mrp: 250,
        productName: 'Dolo 650',
      );

      expect(refusal, isNotNull);
      expect(refusal, contains('Dolo 650'));
      expect(refusal, contains('250.00'));
    });

    test('exactly MRP is billable, which is the commonest price there is', () {
      expect(
        SaleTotals.rateRefusal(
          saleType: SaleType.counter,
          rate: 250,
          mrp: 250,
          productName: 'Dolo 650',
        ),
        isNull,
      );
    });

    test(
      'a package or transfer line has no ceiling, because it is not retail',
      () {
        for (final type in <SaleType>[SaleType.package, SaleType.transfer]) {
          expect(
            SaleTotals.rateRefusal(
              saleType: type,
              rate: 260,
              mrp: 250,
              productName: 'Dolo 650',
            ),
            isNull,
          );
        }
      },
    );

    test('a line with no rate and no MRP cannot be priced', () {
      expect(
        SaleTotals.rateRefusal(
          saleType: SaleType.counter,
          rate: 0,
          mrp: 0,
          productName: 'Dolo 650',
        ),
        isNotNull,
      );
    });
  });

  group('a package sale whose markup nobody configured', () {
    test('is refused rather than priced at an invented percentage', () {
      final refusal = SaleTotals.packageMarkupRefusal(markupPercent: null);

      expect(refusal, isNotNull);
      expect(refusal, contains('markup'));
    });

    test('a configured zero is a value, so it is not refused', () {
      expect(SaleTotals.packageMarkupRefusal(markupPercent: 0), isNull);
      expect(SaleTotals.packageMarkupRefusal(markupPercent: 20), isNull);
    });
  });

  group('a document', () {
    test('totals are the sum of its lines', () {
      final lines = <SaleCartLine>[
        _line(qty: 2, rate: 150, gstPercent: 5),
        _line(batchId: 'batch-2', qty: 3, rate: 33.35, discountPercent: 5),
      ];

      final totals = SaleTotals.forLines(
        lines,
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );
      final perLine = lines.map(_counter).toList(growable: false);

      expect(
        totals.subTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.taxable),
        ),
      );
      expect(
        totals.discountTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.discount),
        ),
      );
      expect(
        totals.taxTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.tax),
        ),
      );
      expect(
        totals.grandTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.total),
        ),
        reason: 'the stored grand total must equal the sum of its stored lines',
      );
    });

    test('the taxable value and the tax add back to the grand total', () {
      // The identity `checkout_sale()` writes into the header: `sub_total` is
      // `grand_total - tax_total`, so a bill cannot describe two different sales.
      final totals = SaleTotals.forLines(
        <SaleCartLine>[
          _line(qty: 3, rate: 33.35, gstPercent: 5),
          _line(batchId: 'batch-2', qty: 7, rate: 12.5, gstPercent: 12),
        ],
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );

      expect(
        PurchaseTotals.round2(totals.subTotal + totals.taxTotal),
        totals.grandTotal,
      );
    });

    test('an empty basket comes to nothing rather than throwing', () {
      final totals = SaleTotals.forLines(
        const <SaleCartLine>[],
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );

      expect(totals.subTotal, 0);
      expect(totals.taxTotal, 0);
      expect(totals.grandTotal, 0);
    });

    test('the tax total is the same whichever way it is split', () {
      final lines = <SaleCartLine>[
        _line(qty: 3, rate: 33.35, gstPercent: 5),
        _line(batchId: 'batch-2', qty: 7, rate: 12.5, gstPercent: 5),
      ];

      final intra = SaleTotals.forLines(
        lines,
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );
      final inter = SaleTotals.forLines(
        lines,
        split: TaxSplit.interState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );

      expect(
        intra.taxTotal,
        inter.taxTotal,
        reason: 'where the goods went changes the heads, not the tax',
      );
      expect(intra.grandTotal, inter.grandTotal);
    });
  });

  group('a bill-level discount', () {
    /// The owner's own example: a bill of 546, a discount of 46, and 500 to pay.
    ///
    /// Two lines, 2 x 105 at 5% and 2 x 168 at 12% - **the same bill**
    /// `supabase/tests/phase7a_bill_discount.sql` writes, so the preview the counter shows
    /// and the row the server stores are pinned to the same figures rather than to two
    /// derivations that happen to look alike.
    List<SaleCartLine> ownerExample() => <SaleCartLine>[
      _line(qty: 2, rate: 105, gstPercent: 5),
      _line(batchId: 'batch-2', qty: 2, rate: 168, gstPercent: 12),
    ];

    /// That example, or any other basket, priced as a document.
    SalePricedBasket price(List<SaleCartLine> lines, double billDiscount) =>
        SaleTotals.price(
          lines,
          split: TaxSplit.intraState,
          saleType: SaleType.counter,
          billDiscount: billDiscount,
        );

    test('546 less 46 is 500, and the tax comes out of the 500', () {
      final priced = price(ownerExample(), 46);

      expect(priced.totals.grandTotal, 500);
      expect(priced.totals.discountTotal, 46);
      expect(priced.totals.taxTotal, 42.13);
      expect(priced.totals.subTotal, 457.87);
      expect(
        PurchaseTotals.round2(priced.totals.subTotal + priced.totals.taxTotal),
        priced.totals.grandTotal,
        reason:
            'the header is the sum of its lines, which is what sharing the '
            'discount across them keeps true',
      );
    });

    test('shares it in proportion to each line, and the last takes the rest', () {
      final priced = price(ownerExample(), 46);

      // 210 of the 546 is the 5% line, so its share is 210 x 46 / 546 = 17.69, and the
      // 12% line takes the remainder, 28.31.
      expect(priced.lines[0].discount, 17.69);
      expect(priced.lines[0].total, 192.31);
      expect(priced.lines[1].discount, 28.31);
      expect(priced.lines[1].total, 307.69);
      expect(
        PurchaseTotals.round2(priced.lines[0].total + priced.lines[1].total),
        priced.totals.grandTotal,
        reason: 'the lines still add up to the header they were priced into',
      );
    });

    test('takes the tax out of the DISCOUNTED price, not the original', () {
      final priced = price(ownerExample(), 46);

      // 192.31 / 1.05 = 183.15 of value and 9.16 of tax; 307.69 / 1.12 = 274.72 + 32.97.
      expect(priced.lines[0].taxable, 183.15);
      expect(priced.lines[0].tax, 9.16);
      expect(priced.lines[1].taxable, 274.72);
      expect(priced.lines[1].tax, 32.97);

      expect(
        priced.totals.taxTotal,
        lessThan(price(ownerExample(), 0).totals.taxTotal),
        reason:
            'a discount given at the time of supply reduces the tax with it - '
            'charging the tax of the undiscounted bill would over-report GST',
      );
    });

    test('the last line absorbs the remainder, so the shares add to the rupee', () {
      // Seven paise is not divisible by three in proportion: 10 x 0.07 / 60 = 0.0116...,
      // 20 x 0.07 / 60 = 0.0233..., and the last line takes the remaining 0.04 rather
      // than its own 0.03 - which is what makes the shares add back to what was typed.
      final lines = <SaleCartLine>[
        _line(rate: 10, gstPercent: 5),
        _line(batchId: 'batch-2', rate: 20, gstPercent: 5),
        _line(batchId: 'batch-3', rate: 30, gstPercent: 5),
      ];

      expect(
        SaleTotals.billDiscountShares(
          lines,
          saleType: SaleType.counter,
          billDiscount: 0.07,
        ),
        <double>[0.01, 0.02, 0.04],
      );
      expect(price(lines, 0.07).totals.discountTotal, 0.07);
    });

    test('a bill that names no discount is priced exactly as before', () {
      final priced = price(ownerExample(), 0);

      // 210 at 5% is 200 + 10, and 336 at 12% is 300 + 36, so the bill is 546.
      expect(priced.totals.grandTotal, 546);
      expect(priced.totals.subTotal, 500);
      expect(priced.totals.taxTotal, 46);
      expect(priced.totals.discountTotal, 0);
      expect(priced.lines[0].discount, 0);
    });

    test("a line's own discount and the bill's share both come off it", () {
      final lines = <SaleCartLine>[
        _line(qty: 2, rate: 105, discountPercent: 10, gstPercent: 5),
      ];

      // 210 less its own 10% is 189.00; a further 9 off the bill leaves 180.00, and the
      // line records BOTH (21.00 + 9.00) - which is what keeps `discountTotal` the sum
      // of the lines rather than a figure of its own.
      final priced = price(lines, 9);

      expect(priced.lines.single.discount, 30);
      expect(priced.lines.single.total, 180);
      expect(priced.totals.discountTotal, 30);
      expect(priced.totals.subTotal, 171.43);
      expect(priced.totals.taxTotal, 8.57);
    });

    test('the cap is taken on the bill BEFORE the discount', () {
      final lines = ownerExample();

      expect(SaleTotals.billGross(lines, saleType: SaleType.counter), 546);
      expect(
        SaleTotals.billDiscountRefusal(
          saleType: SaleType.counter,
          billDiscount: 54.6,
          billGross: 546,
        ),
        isNull,
        reason: 'exactly 10% of the bill is allowed',
      );
      expect(
        SaleTotals.billDiscountRefusal(
          saleType: SaleType.counter,
          billDiscount: 54.61,
          billGross: 546,
        ),
        contains('above 10%'),
        reason:
            'a paisa above the cap needs an approval that does not exist yet',
      );
    });

    test('is refused when it is larger than the bill, or negative', () {
      expect(
        SaleTotals.billDiscountRefusal(
          saleType: SaleType.counter,
          billDiscount: 600,
          billGross: 546,
        ),
        contains('larger than the bill'),
      );
      expect(
        SaleTotals.billDiscountRefusal(
          saleType: SaleType.counter,
          billDiscount: -1,
          billGross: 546,
        ),
        contains('cannot be negative'),
      );
    });

    test('is refused outright where the type has no discount concept', () {
      for (final type in <SaleType>[SaleType.package, SaleType.transfer]) {
        expect(
          SaleTotals.billDiscountRefusal(
            saleType: type,
            billDiscount: 1,
            billGross: 546,
          ),
          contains('has no discount'),
          reason: type.label,
        );
        expect(
          SaleTotals.billDiscountShares(
            ownerExample(),
            saleType: type,
            billDiscount: 46,
          ),
          <double>[0, 0],
          reason: 'nothing is shared out on a bill that may not carry one',
        );
      }
    });

    test('an empty basket with a discount comes to nothing, not an error', () {
      final priced = price(const <SaleCartLine>[], 46);

      expect(priced.lines, isEmpty);
      expect(priced.totals.grandTotal, 0);
      expect(priced.totals.discountTotal, 0);
    });

    test("the cap is the owner's to lift, and staff ask him for it", () {
      // The same over-cap figure, three ways: refused to staff with the sentence that
      // says what to do about it, free for the owner (2026-09-21), and passable for
      // anyone once an approval is attached - because whether that approval is real is
      // `checkout_sale()`'s to decide against the stored row, never the client's.
      String? refusalBy({bool isOwner = false, bool hasApproval = false}) =>
          SaleTotals.billDiscountRefusal(
            saleType: SaleType.counter,
            billDiscount: 100,
            billGross: 546,
            isOwner: isOwner,
            hasApproval: hasApproval,
          );

      expect(refusalBy(), contains('ask for it'));
      expect(refusalBy(isOwner: true), isNull);
      expect(refusalBy(hasApproval: true), isNull);
    });

    test('and the counter asks whether to OFFER the ask or refuse', () {
      // The question behind the discount field's button, which is a different one from
      // "may this be billed": a discount larger than the bill is a refusal, not an ask,
      // and exactly 10% is the counter's own to give.
      bool offers({required double billDiscount, bool isOwner = false}) =>
          SaleTotals.needsOwnerApproval(
            saleType: SaleType.counter,
            billDiscount: billDiscount,
            billGross: 546,
            isOwner: isOwner,
          );

      expect(offers(billDiscount: 100), isTrue);
      expect(
        offers(billDiscount: 54.6),
        isFalse,
        reason: 'exactly 10% is the counter\u2019s own to give',
      );
      expect(
        offers(billDiscount: 100, isOwner: true),
        isFalse,
        reason:
            'he needs nobody\u2019s permission, so there is nothing to offer him',
      );
      expect(
        offers(billDiscount: 600),
        isFalse,
        reason:
            'a discount larger than the bill is a different refusal, not an ask',
      );
    });
  });

  group("the server's own figures", () {
    test('105 at 5% is 100 of value and 5 of tax, as the SQL suite asserts', () {
      // `supabase/tests/phase7a_sale_types.sql`: grand 105.00, sub 100.00,
      // tax 5.00, and the two heads 2.50 each. The client's preview must be able to
      // state the same figures for the same payload, because that row is what the
      // customer's bill will print.
      final totals = SaleTotals.forLines(
        <SaleCartLine>[_line(rate: 105, gstPercent: 5)],
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );

      expect(totals.grandTotal, 105);
      expect(totals.subTotal, 100);
      expect(totals.taxTotal, 5);
    });

    test('a recorded zero slab means zero tax, as the SQL suite asserts', () {
      // 2 x 60 with the slab recorded as 0: tax 0.00 and a grand total of 120.00,
      // not 120.00 plus a default that was never asked for. The zero is the point of
      // the test rather than a value left to the fixture's own default, which is why
      // it is stated.
      final zeroSlab = <SaleCartLine>[
        // ignore: avoid_redundant_argument_values
        _line(qty: 2, rate: 60, gstPercent: 0),
      ];
      final totals = SaleTotals.forLines(
        zeroSlab,
        split: TaxSplit.intraState,
        saleType: SaleType.counter,
        billDiscount: 0,
      );

      expect(totals.grandTotal, 120);
      expect(totals.taxTotal, 0);
      expect(totals.subTotal, 120);
    });
  });

  group('what a tender may record', () {
    test('a tender below the bill is recorded as tendered', () {
      expect(SaleTotals.recordablePaid(tendered: 100, total: 217.6), 100);
    });

    test('a tender above the bill is clamped to the bill', () {
      // The change handed back is not revenue, and `sales_payment_check` refuses
      // a sale paid beyond its total.
      expect(SaleTotals.recordablePaid(tendered: 500, total: 217.6), 217.6);
      expect(SaleTotals.changeFor(tendered: 500, total: 217.6), 282.4);
    });

    test('nothing recorded and nothing billed is nothing paid', () {
      expect(SaleTotals.recordablePaid(tendered: 0, total: 217.6), 0);
      expect(SaleTotals.recordablePaid(tendered: 500, total: 0), 0);
      expect(SaleTotals.recordablePaid(tendered: -5, total: 217.6), 0);
    });

    test('the change is never negative', () {
      expect(SaleTotals.changeFor(tendered: 100, total: 217.6), 0);
      expect(SaleTotals.changeFor(tendered: 217.6, total: 217.6), 0);
    });
  });
}
