/// The owner's queue: everything his staff has asked to do.
///
/// One screen for both sides of the rail, because one read serves them: the table's RLS
/// policy gives the owner every pending request in his pharmacy and a member of staff
/// his own asks, so a cashier who reaches this screen sees what he is waiting on rather
/// than somebody else's business.
///
/// **Only the owner may decide**, and that is the server's rule rather than this
/// screen's - `decide_approval()` refuses anyone else. Nothing here offers a control the
/// server would refuse.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/data/models/approval_request.dart';
import 'package:app/features/approvals/application/approvals_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The approvals waiting for the owner.
class ApprovalsScreen extends ConsumerWidget {
  /// Creates the approvals screen.
  const ApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingApprovalsProvider);
    final isBusy = ref.watch(approvalActionsProvider).isLoading;

    return AppScaffold(
      title: 'Approvals',
      leading: const AppBackButton(
        location: Routes.settings,
        tooltip: 'Back to settings',
      ),
      body: pending.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              describeError(error),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        data: (requests) => requests.isEmpty
            ? const _NothingWaiting()
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: requests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) => _ApprovalCard(
                  request: requests[index],
                  isBusy: isBusy,
                  onDecide: ({required bool approve, String? note}) => ref
                      .read(approvalActionsProvider.notifier)
                      .decide(
                        id: requests[index].id,
                        approve: approve,
                        note: note,
                      ),
                ),
              ),
      ),
    );
  }
}

/// The empty state: nothing is waiting.
class _NothingWaiting extends StatelessWidget {
  const _NothingWaiting();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Nothing is waiting for an answer.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}

/// One request, what it would do, and the two answers.
class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.request,
    required this.isBusy,
    required this.onDecide,
  });

  /// The request being shown.
  final ApprovalRequest request;

  /// Whether a decision is already in flight.
  final bool isBusy;

  /// Called with the answer and an optional reason.
  ///
  /// Named rather than positional, because a bare positional `bool` at a call site reads
  /// as nothing at all.
  final void Function({required bool approve, String? note}) onDecide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final discount = request.discountAmount;
    final bill = request.billGross;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    request.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(request.actionType.label),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (request.summary case final summary?) ...<Widget>[
              const SizedBox(height: 8),
              Text(summary, style: theme.textTheme.bodyMedium),
            ],
            // The figures the owner is actually agreeing to, when he is agreeing to
            // money: `checkout_sale()` will match the bill against these, so showing
            // them here is showing the control itself.
            if (discount != null && bill != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                '${Formatters.currency(discount)} off a bill of '
                '${Formatters.currency(bill)}',
                style: theme.textTheme.bodyLarge,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Asked ${Formatters.dateTimeDdMmmYyyyHm(request.requestedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: AppButton.outlined(
                    label: 'Refuse',
                    icon: Icons.close,
                    onPressed: isBusy
                        ? null
                        : () => _ask(context, approve: false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppButton.primary(
                    label: 'Approve',
                    icon: Icons.check,
                    isLoading: isBusy,
                    onPressed: isBusy
                        ? null
                        : () => _ask(context, approve: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms one answer, with the optional reason the decision is recorded with.
  ///
  /// A refusal is the one a person has to act on, so the reason is offered for both and
  /// left optional: asking the owner to justify an approval is asking him to do work he
  /// did not ask for.
  Future<void> _ask(BuildContext context, {required bool approve}) async {
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _DecisionDialog(approve: approve),
    );
    if (note == null) {
      // Dismissed: no answer was given, which is not the same as refusing.
      return;
    }
    onDecide(approve: approve, note: note.trim().isEmpty ? null : note.trim());
  }
}

/// The confirmation, and the optional reason.
class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.approve});

  /// Whether this is an approval.
  final bool approve;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.approve ? 'Approve this?' : 'Refuse this?'),
    content: TextField(
      controller: _note,
      autofocus: true,
      maxLines: 2,
      decoration: const InputDecoration(
        labelText: 'Reason (optional)',
        hintText: 'What the person asking should know',
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(_note.text),
        child: Text(widget.approve ? 'Approve' : 'Refuse'),
      ),
    ],
  );
}
