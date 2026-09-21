/// One admission episode's account.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/account_balance.dart';
import 'package:app/features/balances/application/balances.dart';
import 'package:app/features/balances/presentation/widgets/account_figure.dart';
import 'package:app/features/balances/presentation/widgets/patient_balance_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What one episode of care owes, read from `admission_account()`.
///
/// **An admission is its own account.** One patient has many episodes and their
/// balances never mix (D-074), so this screen is the answer to "what does this stay
/// cost", which the patient's own balance deliberately cannot give: a bill posted to
/// episode A leaves episode B untouched.
///
/// Every figure is the server's aggregate over the whole episode - **nothing here sums
/// rows** - and the allocations counted are every slice of money aimed at the episode
/// *or* at a bill inside it, because each row is a slice and the sum of the slices is
/// what was applied.
class AdmissionAccountScreen extends ConsumerWidget {
  /// Creates the screen for [admissionId].
  const AdmissionAccountScreen({required this.admissionId, super.key});

  /// The episode to show.
  final String admissionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(admissionAccountProvider(admissionId));

    if (account.hasError && !account.hasValue) {
      return AppScaffold(
        title: 'Admission',
        body: ErrorView(
          message: describeError(account.error!),
          onRetry: () => ref.invalidate(admissionAccountProvider(admissionId)),
        ),
      );
    }

    final value = account.value;
    if (value == null) {
      if (account.isLoading) {
        return const AppScaffold(
          title: 'Admission',
          body: LoadingView(message: 'Loading the admission…'),
        );
      }
      // The server answers no rows for an episode outside the caller's pharmacy, which
      // is the same answer a stale link gets everywhere else in this app.
      return const AppScaffold(
        title: 'Admission',
        body: AppEmptyView(
          icon: Icons.local_hospital_outlined,
          title: 'Admission not found',
          message:
              'This admission is no longer in the pharmacy\u2019s records. It may '
              'have been opened from a link that is out of date.',
        ),
      );
    }

    return AppScaffold(
      title: value.admissionNo,
      // Back to the episode's owner rather than a fixed list: this screen is reached
      // from a patient's detail *and* from a bill, and the patient is the parent both
      // routes share.
      leading: AppBackButton(
        location: Routes.customerDetail(value.customerId),
        tooltip: 'Back to the patient',
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Episode',
            trailing: StatusBadge(
              label: value.isActive ? 'Active' : 'Discharged',
              tone: value.isActive ? BadgeTone.info : BadgeTone.neutral,
            ),
            child: Column(
              children: <Widget>[
                _Field(label: 'Admission number', value: value.admissionNo),
                _Field(
                  label: 'Patient',
                  value: value.patientCode == null
                      ? value.patientName
                      : '${value.patientName} · ${value.patientCode}',
                ),
                _Field(
                  label: 'Admitted',
                  value: value.admittedOn == null
                      ? null
                      : Formatters.dateDdMmYyyy(value.admittedOn!),
                ),
                _Field(
                  label: 'Discharged',
                  value: value.dischargedOn == null
                      ? null
                      : Formatters.dateDdMmYyyy(value.dischargedOn!),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _AccountCard(account: value),
          const SizedBox(height: 16),
          // The patient's own balance, which this episode deliberately does not touch.
          // Shown here so the two cannot be confused for one another.
          PatientBalanceCard(customerId: value.customerId),
        ],
      ),
    );
  }
}

/// The episode's own figures.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});

  /// The loaded account.
  final AdmissionAccount account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inCredit = account.outstanding < 0;

    return SectionCard(
      title: 'Account',
      trailing: StatusBadge(
        label: account.isSettled
            ? 'Settled'
            : (inCredit ? 'In credit' : 'Outstanding'),
        tone: account.isSettled
            ? BadgeTone.success
            : (inCredit ? BadgeTone.warning : BadgeTone.info),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccountFigure(
            label: inCredit ? 'Held for the episode' : 'Outstanding',
            value: Formatters.currency(account.outstanding),
            tone: account.isSettled ? null : theme.colorScheme.error,
            emphasis: theme.textTheme.titleMedium,
          ),
          AccountFigure(
            label: 'Billed to this episode',
            value: Formatters.currency(account.charges),
          ),
          if (account.returnsCredits != 0)
            AccountFigure(
              label: 'Credited back',
              value: '-${Formatters.currency(account.returnsCredits)}',
            ),
          AccountFigure(
            label: 'Receipts applied',
            value: Formatters.currency(account.allocated),
          ),
          const SizedBox(height: 8),
          Text(
            'Billed, less valid returns, less the receipts applied to this episode or '
            'to a bill inside it. An episode\u2019s balance never mixes with another '
            'episode\u2019s, or with the patient\u2019s own.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// A labelled value, stacked so it stays readable at any width.
class _Field extends StatelessWidget {
  const _Field({required this.label, this.value});

  /// What the value is.
  final String label;

  /// The value, or `null`/blank to render an em dash.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value;
    final display = text == null || text.trim().isEmpty ? '—' : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(display, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
