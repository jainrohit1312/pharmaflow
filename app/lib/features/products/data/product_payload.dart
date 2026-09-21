/// The payload `save_product()` takes, built in one place.
///
/// The product master is written by ONE server-side function (migration
/// `20260921000046`), because `products`, `product_batches` and `product_aliases` stopped taking
/// writes from a session at all: a gate that lived in the form would have been a suggestion. So the
/// shape of what that function is handed is part of this feature's contract rather than an
/// implementation detail of one repository method, and it lives here where it can be read and
/// tested on its own.
///
/// Four things about it are load-bearing:
///
///  * **The action type is not in the payload.** `save_product()` derives it - a payload with no
///    `product_id` is a `product_create`, one that deactivates an active product is a
///    `product_delete`, anything else is a `product_edit` - so a client cannot name a gentler act
///    than the change it is asking for, and there is no second place for the two to disagree.
///  * **The form's own columns are the document.** `create()` and `edit()` send
///    `ProductDraft.toJson()` verbatim, nulls included, because a form that clears an optional
///    field has to say so.
///  * **An alias is its OWN document.** The server refuses a payload that mixes the product's fields
///    with an alias act - one approval cannot carry two documents - so `alias()` and
///    `removeAlias()` send the product's id and nothing else.
///  * **`is_active` rides on the edit.** The form owns that switch, so a draft that flips it is the
///    payload that deactivates the product; `active()` exists for the detail screen's own toggle,
///    which changes nothing else.
library;

import 'package:app/data/models/product_draft.dart';

/// Builds the document `save_product()` writes.
abstract final class ProductPayload {
  /// A new product. The absence of `product_id` is what makes this a create.
  static Map<String, dynamic> create({
    required ProductDraft draft,
    String? idempotencyKey,
  }) => <String, dynamic>{...draft.toJson(), 'idempotency_key': idempotencyKey};

  /// An edit of a product that already exists.
  ///
  /// The whole draft travels, not a diff: the server applies the keys it is handed and leaves the
  /// rest alone, and an ask about this product is REFRESHED rather than stacked - so sending the
  /// complete form is what makes the later ask a revision of the earlier one instead of losing a
  /// change from it.
  static Map<String, dynamic> edit({
    required String productId,
    required ProductDraft draft,
  }) => <String, dynamic>{'product_id': productId, ...draft.toJson()};

  /// The active flag alone, for the detail screen's toggle.
  ///
  /// It is the same door: sending `false` for a product that is in use is the soft delete, and the
  /// server raises (or performs) a `product_delete` for it.
  static Map<String, dynamic> active({
    required String productId,
    required bool isActive,
  }) => <String, dynamic>{'product_id': productId, 'is_active': isActive};

  /// Records invoice text against a product.
  ///
  /// [supplierId] is omitted rather than sent as `null` when the supplier is not known: a null
  /// `supplier_id` is a pharmacy-wide alias and a value the database's own key treats as one (N-5),
  /// so both spellings mean the same row - but omitting it is the honest one for "no supplier".
  static Map<String, dynamic> alias({
    required String productId,
    required String rawName,
    String? supplierId,
  }) => <String, dynamic>{
    'product_id': productId,
    'alias': <String, dynamic>{
      'raw_name': rawName.trim(),
      'supplier_id': supplierId,
    },
  };

  /// Removes one recorded alias from a product.
  static Map<String, dynamic> removeAlias({
    required String productId,
    required String aliasId,
  }) => <String, dynamic>{'product_id': productId, 'remove_alias_id': aliasId};
}
