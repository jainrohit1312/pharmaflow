/// The details a sale type asks for: the prescriber, the hospital's reference, the
/// episode, and where a transfer moves stock.
///
/// Which of these appear is the type's business (D-067): a counter sale names a
/// prescriber only when a Schedule H/H1/X line needs one, an IPD sale needs the
/// episode and the doctor who is treating it, a package sale needs the case
/// reference, and a transfer needs its two locations and a reason.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/data/models/doctor.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:app/features/sales/application/admission_controller.dart';
import 'package:app/features/sales/application/doctor_options.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The per-type half of the details step.
class SaleIdentityFields extends ConsumerStatefulWidget {
  /// Creates the fields.
  const SaleIdentityFields({required this.cart, super.key});

  /// The basket as it stands.
  ///
  /// Read from the parent's watch rather than subscribed to here, so a keystroke
  /// elsewhere does not rebuild this widget's controllers.
  final PosCart cart;

  @override
  ConsumerState<SaleIdentityFields> createState() => _SaleIdentityFieldsState();
}

class _SaleIdentityFieldsState extends ConsumerState<SaleIdentityFields> {
  final _doctor = TextEditingController();
  final _reference = TextEditingController();
  final _ward = TextEditingController();
  final _bed = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Listeners rather than `onSubmitted`: a browser and a desktop have no submit
    // key, and the payload must follow every keystroke - the same rule the basket's
    // own fields follow.
    _doctor.addListener(() => _setDoctor(_doctor.text));
    _reference.addListener(
      () => ref
          .read(posControllerProvider.notifier)
          .setHospitalReference(_blankToNull(_reference.text)),
    );
    _from.addListener(_pushTransfer);
    _to.addListener(_pushTransfer);
    _reason.addListener(_pushTransfer);
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _doctor,
      _reference,
      _ward,
      _bed,
      _from,
      _to,
      _reason,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final theme = Theme.of(context);
    final type = cart.saleType;

    if (type == SaleType.transfer) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'A transfer moves stock between locations: it names no patient, takes '
            'no payment and charges no GST.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: _from,
            label: 'From',
            hint: 'Where the stock is now',
            prefixIcon: Icons.warehouse_outlined,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: _to,
            label: 'To',
            hint: 'Where it is going',
            prefixIcon: Icons.warehouse_outlined,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: _reason,
            label: 'Reason',
            hint: 'Why the stock is moving',
            prefixIcon: Icons.notes_outlined,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // A prescriber is recorded on the two sales that are pharmacy sales; a
        // package sale is the hospital buying, so there is nobody to prescribe and
        // the payload carries no doctor at all.
        if (type.isPharmacySale)
          _PrescriberField(
            controller: _doctor,
            onSuggestion: _chooseDoctor,
            ref: ref,
          ),
        if (type == SaleType.ipdAdmission) ...<Widget>[
          if (type.isPharmacySale) const SizedBox(height: 12),
          AppTextField(
            controller: _reference,
            label: 'Hospital admission number',
            hint: 'The hospital\u2019s own IPD/OPD number',
            prefixIcon: Icons.confirmation_number_outlined,
          ),
          const SizedBox(height: 8),
          _AdmissionActions(
            cart: cart,
            reference: _reference,
            ward: _ward,
            bed: _bed,
          ),
        ],
        if (type == SaleType.package) ...<Widget>[
          AppTextField(
            controller: _reference,
            label: 'Package / case reference',
            hint: 'The hospital\u2019s reference for this case',
            prefixIcon: Icons.confirmation_number_outlined,
          ),
        ],
      ],
    );
  }

  /// Records the prescriber the counter typed, resolving the master row it names.
  ///
  /// A name the master does not hold is still recorded as the name: the server
  /// converges the spelling and creates the row itself (D-072), so nothing here has
  /// to refuse a prescriber nobody has met yet.
  void _setDoctor(String value) {
    final name = _blankToNull(value);
    final id = name == null
        ? null
        : _doctorIdFor(ref.read(doctorOptionsProvider).value, name);
    ref.read(posControllerProvider.notifier).setDoctor(id: id, name: name);
  }

  /// Records a prescriber chosen from the master.
  void _chooseDoctor(String id, String name) {
    _doctor.text = name;
    ref.read(posControllerProvider.notifier).setDoctor(id: id, name: name);
  }

  /// Records a transfer's three fields together.
  void _pushTransfer() => ref
      .read(posControllerProvider.notifier)
      .setTransfer(
        from: _blankToNull(_from.text),
        to: _blankToNull(_to.text),
        reason: _blankToNull(_reason.text),
      );
}

/// The prescriber field, with the master's own names offered under it.
class _PrescriberField extends StatelessWidget {
  /// Creates the field.
  const _PrescriberField({
    required this.controller,
    required this.onSuggestion,
    required this.ref,
  });

  /// The name as typed.
  final TextEditingController controller;

  /// Called with a master row's id and name when its chip is tapped.
  final void Function(String id, String name) onSuggestion;

  /// The container, to read the prescriber list the screen already loads.
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doctors = ref.watch(doctorOptionsProvider).value ?? const <Doctor>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppTextField(
          controller: controller,
          label: 'Prescriber',
          hint: 'Required for a Schedule H, H1 or X line',
          prefixIcon: Icons.badge_outlined,
        ),
        if (doctors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Prescribers on file', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final doctor in doctors)
                ActionChip(
                  label: Text(doctor.label),
                  onPressed: () => onSuggestion(doctor.id, doctor.name),
                ),
            ],
          ),
          Text(
            'Tap one to record it, or type a name the list does not have.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// Opening or choosing the episode an IPD bill posts to.
class _AdmissionActions extends ConsumerWidget {
  /// Creates the actions.
  const _AdmissionActions({
    required this.cart,
    required this.reference,
    required this.ward,
    required this.bed,
  });

  /// The basket, for the patient and the number typed.
  final PosCart cart;

  /// The hospital's number as typed, cleared when an episode is chosen instead.
  final TextEditingController reference;

  /// The ward the episode is in, as typed.
  final TextEditingController ward;

  /// The bed the episode is in, as typed.
  final TextEditingController bed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final patientId = cart.customerId;
    // Read leniently: losing the list of a patient's episodes costs the counter a
    // convenience, while failing the bill would cost it the sale.
    final episodes = patientId == null
        ? const <Admission>[]
        : ref.watch(patientAdmissionsProvider(patientId)).value ?? const [];
    final opening = ref.watch(admissionControllerProvider).isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (cart.admissionId != null) ...<Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.link, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Billing admission ${cart.admissionNo}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              AppButton.text(
                label: 'Clear',
                expand: false,
                onPressed: () =>
                    ref.read(posControllerProvider.notifier).setAdmission(null),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: AppTextField(
                controller: ward,
                label: 'Ward',
                hint: 'Optional',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppTextField(
                controller: bed,
                label: 'Bed',
                hint: 'Optional',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AppButton.text(
          label: 'Find or open this admission',
          icon: Icons.search,
          expand: false,
          isLoading: opening,
          onPressed: patientId == null ? null : () => _open(context, ref),
        ),
        if (episodes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'This patient\u2019s admissions',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final episode in episodes)
                ChoiceChip(
                  label: Text(episode.label),
                  selected: episode.id == cart.admissionId,
                  onSelected: (_) {
                    // The number field is cleared, so the screen cannot show one
                    // admission while the bill carries another: the episode that was
                    // chosen is the one the row above names.
                    reference.clear();
                    ref
                        .read(posControllerProvider.notifier)
                        .setAdmission(episode);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Hands the number to the server, which finds the episode or opens it.
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Taken before the await: the sheet may be gone by the time the server answers,
    // and a refusal the operator never sees is worse than one they read a moment
    // after moving on.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(admissionControllerProvider.notifier)
          .open(
            patientId: cart.customerId!,
            admissionNo: cart.hospitalReference ?? '',
            ward: _blankToNull(ward.text),
            bed: _blankToNull(bed.text),
            doctorId: cart.doctorId,
            doctorName: cart.doctorName,
          );
    } on Object catch (error) {
      // The controller records the failure too; this is what the operator reads, in
      // the server's own words where it has them, because a button that silently
      // does nothing is worse than a message.
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// The master row whose name is [name], or `null` when the master has none.
String? _doctorIdFor(List<Doctor>? doctors, String name) {
  if (doctors == null) {
    return null;
  }
  for (final doctor in doctors) {
    if (doctor.name.toLowerCase() == name.toLowerCase()) {
      return doctor.id;
    }
  }
  return null;
}

/// [value] trimmed, or `null` when it holds nothing.
String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
