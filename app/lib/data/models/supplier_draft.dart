/// Freezed/JSON model for the writable half of a supplier: what a form collects.
library;

import 'package:app/data/models/supplier.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'supplier_draft.freezed.dart';
part 'supplier_draft.g.dart';

/// The fields a create/edit form owns.
///
/// Kept separate from [Supplier] because a form cannot invent `id`,
/// `pharmacyId` or the timestamps, and because the write payload should be
/// explicit rather than "whatever the entity happens to carry".
///
/// Unlike the entity models, this one serialises nulls: a form that clears an
/// optional field (removing a GSTIN, say) has to send an explicit null so the
/// column is cleared, not left at its previous value.
@freezed
abstract class SupplierDraft with _$SupplierDraft {
  /// Creates an immutable [SupplierDraft].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SupplierDraft({
    required String name,
    @Default(0) int creditDays,
    @Default(0) double openingBalance,
    @Default(true) bool isActive,
    String? gstin,
    String? drugLicenseNo,
    String? contactPerson,
    String? phone,
    String? email,
    String? address,
    String? city,
    String? state,
    String? pincode,
  }) = _SupplierDraft;

  /// Decodes a draft from JSON (used by tests and for round-trips).
  factory SupplierDraft.fromJson(Map<String, dynamic> json) =>
      _$SupplierDraftFromJson(json);

  /// Seeds a draft from an existing supplier, for the edit form.
  factory SupplierDraft.fromSupplier(Supplier supplier) => SupplierDraft(
    name: supplier.name,
    creditDays: supplier.creditDays,
    openingBalance: supplier.openingBalance,
    isActive: supplier.isActive,
    gstin: supplier.gstin,
    drugLicenseNo: supplier.drugLicenseNo,
    contactPerson: supplier.contactPerson,
    phone: supplier.phone,
    email: supplier.email,
    address: supplier.address,
    city: supplier.city,
    state: supplier.state,
    pincode: supplier.pincode,
  );
}
