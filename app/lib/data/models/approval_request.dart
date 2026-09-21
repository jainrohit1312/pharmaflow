/// Freezed/JSON model for the `approval_requests` table plus the two enums
/// migration 00043 introduced.
///
/// The table is the owner-approval RBAC's own record: one row per thing he has been
/// asked to allow, carrying the `payload` the action needs and the two states. A
/// member of staff reads only his own rows and the owner reads every row in his
/// pharmacy - that scoping is the table's RLS policy, not this model's business.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'approval_request.freezed.dart';
part 'approval_request.g.dart';

/// What a request is asking the owner to allow.
///
/// The list is the owner's own policy (2026-09-21). Only the action types whose chunk
/// has landed can be asked for at all - `request_approval()` refuses the rest - so a
/// row can only ever carry one of the implemented ones; [unknown] exists so an
/// unrecognised literal is *visible* rather than silently mistaken for something else.
enum ApprovalActionType {
  /// A discount above 10% of a bill (D-071). The first one built.
  discountAboveLimit,

  /// Creating a GRN.
  purchase,

  /// Changing an editable GRN.
  purchaseEdit,

  /// Cancelling a GRN.
  purchaseDelete,

  /// A purchase return.
  purchaseReturn,

  /// A sale return.
  saleReturn,

  /// Changing a posted sale.
  saleEdit,

  /// Cancelling a posted sale.
  saleCancel,

  /// An inventory adjustment.
  stockAdjustment,

  /// Adding a new product.
  productCreate,

  /// Editing a product or a batch.
  productEdit,

  /// Deleting a product.
  productDelete,

  /// Editing a customer's master record.
  customerEdit,

  /// Recording an expense.
  expenseCreate,

  /// Editing an expense.
  expenseEdit,

  /// Deleting an expense.
  expenseDelete,

  /// A literal this build does not know.
  unknown,
}

/// Parses a Postgres `approval_action_type` literal.
///
/// An unrecognised value is [ApprovalActionType.unknown] rather than a guess: showing a
/// request the owner cannot classify is honest, whereas treating it as a discount would
/// not be.
ApprovalActionType approvalActionTypeFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'discount_above_limit' => ApprovalActionType.discountAboveLimit,
      'purchase' => ApprovalActionType.purchase,
      'purchase_edit' => ApprovalActionType.purchaseEdit,
      'purchase_delete' => ApprovalActionType.purchaseDelete,
      'purchase_return' => ApprovalActionType.purchaseReturn,
      'sale_return' => ApprovalActionType.saleReturn,
      'sale_edit' => ApprovalActionType.saleEdit,
      'sale_cancel' => ApprovalActionType.saleCancel,
      'stock_adjustment' => ApprovalActionType.stockAdjustment,
      'product_create' => ApprovalActionType.productCreate,
      'product_edit' => ApprovalActionType.productEdit,
      'product_delete' => ApprovalActionType.productDelete,
      'customer_edit' => ApprovalActionType.customerEdit,
      'expense_create' => ApprovalActionType.expenseCreate,
      'expense_edit' => ApprovalActionType.expenseEdit,
      'expense_delete' => ApprovalActionType.expenseDelete,
      _ => ApprovalActionType.unknown,
    };

/// Maps [ApprovalActionType] to its Postgres literal and its label.
extension ApprovalActionTypeX on ApprovalActionType {
  /// The literal stored in the Postgres `approval_action_type` enum column.
  String get dbValue => switch (this) {
    ApprovalActionType.discountAboveLimit => 'discount_above_limit',
    ApprovalActionType.purchase => 'purchase',
    ApprovalActionType.purchaseEdit => 'purchase_edit',
    ApprovalActionType.purchaseDelete => 'purchase_delete',
    ApprovalActionType.purchaseReturn => 'purchase_return',
    ApprovalActionType.saleReturn => 'sale_return',
    ApprovalActionType.saleEdit => 'sale_edit',
    ApprovalActionType.saleCancel => 'sale_cancel',
    ApprovalActionType.stockAdjustment => 'stock_adjustment',
    ApprovalActionType.productCreate => 'product_create',
    ApprovalActionType.productEdit => 'product_edit',
    ApprovalActionType.productDelete => 'product_delete',
    ApprovalActionType.customerEdit => 'customer_edit',
    ApprovalActionType.expenseCreate => 'expense_create',
    ApprovalActionType.expenseEdit => 'expense_edit',
    ApprovalActionType.expenseDelete => 'expense_delete',
    ApprovalActionType.unknown => 'unknown',
  };

  /// What the owner's screen calls it.
  String get label => switch (this) {
    ApprovalActionType.discountAboveLimit => 'Discount above 10%',
    ApprovalActionType.purchase => 'Purchase',
    ApprovalActionType.purchaseEdit => 'Purchase edit',
    ApprovalActionType.purchaseDelete => 'Purchase cancellation',
    ApprovalActionType.purchaseReturn => 'Purchase return',
    ApprovalActionType.saleReturn => 'Sale return',
    ApprovalActionType.saleEdit => 'Sale edit',
    ApprovalActionType.saleCancel => 'Sale cancellation',
    ApprovalActionType.stockAdjustment => 'Stock adjustment',
    ApprovalActionType.productCreate => 'New product',
    ApprovalActionType.productEdit => 'Product edit',
    ApprovalActionType.productDelete => 'Product deletion',
    ApprovalActionType.customerEdit => 'Customer edit',
    ApprovalActionType.expenseCreate => 'Expense',
    ApprovalActionType.expenseEdit => 'Expense edit',
    ApprovalActionType.expenseDelete => 'Expense deletion',
    ApprovalActionType.unknown => 'Approval',
  };
}

/// Round-trips [ApprovalActionType] with the Postgres literal.
class ApprovalActionTypeConverter
    extends JsonConverter<ApprovalActionType, String?> {
  /// Creates the converter referenced by `@ApprovalActionTypeConverter()`.
  const ApprovalActionTypeConverter();

  /// Decodes the enum literal.
  @override
  ApprovalActionType fromJson(String? json) => approvalActionTypeFromDb(json);

  /// Emits the enum literal.
  @override
  String? toJson(ApprovalActionType object) => object.dbValue;
}

/// Where a request has got to.
enum ApprovalStatus {
  /// Waiting for the owner. The only state that can be decided.
  pending,

  /// The owner allowed it - which, for a discount, is what lets the bill quote it.
  approved,

  /// The owner refused it.
  rejected,
}

/// Parses a Postgres `approval_status` literal.
///
/// An unrecognised value falls back to [ApprovalStatus.pending], which is the state that
/// asks for attention: guessing `approved` would show a permission nobody gave.
ApprovalStatus approvalStatusFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'approved' => ApprovalStatus.approved,
      'rejected' => ApprovalStatus.rejected,
      _ => ApprovalStatus.pending,
    };

/// Maps [ApprovalStatus] to its Postgres literal and its label.
extension ApprovalStatusX on ApprovalStatus {
  /// The literal stored in the Postgres `approval_status` enum column.
  String get dbValue => switch (this) {
    ApprovalStatus.pending => 'pending',
    ApprovalStatus.approved => 'approved',
    ApprovalStatus.rejected => 'rejected',
  };

  /// What the UI calls it.
  String get label => switch (this) {
    ApprovalStatus.pending => 'Waiting for the owner',
    ApprovalStatus.approved => 'Approved',
    ApprovalStatus.rejected => 'Refused',
  };

  /// Whether the owner still has to answer it.
  bool get isPending => this == ApprovalStatus.pending;
}

/// Round-trips [ApprovalStatus] with the Postgres literal.
class ApprovalStatusConverter extends JsonConverter<ApprovalStatus, String?> {
  /// Creates the converter referenced by `@ApprovalStatusConverter()`.
  const ApprovalStatusConverter();

  /// Decodes the enum literal.
  @override
  ApprovalStatus fromJson(String? json) => approvalStatusFromDb(json);

  /// Emits the enum literal.
  @override
  String? toJson(ApprovalStatus object) => object.dbValue;
}

/// One `approval_requests` row.
///
/// `@JsonSerializable` sits on the factory constructor because Freezed forwards
/// constructor-level metadata onto the generated concrete class; on the class itself it
/// would be ignored (keys would stay camelCase).
@freezed
abstract class ApprovalRequest with _$ApprovalRequest {
  /// Creates an immutable request.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: false)
  const factory ApprovalRequest({
    required String id,
    required String pharmacyId,
    required String title,
    required DateTime requestedAt,
    @Default(ApprovalActionType.unknown)
    @ApprovalActionTypeConverter()
    ApprovalActionType actionType,
    @Default(ApprovalStatus.pending)
    @ApprovalStatusConverter()
    ApprovalStatus status,
    String? summary,
    @Default(<String, dynamic>{}) Map<String, dynamic> payload,
    String? targetTable,
    String? targetId,
    String? requestedBy,
    String? decidedBy,
    DateTime? decidedAt,
    String? decisionNote,
  }) = _ApprovalRequest;

  /// Decodes a snake_case Postgres/Supabase row into an [ApprovalRequest].
  factory ApprovalRequest.fromJson(Map<String, dynamic> json) =>
      _$ApprovalRequestFromJson(json);
}

/// The figures a request carries, read off its `payload`.
///
/// Typed accessors rather than a map lookup at each call site: the payload is jsonb and
/// the two figures a discount request must carry are what the owner reads AND what
/// `checkout_sale()` matches the bill against.
extension ApprovalRequestX on ApprovalRequest {
  /// The discount the request is about, when it is a discount request.
  double? get discountAmount =>
      (payload['discount_amount'] as num?)?.toDouble();

  /// The tax-inclusive bill that discount is taken off, on the same terms.
  double? get billGross => (payload['bill_gross'] as num?)?.toDouble();
}
