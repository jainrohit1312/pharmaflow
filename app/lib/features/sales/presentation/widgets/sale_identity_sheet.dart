/// The sheet that corrects a posted bill's printed identity.
///
/// Phase 6.5c chunk 5d lets a bill's PRINTED details be corrected - who it was for, who prescribed
/// it, the hospital's own reference - and nothing else. The sheet collects exactly those five
/// fields and hands them back; the screen that opened it performs the write, because the sentence a
/// staged act produces belongs to the screen and not to a modal that is already closing.
///
/// The patient's name and mobile travel TOGETHER, always, even when only one was edited: a pharmacy
/// bill carries the pair or neither (migration 00035's constraint, which the server checks in words
/// rather than letting the constraint raise), and a sheet that sent only the name would be offering
/// the operator a refusal they did not ask for.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/sale.dart';
import 'package:flutter/material.dart';

/// The five printed fields, as the operator left them.
class SaleIdentityEdits {
  /// Creates the edits.
  const SaleIdentityEdits({
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    required this.doctorName,
    required this.hospitalReference,
  });

  /// The patient as this bill prints them.
  final String patientName;

  /// The patient's contact as this bill recorded it.
  final String patientMobile;

  /// The patient's address as this bill prints it.
  final String patientAddress;

  /// The prescriber as this bill prints them.
  final String doctorName;

  /// The hospital's own OPD/IPD reference.
  final String hospitalReference;
}

/// Opens the sheet, and answers the edits or `null` when it was dismissed.
Future<SaleIdentityEdits?> showSaleIdentitySheet(
  BuildContext context, {
  required Sale sale,
}) => showModalBottomSheet<SaleIdentityEdits>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => Padding(
    padding: EdgeInsets.only(
      left: 16,
      right: 16,
      top: 16,
      bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
    ),
    child: _SaleIdentitySheet(sale: sale),
  ),
);

/// The form itself.
class _SaleIdentitySheet extends StatefulWidget {
  const _SaleIdentitySheet({required this.sale});

  final Sale sale;

  @override
  State<_SaleIdentitySheet> createState() => _SaleIdentitySheetState();
}

class _SaleIdentitySheetState extends State<_SaleIdentitySheet> {
  late final TextEditingController _patientName;
  late final TextEditingController _patientMobile;
  late final TextEditingController _patientAddress;
  late final TextEditingController _doctorName;
  late final TextEditingController _hospitalReference;

  @override
  void initState() {
    super.initState();
    final sale = widget.sale;
    _patientName = TextEditingController(text: sale.patientName ?? '');
    _patientMobile = TextEditingController(text: sale.patientMobile ?? '');
    _patientAddress = TextEditingController(text: sale.patientAddress ?? '');
    _doctorName = TextEditingController(text: sale.doctorName ?? '');
    _hospitalReference = TextEditingController(
      text: sale.hospitalReference ?? '',
    );
  }

  @override
  void dispose() {
    _patientName.dispose();
    _patientMobile.dispose();
    _patientAddress.dispose();
    _doctorName.dispose();
    _hospitalReference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Correct the printed details',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'These are what this bill printed. Nothing here changes what the '
            'customer owes, what was sold or the stock - a correction to those is '
            'a sale return, which the owner also approves.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          AppTextField(controller: _patientName, label: 'Patient name'),
          const SizedBox(height: 12),
          AppTextField(
            controller: _patientMobile,
            label: 'Patient mobile',
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 12),
          AppTextField(controller: _patientAddress, label: 'Patient address'),
          const SizedBox(height: 12),
          AppTextField(controller: _doctorName, label: 'Prescribed by'),
          const SizedBox(height: 12),
          AppTextField(
            controller: _hospitalReference,
            label: 'Hospital reference',
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              // `expand: false` on both: an `AppButton` defaults to the full width, and one inside a
              // Row asks for an infinite width - which is a layout error, not a wide button.
              AppButton.text(
                label: 'Close',
                expand: false,
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              AppButton.primary(
                label: 'Save these details',
                expand: false,
                onPressed: () => Navigator.of(context).pop(
                  SaleIdentityEdits(
                    patientName: _patientName.text,
                    patientMobile: _patientMobile.text,
                    patientAddress: _patientAddress.text,
                    doctorName: _doctorName.text,
                    hospitalReference: _hospitalReference.text,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
