/// Who the bill is for.
///
/// The first thing the counter answers, because every sale type but a transfer
/// requires it and the server refuses a pharmacy sale without one: a patient
/// (D-074), found by name, mobile or patient code, or registered in one sheet.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:app/features/customers/application/patient_registration_controller.dart';
import 'package:app/features/customers/presentation/patients/patient_registration_sheet.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The patient step: the patient a bill is for, or the account a package sale
/// bills.
class PatientStep extends ConsumerStatefulWidget {
  /// Creates the step.
  const PatientStep({required this.cart, super.key});

  /// The basket as it stands.
  final PosCart cart;

  @override
  ConsumerState<PatientStep> createState() => _PatientStepState();
}

class _PatientStepState extends ConsumerState<PatientStep> {
  final _debounce = Debouncer();
  final _patientName = TextEditingController();
  final _patientMobile = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _debounce.dispose();
    _patientName.dispose();
    _patientMobile.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    if (cart.saleType == SaleType.package) {
      return _PackageStep(
        cart: cart,
        name: _patientName,
        mobile: _patientMobile,
      );
    }
    return _patientFound(cart)
        ? _PinnedPatient(cart: cart, onClear: _clear)
        : _lookup(cart);
  }

  /// Whether this bill already names the patient it is for.
  bool _patientFound(PosCart cart) =>
      cart.customerId != null && (cart.patientName ?? '').trim().isNotEmpty;

  /// The lookup: a term, the recent patients, and the way to register one.
  Widget _lookup(PosCart cart) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppSearchField(
          hint: 'Search by name, mobile or patient code',
          onChanged: _termChanged,
        ),
        if (_query.isEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _RecentPatients(onSelected: _pin),
        ] else ...<Widget>[
          const SizedBox(height: 8),
          _Results(term: _query, onSelected: _pin),
        ],
        const SizedBox(height: 12),
        AppButton.outlined(
          label: 'New patient',
          icon: Icons.person_add_alt,
          onPressed: _register,
        ),
        const SizedBox(height: 8),
        Text(
          'A pharmacy sale prints the patient\u2019s name and number, so both are '
          'needed before the medicines.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  /// Applies a search term once the counter stops typing.
  void _termChanged(String value) {
    final trimmed = value.trim();
    if (trimmed == _query) {
      return;
    }
    _debounce.run(() {
      if (mounted) {
        setState(() => _query = trimmed);
      }
    });
  }

  /// Pins a patient to the bill.
  ///
  /// Through the registration controller rather than straight onto the cart: the
  /// server is asked to hand the row back (which is what assigns a code to a
  /// customer registered before Phase 7a), and the cart then carries the name and
  /// number the bill will print.
  Future<void> _pin(Customer patient) async {
    try {
      await ref
          .read(patientRegistrationControllerProvider.notifier)
          .reuse(patient);
      if (mounted) {
        _clearSearch();
      }
    } on Object catch (error) {
      _report(describeError(error));
    }
  }

  /// Opens the registration sheet and pins whoever it answers with.
  Future<void> _register() async {
    final registered = await showPatientRegistrationSheet(context);
    if (registered == null || !mounted) {
      return;
    }
    // A patient who was not on file a moment ago is on the list now, and the recent list
    // is what the next counter opens with. Refreshed **here** rather than by the
    // controller, which may already have been disposed by the time its own write answers -
    // the same one-way dependency `showPaymentSheet` documents.
    ref.invalidate(recentPatientsProvider);
    _clearSearch();
    _report('${registered.patient.name} pinned to this bill.');
  }

  /// Forgets the patient, and the term that found them.
  void _clear() {
    ref.read(posControllerProvider.notifier).setPatient(null);
    _clearSearch();
  }

  /// Empties the lookup, so the next search starts clean.
  ///
  /// The search field owns its own text: it is removed from the tree while a patient
  /// is pinned, so the next one is built empty and there is nothing here to clear.
  void _clearSearch() => setState(() => _query = '');

  /// Shows a message without involving a controller.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The patient a bill is already for.
class _PinnedPatient extends StatelessWidget {
  /// Creates the card.
  const _PinnedPatient({required this.cart, required this.onClear});

  /// The basket carrying the patient.
  final PosCart cart;

  /// Called when the counter wants a different one.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mobile = cart.patientMobile;

    return Row(
      children: <Widget>[
        const Icon(Icons.person_outline),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                cart.patientName ?? 'Patient',
                style: theme.textTheme.titleSmall,
              ),
              Text(
                mobile == null || mobile.isEmpty ? 'No number on file' : mobile,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        AppButton.text(label: 'Change', expand: false, onPressed: onClear),
      ],
    );
  }
}

/// The patients registered most recently.
class _RecentPatients extends ConsumerWidget {
  /// Creates the list.
  const _RecentPatients({required this.onSelected});

  /// Called with the patient that was tapped.
  final ValueChanged<Customer> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentPatientsProvider);

    return recent.when(
      data: (patients) => patients.isEmpty
          ? const AppEmptyView(
              icon: Icons.person_search_outlined,
              title: 'No patients yet',
              message:
                  'Register the patient before the medicines: a pharmacy sale '
                  'needs a name and a number.',
            )
          : _List(
              label: 'Recent patients',
              patients: patients,
              onSelected: onSelected,
            ),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      // A failed read costs the list, not the sale: the search field still works,
      // and the sheet can still register somebody.
      error: (error, _) => Text(
        describeError(error),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// The patients a term matched.
class _Results extends ConsumerWidget {
  /// Creates the list.
  const _Results({required this.term, required this.onSelected});

  /// The term to search for.
  final String term;

  /// Called with the patient that was tapped.
  final ValueChanged<Customer> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(patientSearchProvider(term));
    final theme = Theme.of(context);

    return results.when(
      data: (matches) => matches.isEmpty
          ? Text(
              'No patient matches "$term".',
              style: theme.textTheme.bodySmall,
            )
          : _List(
              patients: matches.map((match) => match.patient).toList(),
              admissionCounts: <String, int>{
                for (final match in matches)
                  match.patient.id: match.activeAdmissionCount,
              },
              onSelected: onSelected,
            ),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (error, _) =>
          Text(describeError(error), style: theme.textTheme.bodySmall),
    );
  }
}

/// A tappable list of patients, with what makes them identifiable.
class _List extends StatelessWidget {
  /// Creates the list.
  const _List({
    required this.patients,
    required this.onSelected,
    this.label,
    this.admissionCounts = const <String, int>{},
  });

  /// The patients to show.
  final List<Customer> patients;

  /// Called with the patient that was tapped.
  final ValueChanged<Customer> onSelected;

  /// An optional heading.
  final String? label;

  /// How many open episodes each patient has, by id.
  final Map<String, int> admissionCounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = label;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (heading != null) ...<Widget>[
          Text(heading, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
        ],
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              for (final patient in patients)
                ListTile(
                  dense: true,
                  title: Text(patient.name),
                  // The code and the number are what tell two patients with the
                  // same name apart, which is the whole reason the lookup shows
                  // them rather than only the name.
                  subtitle: Text(
                    <String>[
                      if ((patient.patientCode ?? '').isNotEmpty)
                        patient.patientCode!,
                      if ((patient.phone ?? '').isNotEmpty) patient.phone!,
                      if ((admissionCounts[patient.id] ?? 0) > 0)
                        '${admissionCounts[patient.id]} admitted',
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onSelected(patient),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The package sale's half of the step: the account that owes, and the patient the
/// medicines are for.
class _PackageStep extends ConsumerStatefulWidget {
  /// Creates the step.
  const _PackageStep({
    required this.cart,
    required this.name,
    required this.mobile,
  });

  /// The basket as it stands.
  final PosCart cart;

  /// The patient's name, as typed.
  final TextEditingController name;

  /// The patient's mobile number, as typed.
  final TextEditingController mobile;

  @override
  ConsumerState<_PackageStep> createState() => _PackageStepState();
}

class _PackageStepState extends ConsumerState<_PackageStep> {
  @override
  void initState() {
    super.initState();
    widget.name.addListener(_push);
    widget.mobile.addListener(_push);
  }

  @override
  void dispose() {
    widget.name.removeListener(_push);
    widget.mobile.removeListener(_push);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A failed account read costs the picker its options, not the counter its
    // basket, so it is read leniently - the same choice the old Customer dropdown
    // made.
    final accounts =
        ref.watch(customerOptionsProvider).value ?? const <Customer>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'The hospital is the debtor on a package sale, and the patient is '
          'recorded for traceability.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        AppDropdownField<String>(
          label: 'Hospital account',
          hint: 'Choose the account being billed',
          prefixIcon: Icons.account_balance_outlined,
          value: widget.cart.customerId,
          values: <String>[for (final account in accounts) account.id],
          labelOf: (id) => _accountName(accounts, id),
          allowNone: true,
          onChanged: (id) =>
              ref.read(posControllerProvider.notifier).setCustomer(id),
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: widget.name,
          label: 'Patient',
          hint: 'Who the medicines are for',
          prefixIcon: Icons.person_outline,
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: widget.mobile,
          label: 'Patient mobile',
          hint: 'Ten digits, for traceability',
          prefixIcon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
        ),
      ],
    );
  }

  /// Records both typed fields together, so the cart never holds half of them.
  void _push() => ref
      .read(posControllerProvider.notifier)
      .setPatientDetails(
        name: widget.name.text.trim().isEmpty ? null : widget.name.text.trim(),
        mobile: widget.mobile.text.trim().isEmpty
            ? null
            : widget.mobile.text.trim(),
      );
}

/// The name of the account [id] names, or a placeholder while it loads.
String _accountName(List<Customer> accounts, String id) {
  for (final account in accounts) {
    if (account.id == id) {
      return account.name;
    }
  }
  return 'Currently selected account';
}
