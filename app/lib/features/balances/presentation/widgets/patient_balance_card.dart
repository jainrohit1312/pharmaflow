/// What the account says this patient owes, and what the pharmacy holds for them.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/account_balance.dart';
import 'package:app/features/balances/application/balances.dart';
import 'package:app/features/balances/presentation/widgets/account_figure.dart';
import 'package:app/features/balances/presentation/widgets/apply_deposit_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A patient's account, read from `patient_account()`.
///
/// Every figure is the server's own aggregate over the whole patient: **nothing here
/// sums rows**, and nothing recomputes the balance, so what this card says and what the
/// ledger describes cannot disagree (D-025).
///
/// It is **not** the same question as the ledger balance above it on the customer
/// screen. The ledger shows debit and credit entries; this shows what those entries mean
/// for settlement - billed, credited back, **applied**, and therefore outstanding - and
/// whether any money is being held that no bill has been applied to.
class PatientBalanceCard extends ConsumerWidget {
  /// Creates the card for [customerId].
  const PatientBalanceCard({required this.customerId, super.key});

  /// The patient to show.
  final String customerId;

  /// What the card is called wherever it appears.
  static const String title = 'Patient account';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final account = ref.watch(patientAccountProvider(customerId));

    // A refresh keeps showing the loaded account; only a first-load failure takes the
    // card over. Checked before `isLoading` for the same reason the bill screen does it:
    // a retry holds no value while it is in flight either.
    if (account.hasError && !account.hasValue) {
      return SectionCard(
        title: title,
        child: ErrorView(
          message: describeError(account.error!),
          onRetry: () => ref.invalidate(patientAccountProvider(customerId)),
        ),
      );
    }

    final value = account.value;
    if (value == null) {
      if (account.isLoading) {
        return const SectionCard(
          title: title,
          child: Text('Loading the account…'),
        );
      }
      // The server answers no rows for a customer who is not in this pharmacy - and for
      // any customer the pharmacy has never billed. Both are "no account yet" rather
      // than a failure.
      return const SectionCard(
        title: title,
        trailing: StatusBadge(label: 'No account yet'),
        child: Text(
          'Nothing has been billed to this customer yet. The account fills in as '
          'sales are billed and receipts are applied to them.',
        ),
      );
    }

    final inCredit = value.outstanding < 0;
    return SectionCard(
      title: title,
      trailing: StatusBadge(
        label: value.isSettled
            ? 'Settled'
            : (inCredit ? 'In credit' : 'Outstanding'),
        tone: value.isSettled
            ? BadgeTone.success
            : (inCredit ? BadgeTone.warning : BadgeTone.info),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccountFigure(
            label: inCredit ? 'Held for the patient' : 'Outstanding',
            value: Formatters.currency(value.outstanding),
            tone: value.isSettled ? null : theme.colorScheme.error,
            emphasis: theme.textTheme.titleMedium,
          ),
          AccountFigure(
            label: 'Billed',
            value: Formatters.currency(value.charges),
          ),
          if (value.returnsCredits != 0)
            AccountFigure(
              label: 'Credited back',
              value: '-${Formatters.currency(value.returnsCredits)}',
            ),
          AccountFigure(
            label: 'Receipts applied',
            value: Formatters.currency(value.allocated),
          ),
          if (value.hasDeposit)
            AccountFigure(
              label: 'Held unapplied',
              value: Formatters.currency(value.unallocatedDeposits),
              tone: theme.colorScheme.error,
            ),
          const SizedBox(height: 8),
          Text(
            'Aggregated by the server: billed, less valid returns, less the receipts '
            'applied to those bills. Money held unapplied is not counted as settled.',
            style: theme.textTheme.bodySmall,
          ),
          // The action belongs where the figure is: this is the only place a screen says the
          // pharmacy is holding money nobody asked for, so it is where applying it starts. Absent
          // when nothing is held - a button that could only say "there is nothing to apply" is
          // worse than no button.
          if (value.hasDeposit) ...<Widget>[
            const SizedBox(height: 12),
            AppButton.outlined(
              label: 'Apply held money',
              icon: Icons.price_check,
              onPressed: () => _applyHeld(context, ref, value),
            ),
          ],
        ],
      ),
    );
  }

  /// Opens the application sheet, and says so once money has moved.
  Future<void> _applyHeld(
    BuildContext context,
    WidgetRef ref,
    PatientAccount account,
  ) async {
    final applied = await showApplyDepositSheet(
      context,
      customerId: customerId,
      patientName: account.patientName,
    );
    if (!applied || !context.mounted) {
      return;
    }
    // The sheet refreshes the account, the open bills and the receipts itself; what is left is to
    // say that something happened, because the figures moving is easy to miss on a long screen.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('The money was applied to the bills you chose.'),
        ),
      );
  }
}
