/// The one place that knows which cached reads the owner's answer feeds.
///
/// Deciding a request RUNS its write, so one answer moves far more than the queue: the document it
/// wrote is out of date wherever it is on screen, and so is every cached read that document feeds.
/// Three callers can produce that state - the owner approving a receipt, a return or a product, and
/// the counter's own screen when a discount is raised - so the list lives here rather than being
/// repeated, which is the shape `refreshStockReaders()` (D-021) settled for the shelf.
library;

import 'package:app/features/approvals/application/approvals_controller.dart';
import 'package:app/features/customers/application/customers_detail_controller.dart';
import 'package:app/features/customers/application/customers_list_controller.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/products/application/products_detail_controller.dart';
import 'package:app/features/products/application/products_list_controller.dart';
import 'package:app/features/purchase/application/purchase_form_controller.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:app/features/sales/application/sales_list_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

/// Drops every cached read that the owner's answer to a request can move.
///
/// Three groups, and all of them, because **which of them actually changed is not knowable from the
/// answer alone**: the payload IS the document for most action types, a `discount_above_limit` writes
/// no document at all, and a receipt moves stock in a way no reader can predict. So they are dropped
/// together - the rule `refreshStockReaders()` records for the shelf - and a read with nothing mounted
/// costs nothing, which is what makes the coarse list the cheap one rather than the lazy one.
///
///   1. **The rail's own three readers.** The owner's queue
///      ([pendingApprovalsProvider]), the counter's label on a bill it is holding
///      ([approvalRequestProvider] - a bill it has asked about, whose answer it is waiting to read),
///      and every document's *waiting for the owner* card ([approvalForTargetProvider]). A card left
///      showing an ask the owner has just answered would promise an approval that no longer exists,
///      and an answered bill left reading *waiting* would do the same thing on the counter's screen.
///   2. **The documents a decision can write** - a purchase, a product, a bill, a patient master -
///      and the shelf, which is why [refreshStockReaders] is called here too: three of the action
///      types move stock, and the inventory module already owns the contract for that (D-021).
///   3. **The lists those documents appear in.** They are `keepAlive`, so unlike a detail screen they
///      do NOT re-read when they are re-entered: a purchase list that still shows a document as
///      *pending approval* after the owner has received it is the same defect one screen further out.
///
/// It is deliberately not a switch over the action type or the target table. The rail has gained a
/// whole family of action types per chunk, and a switch would need a new arm - and a memory of this
/// file - every time it does; a list of the READERS, which only grows when a screen is added, does
/// not. Each family is invalidated WHOLE rather than by id: `invalidate` takes a provider or a
/// family, so every mounted instance re-reads and nothing here has to guess which row is on screen.
void refreshApprovalReaders(Ref ref) {
  ref
    // 1. The rail's own readers.
    ..invalidate(pendingApprovalsProvider)
    ..invalidate(approvalRequestProvider)
    ..invalidate(approvalForTargetProvider)
    // 2. The documents an answer can write, detail by detail...
    ..invalidate(purchaseWithLinesProvider)
    ..invalidate(productDetailControllerProvider)
    ..invalidate(saleDetailProvider)
    ..invalidate(customerDetailControllerProvider)
    // ...3. and the lists they appear in, which are keepAlive and would not re-read on entry.
    ..invalidate(purchasesListControllerProvider)
    ..invalidate(productsListControllerProvider)
    ..invalidate(salesListControllerProvider)
    ..invalidate(customersListControllerProvider);

  // A receipt, a return and a stock adjustment all move the shelf, and which readers that feeds is
  // the inventory module's own contract rather than a second list kept here.
  refreshStockReaders(ref);
}
