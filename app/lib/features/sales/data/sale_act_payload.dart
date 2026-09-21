/// The payloads the two sale acts take, built in one place.
///
/// A posted bill is written only by server-side functions since Phase 6.5c chunk 5d - `sales` and
/// `sale_items` take no write from a session at all - so the shape of what `cancel_sale()` and
/// `save_sale_identity()` are handed is part of this feature's contract rather than an
/// implementation detail of one repository method. It lives here where it can be read and tested on
/// its own, the way `purchase_payload.dart` and `product_payload.dart` do.
///
/// Two things about the edit are load-bearing:
///
///  * **It is the printed identity and nothing else.** The server holds the payload to a WHITELIST,
///    so sending a money column or a line is refused by name - and the refusal is what keeps a
///    correction that changes what the customer owes on the sale-return path, which the owner also
///    approves.
///  * **`null` is a value, and omitting a key is not.** A field the caller does not name keeps what
///    the bill already says; a field sent as an explicit empty string clears it. The builder
///    therefore only includes the keys it was given a value for.
library;

/// Builds the documents the two sale acts write.
abstract final class SaleActPayload {
  /// A cancellation. The status is the whole act, so the document is the bill's id.
  static Map<String, dynamic> cancel({
    required String saleId,
    String? reason,
    String? idempotencyKey,
  }) => <String, dynamic>{
    'sale_id': saleId,
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    'idempotency_key': idempotencyKey,
  };

  /// A correction of the bill's printed identity.
  ///
  /// Only the keys actually supplied travel: an absent key means "leave this alone" on the server,
  /// so a sheet that changed one field sends one field. Both halves of the patient pair are sent
  /// together by the caller, because a pharmacy bill carries the name and the number together or
  /// neither - the server refuses the half pair in words rather than raising at the constraint.
  static Map<String, dynamic> editIdentity({
    required String saleId,
    String? patientName,
    String? patientMobile,
    String? patientAddress,
    String? doctorName,
    String? hospitalReference,
  }) {
    final payload = <String, dynamic>{'sale_id': saleId};

    void put(String key, String? value) {
      if (value != null) {
        payload[key] = value.trim();
      }
    }

    put('patient_name', patientName);
    put('patient_mobile', patientMobile);
    put('patient_address', patientAddress);
    put('doctor_name', doctorName);
    put('hospital_reference', hospitalReference);

    return payload;
  }
}
