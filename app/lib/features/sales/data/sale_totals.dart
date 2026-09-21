/// Money math for a sale, on the basis the server prices it.
///
/// Pure, and separate from the repository, for the same reason `PurchaseTotals`
/// is: these figures are what the customer is charged and what the ledger posts,
/// so a rounding mistake is money rather than a display glitch.
///
/// **The basis is tax-INCLUSIVE** (D-075, migration 00036). For a pharmacy sale the
/// rate on a line *is* the price the customer pays, and the tax is **extracted**
/// from it rather than added on top: ₹105 at 5% is ₹100 taxable plus ₹5 tax, not
/// ₹110.25. Three things follow, and every one of them matches the server:
///
///  * a line's total is `qty × rate − discount`, so a bill comes to the price on
///    the shelf;
///  * a line's taxable value is `total / (1 + slab/100)` and its tax is the
///    remainder, which makes the document's `sub_total` equal
///    `grand_total − tax_total` - the identity `checkout_sale()` writes;
///  * the rate itself is per sale type: a `counter` or `ipd_admission` line is
///    retail-priced, a `package` line is cost plus the pharmacy's markup, and a
///    `transfer` is plain cost with no tax at all.
///
/// Two rules keep the stored numbers self-consistent, and both are inherited from
/// the purchase path so the two money paths cannot disagree:
///
///  * every figure is rounded to two decimals *before* it is summed, so the stored
///    `grand_total` always equals the sum of the stored lines;
///  * rounding is half-away-from-zero with an epsilon ([PurchaseTotals.round2]),
///    which is what Postgres `numeric` does - every figure is therefore a whole
///    number of paise, and `1.005` does not come out a paisa short of what the
///    column will hold.
///
/// **The bill-level discount** (migration 00042, owner 2026-09-21) is applied here on
/// the same basis and in the same order the server applies it: one amount in rupees
/// comes off the tax-inclusive total, it is **distributed across the lines** in
/// proportion to each line's own total with the last line taking the rounding
/// remainder ([SaleTotals.billDiscountShares]), and each line's value and tax are then extracted
/// from its discounted total. So a line's `discount` is its own percentage **plus** its
/// share of the bill's, which is what keeps the document's `discountTotal` the sum of
/// its lines and the receipt's `Discount -Rs 46.00` the figure the counter typed.
///
/// The money is carried as `double` rather than as an integer-paise type because
/// the models decode `numeric(14,2)` columns into `double` and a parallel paise
/// type would exist only to be converted at every boundary. The rounding rule is
/// what makes that safe: at these magnitudes `round2` lands on the exact paise, and
/// the tests assert exact equality on figures anchored to the server's own.
library;

import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';

/// The components of one sale line, as the `sale_items` columns want them.
class SaleLineTotals {
  /// Creates line totals.
  const SaleLineTotals({
    required this.taxable,
    required this.discount,
    required this.tax,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.total,
  });

  /// What the line's tax was charged on: [total] less [tax].
  final double taxable;

  /// Amount the discount took off, for the `discount_amount` column.
  final double discount;

  /// Tax *contained in* [total], for the `tax_amount` column.
  final double tax;

  /// Central share of [tax], or 0 when the supply is inter-state.
  final double cgst;

  /// State share of [tax], or 0 when the supply is inter-state.
  final double sgst;

  /// Integrated tax, or 0 when the supply is intra-state.
  final double igst;

  /// The price the customer pays: quantity x rate, less the discount.
  final double total;
}

/// The totals a sale document itself stores.
class SaleDocumentTotals {
  /// Creates document totals.
  const SaleDocumentTotals({
    required this.subTotal,
    required this.discountTotal,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// Sum of the lines' taxable values: `grandTotal - taxTotal`.
  final double subTotal;

  /// Sum of the lines' discounts.
  final double discountTotal;

  /// Sum of the tax extracted from the lines.
  final double taxTotal;

  /// Sum of the lines' totals: what the customer is charged.
  final double grandTotal;
}

/// A basket priced: every line's own totals, and the document's.
///
/// Both halves come out of one walk of the lines ([SaleTotals.price]), so a widget
/// showing the basket and the write sending it cannot describe two different bills -
/// a disagreement there is a receipt that differs from the amount just taken.
class SalePricedBasket {
  /// Creates a priced basket.
  const SalePricedBasket({required this.lines, required this.totals});

  /// Every line's totals, in cart order, each carrying its share of a bill-level
  /// discount when there is one.
  final List<SaleLineTotals> lines;

  /// The document's totals: the sums of [lines].
  final SaleDocumentTotals totals;
}

/// Line and document totals for a sale, and the pricing rules the server applies.
///
/// The refusals are here rather than in the screen because they are pricing rules
/// rather than presentation: each returns the sentence to show, or `null` when the
/// figure is acceptable. They mirror `checkout_sale()`'s own checks, so the counter
/// refuses a line for the same reason the server would, with the same words.
abstract final class SaleTotals {
  /// What a line's discount takes off its gross value.
  static double discountAmount({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => PurchaseTotals.round2(qty * rate * discountPercent / 100);

  /// The price a line is charged at: quantity x rate, less its discount.
  static double lineTotal({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => PurchaseTotals.round2(
    qty * rate -
        discountAmount(qty: qty, rate: rate, discountPercent: discountPercent),
  );

  /// The value a tax-inclusive [total] carries, at [gstPercent].
  ///
  /// The tax is *extracted*, not added (D-075): ₹105 at 5% is ₹100 plus ₹5, so
  /// this divides rather than multiplying. A slab of zero - or a type that charges
  /// no tax, whose line is priced at zero - leaves the total as its own taxable
  /// value.
  static double taxableFromInclusive({
    required double total,
    required double gstPercent,
  }) => gstPercent > 0
      ? PurchaseTotals.round2(total / (1 + gstPercent / 100))
      : PurchaseTotals.round2(total);

  /// The tax contained in a tax-inclusive [total], at [gstPercent].
  ///
  /// The remainder rather than its own division, so the two figures always add back
  /// to the total the customer paid - the same rule the two tax heads follow.
  static double taxFromInclusive({
    required double total,
    required double gstPercent,
  }) => PurchaseTotals.round2(
    total - taxableFromInclusive(total: total, gstPercent: gstPercent),
  );

  /// The full breakdown of one cart line, on [saleType]'s basis, with
  /// [discountShare] - this line's share of a bill-level discount - taken off
  /// alongside its own.
  ///
  /// What a line may carry is the type's business, and this applies the type as the
  /// server applies it rather than trusting what the cart happens to hold: a package
  /// or transfer line is computed with no discount, and a transfer line with no tax.
  /// A line that *does* carry one the type forbids is refused by [discountRefusal]
  /// before it is sent - the server refuses it too, and would not silently price it
  /// at zero.
  ///
  /// [discountShare] is required rather than defaulted, deliberately: a caller that
  /// forgot a bill-level discount would silently price a bill the server would not
  /// store, and a required parameter is the one place that mistake is caught before a
  /// customer sees it. Pass 0 when the bill carries none, or the line's own share from
  /// [billDiscountShares].
  static SaleLineTotals forLine(
    SaleCartLine line, {
    required TaxSplit split,
    required SaleType saleType,
    required double discountShare,
  }) {
    final gross = PurchaseTotals.round2(line.qty * line.rate);
    final discount = PurchaseTotals.round2(
      _ownDiscount(line, saleType: saleType) + discountShare,
    );
    final total = PurchaseTotals.round2(gross - discount);
    final slab = saleType.chargesGst ? line.gstPercent : 0.0;

    final taxableValue = taxableFromInclusive(total: total, gstPercent: slab);
    final taxValue = taxFromInclusive(total: total, gstPercent: slab);

    // The second half is the difference rather than its own division, so the two
    // halves always add back to the tax: rounding 0.01 in half twice gives 0.01
    // twice, which would charge a paisa that was never due.
    final (cgst, sgst, igst) = switch (split) {
      TaxSplit.intraState => () {
        final half = PurchaseTotals.round2(taxValue / 2);
        return (half, PurchaseTotals.round2(taxValue - half), 0.0);
      }(),
      TaxSplit.interState => (0.0, 0.0, taxValue),
    };

    return SaleLineTotals(
      taxable: taxableValue,
      discount: discount,
      tax: taxValue,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      total: total,
    );
  }

  /// The document totals for [lines], on [saleType]'s basis, with [billDiscount]
  /// shared across them.
  ///
  /// A thin face on [price] for callers that want only the header - the counter shows
  /// both halves, and the write sends both.
  static SaleDocumentTotals forLines(
    List<SaleCartLine> lines, {
    required TaxSplit split,
    required SaleType saleType,
    required double billDiscount,
  }) => price(
    lines,
    split: split,
    saleType: saleType,
    billDiscount: billDiscount,
  ).totals;

  /// [lines] priced as a document: each line's totals, and the sums of them.
  ///
  /// The one walk that works out a bill-level discount, and the reason both halves come
  /// back together: the counter's preview and the payload it writes read the same
  /// figures rather than each deriving their own.
  static SalePricedBasket price(
    List<SaleCartLine> lines, {
    required TaxSplit split,
    required SaleType saleType,
    required double billDiscount,
  }) {
    final shares = billDiscountShares(
      lines,
      saleType: saleType,
      billDiscount: billDiscount,
    );

    final lineTotals = <SaleLineTotals>[
      for (var index = 0; index < lines.length; index++)
        forLine(
          lines[index],
          split: split,
          saleType: saleType,
          discountShare: shares[index],
        ),
    ];

    var subTotal = 0.0;
    var discountTotal = 0.0;
    var taxTotal = 0.0;
    var grandTotal = 0.0;

    for (final totals in lineTotals) {
      subTotal += totals.taxable;
      discountTotal += totals.discount;
      taxTotal += totals.tax;
      grandTotal += totals.total;
    }

    return SalePricedBasket(
      lines: lineTotals,
      totals: SaleDocumentTotals(
        subTotal: PurchaseTotals.round2(subTotal),
        discountTotal: PurchaseTotals.round2(discountTotal),
        taxTotal: PurchaseTotals.round2(taxTotal),
        grandTotal: PurchaseTotals.round2(grandTotal),
      ),
    );
  }

  /// What a line's own percentage discount takes off it, or 0 when its type has none.
  static double _ownDiscount(SaleCartLine line, {required SaleType saleType}) =>
      saleType.hasDiscount
      ? discountAmount(
          qty: line.qty,
          rate: line.rate,
          discountPercent: line.discountPercent,
        )
      : 0.0;

  /// What a line comes to before ANY bill-level discount: `quantity x rate` less its
  /// own percentage discount.
  ///
  /// The figure the server distributes the bill's discount in proportion to - its
  /// `sale_items.total_amount` at the moment the lines have been priced and the bill's
  /// discount has not.
  static double lineGross(SaleCartLine line, {required SaleType saleType}) =>
      PurchaseTotals.round2(
        line.qty * line.rate - _ownDiscount(line, saleType: saleType),
      );

  /// The bill's tax-inclusive total **before** the bill-level discount: the sum of the
  /// lines' own totals.
  ///
  /// The server takes D-071's 10% cap on this figure (migration 00042), so the counter
  /// refuses on the same number rather than on a total the discount has already moved.
  static double billGross(
    List<SaleCartLine> lines, {
    required SaleType saleType,
  }) {
    var gross = 0.0;
    for (final line in lines) {
      gross += lineGross(line, saleType: saleType);
    }
    return PurchaseTotals.round2(gross);
  }

  /// Each line's share of a bill-level discount of [billDiscount], in cart order.
  ///
  /// The server's own rule (migration 00042): a share in proportion to each line's own
  /// total, and the **last line takes the rounding remainder**, so the shares add back
  /// to the rupee figure the counter typed instead of to something a paisa short of it.
  ///
  /// All zeros when there is nothing to share, or when the type has no discount concept
  /// at all - a package or transfer bill is priced from cost and is refused a discount
  /// outright ([billDiscountRefusal]).
  static List<double> billDiscountShares(
    List<SaleCartLine> lines, {
    required SaleType saleType,
    required double billDiscount,
  }) {
    if (billDiscount == 0 || !saleType.hasDiscount || lines.isEmpty) {
      return List<double>.filled(lines.length, 0);
    }

    final gross = billGross(lines, saleType: saleType);
    if (gross <= 0) {
      return List<double>.filled(lines.length, 0);
    }

    final shares = <double>[];
    var shared = 0.0;

    for (var index = 0; index < lines.length; index++) {
      final isLast = index == lines.length - 1;
      final share = isLast
          // Whatever the shares above left over. This is what makes them add back to
          // the figure the counter entered rather than to something a paisa short of it.
          ? PurchaseTotals.round2(billDiscount - shared)
          : PurchaseTotals.round2(
              lineGross(lines[index], saleType: saleType) *
                  billDiscount /
                  gross,
            );
      shared = PurchaseTotals.round2(shared + share);
      shares.add(share);
    }

    return shares;
  }

  /// The retail price of one unit, as `checkout_sale()` resolves it.
  ///
  /// The caller's own rate when there is one, else the batch's counter price, else
  /// its MRP - so a product that was never given a counter price is still billable.
  static double retailRate({
    required double sellingRate,
    required double mrp,
    double? rate,
  }) {
    if (rate != null && rate > 0) {
      return PurchaseTotals.round2(rate);
    }
    return sellingRate > 0 ? sellingRate : mrp;
  }

  /// The price of one package unit: cost plus the pharmacy's markup (D-070).
  ///
  /// The **batch's purchase rate** deliberately, not the landed cost. [markupPercent]
  /// may be 0, which is a real configured deal (D-068's "0% is a value, not an
  /// absence") and multiplies to the purchase rate itself.
  static double packageRate({
    required double purchaseRate,
    required double markupPercent,
  }) => PurchaseTotals.round2(purchaseRate * (1 + markupPercent / 100));

  /// The price of one transferred unit: the batch's purchase rate, no markup.
  static double transferRate({required double purchaseRate}) =>
      PurchaseTotals.round2(purchaseRate);

  /// Why a package sale cannot be priced, or `null` when it can.
  ///
  /// `null` markup means nobody has configured the pharmacy's markup, and the sane
  /// answer is to refuse rather than to price at an invented percentage - the same
  /// rule the server applies, in the server's own words.
  static String? packageMarkupRefusal({required double? markupPercent}) =>
      markupPercent == null
      ? 'This pharmacy has no package markup configured, so a package cannot be '
            'priced: set the package markup percentage first.'
      : null;

  /// Why a discount cannot be applied, or `null` when it can.
  ///
  /// Two rules, both the server's: a package or transfer sale has no discount
  /// concept at all, and a pharmacy sale is capped at 10% - above which the owner's
  /// approval is required. That approval now EXISTS server-side (migration 00043 built
  /// `approval_requests` and wired the cap to it), but **the counter cannot yet ask for
  /// one** - that is Phase 6.5c chunk 2 - so the cap is still a real ceiling here, and
  /// the sentence says which of the two is missing rather than claiming the workflow
  /// does not exist. **At exactly 10% the sale proceeds.**
  static String? discountRefusal({
    required SaleType saleType,
    required double discountPercent,
  }) {
    if (discountPercent < 0 || discountPercent > 100) {
      return 'A discount percent must be between 0 and 100.';
    }
    if (discountPercent == 0) {
      return null;
    }
    if (!saleType.hasDiscount) {
      return 'A ${saleType.label.toLowerCase()} sale has no discount.';
    }
    if (discountPercent > 10) {
      return 'A discount above 10% needs the owner\u2019s approval, and the '
          'counter cannot request one yet - bill at 10% or less.';
    }
    return null;
  }

  /// Why a bill-level discount cannot be applied, or `null` when it can.
  ///
  /// The server's own rules, in the server's own order (migration 00042), because the
  /// counter refuses on the figure the server refuses on rather than one round trip
  /// later:
  ///
  ///  * never negative;
  ///  * nothing at all on a package or transfer bill, which has no discount concept;
  ///  * never larger than the bill;
  ///  * never above 10% of the bill's tax-inclusive total ([billGross] - the total
  ///    BEFORE this discount). Above that the owner's approval is required. Migration
  ///    00043 built the mechanism and wired the cap to it, so the approval is real and
  ///    the sale can carry it - but **the counter cannot ask for one until Phase 6.5c
  ///    chunk 2**, so the cap is still a ceiling at the till and the sentence names the
  ///    half that is missing - and **at exactly 10% the sale proceeds**.
  static String? billDiscountRefusal({
    required SaleType saleType,
    required double billDiscount,
    required double billGross,
  }) {
    if (billDiscount < 0) {
      return 'A discount cannot be negative.';
    }
    if (billDiscount == 0) {
      return null;
    }
    if (!saleType.hasDiscount) {
      return 'A ${saleType.label.toLowerCase()} sale has no discount.';
    }
    if (billDiscount > billGross) {
      return 'The discount of ${billDiscount.toStringAsFixed(2)} is larger than '
          'the bill\u2019s ${billGross.toStringAsFixed(2)}.';
    }
    if (billDiscount > billGross * 0.10) {
      return 'A discount above 10% needs the owner\u2019s approval, and the '
          'counter cannot request one yet - bill at 10% or less.';
    }
    return null;
  }

  /// Why a rate cannot be charged, or `null` when it can.
  ///
  /// MRP is a **ceiling** on a retail rate, which is the rule that stops a counter
  /// billing more than the price printed on the box. The server refuses the same
  /// case in the same words, naming the product.
  static String? rateRefusal({
    required SaleType saleType,
    required double rate,
    required double mrp,
    required String productName,
  }) {
    if (rate <= 0) {
      return 'Cannot price $productName - it has no rate and no MRP.';
    }
    if (saleType.isPharmacySale && mrp > 0 && rate > mrp) {
      return 'The rate for $productName is above its MRP of ${mrp.toStringAsFixed(2)}.';
    }
    return null;
  }

  /// What a sale of [total] may record as paid, given a tender of [tendered].
  ///
  /// The change a cashier hands back is not revenue, and `checkout_sale()` refuses
  /// a sale paid beyond its total (the `sales_payment_check` trigger). Clamping
  /// here means the counter can take a ₹500 note for a ₹217 bill without the
  /// write being refused: the sale records 217, and the 283 is change.
  static double recordablePaid({
    required double tendered,
    required double total,
  }) {
    if (tendered <= 0 || total <= 0) {
      return 0;
    }
    return tendered > total
        ? PurchaseTotals.round2(total)
        : PurchaseTotals.round2(tendered);
  }

  /// The change owed on a tender, which is never negative.
  static double changeFor({required double tendered, required double total}) {
    final change = PurchaseTotals.round2(tendered - total);
    return change > 0 ? change : 0;
  }

  /// The raw tender for a bill of [grandTotal], whether or not one was typed.
  ///
  /// The figure the **change** is worked out from; the figure that gets stored is
  /// `PosCart.paidFor`, which clamps it. No tender and a mode that settles at the
  /// counter means the exact amount was handed over; no tender and credit means nothing
  /// was. Shared with the confirmation step so the change the counter shows and the
  /// change its dialog shows cannot be worked out two different ways.
  static double tenderedFor({
    required double grandTotal,
    required double tendered,
    required bool isOnAccount,
  }) => tendered > 0 ? tendered : (isOnAccount ? 0 : grandTotal);

  /// Whether the figures the counter showed are the ones the server stored.
  ///
  /// The client computes on the server's own basis (D-075) and the server recomputes
  /// from its own reading of the slabs, so agreement is the ordinary case - and it is
  /// still worth asking, because a disagreement means the receipt the customer is
  /// handed differs from the amount the operator just took. Compared **exactly**:
  /// both sides are whole paise, so a tolerance here would swallow the one-paisa
  /// divergence that is exactly the defect worth naming.
  static bool matchesStored({
    required SaleDocumentTotals shown,
    required Sale stored,
  }) =>
      shown.grandTotal == stored.grandTotal &&
      shown.taxTotal == stored.taxTotal &&
      shown.subTotal == stored.subTotal;
}
