/// The one place the app says that a write went to the owner instead of landing.
///
/// Phase 6.5c gates every document but a sale bill for anybody but the owner, and the difference
/// between "saved" and "sent" is not a detail: a sent return has moved no stock and a sent GRN has
/// put nothing in stock. Three sentences and one shower, so the screens that write a gated document
/// cannot each phrase the same fact differently from what the server actually did.
///
/// Lives in the approvals feature because the owner's rail is what these sentences are about - a
/// purchase screen importing the returns feature's copy, or the other way round, would be the wrong
/// dependency for one string.
library;

import 'package:flutter/material.dart';

/// What a writer is told when the document was STAGED: it exists, and nothing has posted.
const String sentToOwnerMessage =
    'Sent to the owner. Nothing posts until he approves it.';

/// What a writer is told when the whole document was only REQUESTED: nothing was written at all.
///
/// Deliberately not the sentence above. A staged GRN exists as a document whose stock and ledger
/// have not moved; a requested return has no row anywhere, so "nothing has been recorded" is the
/// thing its writer needs to know - their work is not in the returns list, it is in the owner's
/// queue.
const String sentForApprovalMessage =
    'Sent to the owner. Nothing has been recorded until he approves it.';

/// What a cancellation's asker is told.
///
/// A cancellation moves nothing either way, so the thing its asker needs to know is that the
/// document has not moved - which is why this is not the staged sentence above.
const String sentToOwnerCancellationMessage =
    'Sent to the owner. The document stays as it is until he answers.';

/// Shows [message] as a SnackBar.
///
/// Called before a screen navigates away, so the sentence survives the `go`: the messenger
/// belongs to the app rather than to the route being left.
void showSentToOwnerNotice(BuildContext context, {required String message}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
