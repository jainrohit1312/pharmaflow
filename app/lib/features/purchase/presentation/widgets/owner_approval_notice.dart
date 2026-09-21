/// Tells the person who just saved a purchase where the write actually went.
///
/// Phase 6.5c put purchases behind the owner's approval, and the difference between "saved"
/// and "sent" is not a detail: a member of staff's receipt has **posted nothing**, so the
/// medicines are not in stock, and a silence after tapping Save would read as a receipt.
///
/// A purchase is the one gated document whose staged state is a *row*, so this file's job is
/// reading that state; the sentences themselves live with the rail, in
/// `features/approvals/presentation/sent_to_owner.dart`, so no two features can phrase the
/// same fact differently.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/features/approvals/presentation/sent_to_owner.dart';
import 'package:flutter/material.dart';

/// Whether a write's answer means the document went to the owner rather than landing.
///
/// `pendingApproval` says so outright: the server staged the document and raised the ask.
/// A **cancellation** does not, and that is not an oversight - the server deliberately moves
/// nothing until the owner answers, so the document comes back exactly as it was and the
/// row itself cannot say which of the two happened. What is left is who asked, which is the
/// same reading the counter uses for the discount cap (`sale_requirements.dart`): the client
/// knows who is signed in so it can *say the right thing*, while the server remains the one
/// that decides what actually happens - and the owner's own cancellation closes any ask his
/// staff had raised rather than raising one.
bool wentToOwner({
  required Purchase document,
  required bool isOwner,
  required bool isCancellation,
}) => document.status.isPendingApproval || (isCancellation && !isOwner);

/// Shows the right sentence when [wentToOwner], and shows nothing otherwise.
///
/// Called after a write, before the screen navigates, so the message survives the `go` -
/// the messenger belongs to the app rather than to the route being left.
void reportSentToOwner(
  BuildContext context, {
  required Purchase document,
  required bool isOwner,
  bool isCancellation = false,
}) {
  if (!wentToOwner(
    document: document,
    isOwner: isOwner,
    isCancellation: isCancellation,
  )) {
    return;
  }

  showSentToOwnerNotice(
    context,
    message: isCancellation && !document.status.isPendingApproval
        ? sentToOwnerCancellationMessage
        : sentToOwnerMessage,
  );
}
