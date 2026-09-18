/// Freezed/JSON model for the writable half of a customer: what a form collects.
library;

import 'package:app/data/models/customer.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'customer_draft.freezed.dart';
part 'customer_draft.g.dart';

/// The fields a create/edit form owns.
///
/// Kept separate from [Customer] because a form cannot invent `id`, `pharmacyId`
/// or the timestamps, and because the write payload should be explicit rather
/// than "whatever the entity happens to carry".
///
/// Unlike the entity models, this one serialises nulls: a form that clears an
/// optional field (removing a GSTIN, say) has to send an explicit null so the
/// column is cleared, not left at its previous value. That matters here more
/// than on a product: a stale GSTIN would quietly keep a walk-in customer on the
/// tax books.
@freezed
abstract class CustomerDraft with _$CustomerDraft {
  /// Creates an immutable [CustomerDraft].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory CustomerDraft({
    required String name,
    @Default(0) double openingBalance,
    @Default(0) int loyaltyPoints,
    @Default(true) bool isActive,
    String? phone,
    String? email,
    String? address,
    String? gstin,
  }) = _CustomerDraft;

  /// Decodes a draft from JSON (used by tests and for round-trips).
  factory CustomerDraft.fromJson(Map<String, dynamic> json) =>
      _$CustomerDraftFromJson(json);

  /// Seeds a draft from an existing customer, for the edit form.
  factory CustomerDraft.fromCustomer(Customer customer) => CustomerDraft(
    name: customer.name,
    openingBalance: customer.openingBalance,
    loyaltyPoints: customer.loyaltyPoints,
    isActive: customer.isActive,
    phone: customer.phone,
    email: customer.email,
    address: customer.address,
    gstin: customer.gstin,
  );
}
