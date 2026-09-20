/// What each of the four sale types needs before it can be sent.
///
/// The server validates every one of these again, and refuses in its own words
/// (migration 00036). This exists so the counter meets the same refusal *before*
/// the write, next to the field that is missing, rather than as a server error one
/// round trip later - and so the rules are testable without a till.
///
/// It is deliberately a **list of refusals** rather than a form validator per
/// field: what is required depends on the type, and several rules are about the
/// document rather than any one input (a transfer needs a source, a destination and
/// a reason, and its source and destination must differ).
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/data/sale_totals.dart';

/// Why a basket cannot be sent as it stands, or `null` when it can.
///
/// [packageMarkupPercent] is the pharmacy's configured markup (D-070): a package
/// sale is refused while nobody has set one, because pricing it would mean
/// inventing a percentage. Everything else it needs is read off the cart - including
/// whether any line is a Schedule H, H1, X or narcotic medicine, which is what makes
/// a prescriber's name mandatory (D-072).
String? saleRefusal({required PosCart cart, double? packageMarkupPercent}) {
  for (final line in cart.lines) {
    final refusal = SaleTotals.discountRefusal(
      saleType: cart.saleType,
      discountPercent: line.discountPercent,
    );
    if (refusal != null) {
      return refusal;
    }
    final rateRefusal = SaleTotals.rateRefusal(
      saleType: cart.saleType,
      rate: line.rate,
      mrp: line.mrp,
      productName: line.productName,
    );
    if (rateRefusal != null) {
      return rateRefusal;
    }
  }

  switch (cart.saleType) {
    case SaleType.counter:
      final identity = _patientRefusal(cart);
      if (identity != null) {
        return identity;
      }

    case SaleType.ipdAdmission:
      final identity = _patientRefusal(cart);
      if (identity != null) {
        return identity;
      }
      if (cart.admissionId == null && _blank(cart.hospitalReference)) {
        return 'An IPD sale needs the hospital\u2019s admission number, or a '
            'chosen admission.';
      }
      if (_blank(cart.doctorName)) {
        return 'An IPD sale needs the treating doctor.';
      }

    case SaleType.package:
      final markup = SaleTotals.packageMarkupRefusal(
        markupPercent: packageMarkupPercent,
      );
      if (markup != null) {
        return markup;
      }
      if (_blank(cart.customerId)) {
        return 'A package sale needs the hospital or account being billed.';
      }
      if (_blank(cart.patientName)) {
        return 'A package bill needs the patient\u2019s name.';
      }
      if (_blank(cart.patientMobile)) {
        return 'A package bill needs the patient\u2019s mobile number.';
      }
      if (_blank(cart.hospitalReference)) {
        return 'A package bill needs the package or case reference.';
      }

    case SaleType.transfer:
      if (_blank(cart.fromLocation) || _blank(cart.toLocation)) {
        return 'A transfer needs a source and a destination.';
      }
      if (cart.fromLocation!.trim() == cart.toLocation!.trim()) {
        return 'A transfer\u2019s source and destination cannot be the same.';
      }
      if (_blank(cart.transferReason)) {
        return 'A transfer needs a reason.';
      }
  }

  // The prescriber rule is about a line rather than the type: any Schedule H, H1,
  // X or narcotic medicine makes the prescriber's name mandatory on a pharmacy
  // sale (D-072). A package sale is the hospital buying, so it is exempt.
  final hasControlledLine = cart.lines.any(
    (line) => line.scheduleType.requiresPrescription,
  );
  if (hasControlledLine &&
      cart.saleType.isPharmacySale &&
      _blank(cart.doctorName)) {
    return 'A Schedule H/H1/X line needs the prescriber\u2019s name.';
  }

  return null;
}

/// Why the bill cannot be pinned to a patient, or `null` when it can.
///
/// The patient's own row is required rather than a typed name, because the server
/// snapshots the name and mobile **from the row** and a pharmacy sale needs both:
/// a patient with no number on file is refused there, so it is refused here where
/// the operator can see which patient it is.
String? _patientRefusal(PosCart cart) {
  if (_blank(cart.customerId)) {
    return 'A pharmacy sale needs a patient: select or register one before the '
        'medicines.';
  }
  if (_blank(cart.patientName)) {
    return 'That patient has no name on file.';
  }
  if (_blank(cart.patientMobile)) {
    return 'That patient has no mobile number on file, and a pharmacy sale needs '
        'one.';
  }
  return null;
}

/// Whether [value] holds nothing but whitespace, or nothing at all.
bool _blank(String? value) => value == null || value.trim().isEmpty;
