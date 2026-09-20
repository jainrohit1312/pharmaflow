/// Registering a patient at the counter.
///
/// The minimum identity an authorised sale needs (the brief's words), and no more:
/// a name, a mobile, and whatever else the counter happens to know. The patient code
/// is the server's to mint - nothing here types or picks one - and a GSTIN is
/// deliberately absent, because `save_patient()` has no parameter for it and the
/// customers screen owns that column.
///
/// The duplicate question is asked *before* the write: a number that already belongs
/// to somebody is a question rather than a conflict, because families share mobiles
/// and the server's unique key is the patient code, never the phone.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/application/patient_registration_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The sexes the details step offers.
///
/// A fixed list rather than free text because `customers.sex` carries a CHECK for
/// exactly these three (migration 00034), so anything else would be refused by the
/// database one round trip later.
const List<String> patientSexes = <String>['Male', 'Female', 'Other'];

/// Opens the registration sheet and resolves to the patient it registered, or
/// `null` when the counter closed it.
Future<PatientRegistration?> showPatientRegistrationSheet(
  BuildContext context,
) => showModalBottomSheet<PatientRegistration>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => const _PatientRegistrationSheet(),
);

/// The registration form.
class _PatientRegistrationSheet extends ConsumerStatefulWidget {
  const _PatientRegistrationSheet();

  @override
  ConsumerState<_PatientRegistrationSheet> createState() =>
      _PatientRegistrationSheetState();
}

class _PatientRegistrationSheetState
    extends ConsumerState<_PatientRegistrationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _mobile = TextEditingController();
  final _guardianName = TextEditingController();
  final _guardianPhone = TextEditingController();
  final _ageYears = TextEditingController();
  final _ageMonths = TextEditingController();
  final _address = TextEditingController();
  DateTime? _dateOfBirth;
  String? _sex;
  bool _saving = false;

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _mobile,
      _guardianName,
      _guardianPhone,
      _ageYears,
      _ageMonths,
      _address,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: media.viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('New patient', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'The patient number is given by the pharmacy, not chosen here.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _name,
                  label: 'Name',
                  prefixIcon: Icons.person_outline,
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'A name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _mobile,
                  label: 'Mobile',
                  hint: 'Ten digits, starting 6-9',
                  prefixIcon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: _mobileIfPresent,
                ),
                const SizedBox(height: 12),
                AppDateField(
                  label: 'Date of birth',
                  value: _dateOfBirth,
                  onChanged: (value) => setState(() => _dateOfBirth = value),
                  lastDate: DateTime.now(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: AppTextField(
                        controller: _ageYears,
                        label: 'Age (years)',
                        hint: 'Or the date above',
                        keyboardType: TextInputType.number,
                        validator: (value) => _ageError(value, 150),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppTextField(
                        controller: _ageMonths,
                        label: 'Age (months)',
                        hint: '0-11',
                        keyboardType: TextInputType.number,
                        validator: (value) => _ageError(value, 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AppDropdownField<String>(
                  label: 'Sex',
                  hint: 'Optional',
                  values: patientSexes,
                  labelOf: (value) => value,
                  value: _sex,
                  allowNone: true,
                  onChanged: (value) => setState(() => _sex = value),
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _guardianName,
                  label: 'Guardian name',
                  hint: 'For a child or a dependant',
                  prefixIcon: Icons.family_restroom_outlined,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _guardianPhone,
                  label: 'Guardian mobile',
                  hint: 'Satisfies the contact requirement instead',
                  prefixIcon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: _guardianError,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _address,
                  label: 'Address',
                  hint: 'Optional',
                  prefixIcon: Icons.home_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 20),
                AppButton.primary(
                  label: 'Register',
                  icon: Icons.person_add_alt,
                  isLoading: _saving,
                  onPressed: _saving ? null : _save,
                ),
                const SizedBox(height: 8),
                AppButton.text(
                  label: 'Cancel',
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Registers the patient, asking about the mobile number first.
  ///
  /// Two steps rather than one, because the second is a question only the counter
  /// can answer: a number already on file may be this patient, or their spouse, or
  /// their child - and the server stores a shared number as two patients on purpose.
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    // The contact requirement is the **pair** - the patient's own number, or a
    // guardian's for a child or dependant - which no single field validator can
    // see, so the two are checked together here. The sentence is the server's.
    if (_blank(_mobile.text) && _blank(_guardianPhone.text)) {
      _report(
        'A patient needs a mobile number, or a guardian\u2019s for a child or '
        'dependant.',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final matches = await ref
          .read(patientRegistrationControllerProvider.notifier)
          .matchesForMobile(_mobile.text);
      if (!mounted) {
        return;
      }
      if (matches.isNotEmpty) {
        // Not saving any more: asking. The spinner goes with it, because a submit in
        // flight and a question waiting to be answered are two different states.
        setState(() => _saving = false);
        final existing = matches.first;
        final useExisting = await _askAboutExisting(existing);
        if (!mounted) {
          return;
        }
        if (useExisting) {
          final reused = await ref
              .read(patientRegistrationControllerProvider.notifier)
              .reuse(existing);
          if (mounted) {
            Navigator.of(context).pop(reused);
          }
          return;
        }
        setState(() => _saving = true);
      }

      final registered = await ref
          .read(patientRegistrationControllerProvider.notifier)
          .register(
            name: _name.text,
            mobile: _mobile.text,
            dateOfBirth: _dateOfBirth,
            ageYears: _parse(_ageYears.text),
            ageMonths: _parse(_ageMonths.text),
            sex: _sex?.toLowerCase(),
            guardianName: _guardianName.text.trim().isEmpty
                ? null
                : _guardianName.text.trim(),
            guardianPhone: _guardianPhone.text.trim().isEmpty
                ? null
                : _guardianPhone.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
          );
      if (mounted) {
        Navigator.of(context).pop(registered);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        _report(describeError(error));
      }
    }
  }

  /// Asks whether the number belongs to [existing], and resolves to "use them".
  Future<bool> _askAboutExisting(Customer existing) => showConfirmDialog(
    context,
    title: 'That number is already on file',
    message:
        '${existing.name}'
        '${(existing.patientCode ?? '').isEmpty ? '' : ' (${existing.patientCode})'} '
        'is registered with this mobile number. Bill this sale to them, or register '
        'a second patient who shares the number?',
    confirmLabel: 'Use that patient',
    cancelLabel: 'Register anyway',
  );

  /// Shows a message without leaving the sheet.
  void _report(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether [value] holds nothing but whitespace.
  static bool _blank(String value) => value.trim().isEmpty;

  /// The mobile's own message, for a number that was typed and is wrong.
  ///
  /// A blank value passes: the requirement is the pair with the guardian's number,
  /// which [_save] checks where both are visible.
  static String? _mobileIfPresent(String? value) {
    if (_blank(value ?? '')) {
      return null;
    }
    return _numberError(value!);
  }

  /// The guardian's number, which has to be a mobile when one is given.
  static String? _guardianError(String? value) {
    if (_blank(value ?? '')) {
      return null;
    }
    return _numberError(value!);
  }

  /// Whether [value] is a usable Indian mobile number.
  static String? _numberError(String value) =>
      RegExp(r'^[6-9]\d{9}$').hasMatch(_digits(value))
      ? null
      : 'Enter a valid 10-digit mobile number';

  /// A whole number within [max], when one was entered.
  static String? _ageError(String? value, int max) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      return 'Enter a whole number';
    }
    if (parsed < 0 || parsed > max) {
      return 'Must be between 0 and $max';
    }
    return null;
  }

  /// The digits of a number, with `+91` and a leading zero tolerated.
  static String _digits(String value) {
    var digits = value.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    }
    if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return digits;
  }

  /// [value] as a whole number, or `null` when it holds nothing usable.
  static int? _parse(String value) {
    final raw = value.trim();
    return raw.isEmpty ? null : int.tryParse(raw);
  }
}
