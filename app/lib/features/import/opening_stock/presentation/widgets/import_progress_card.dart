/// The upload's steps, as the owner watches them.
library;

import 'dart:async';

import 'package:app/core/theme/app_colors.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/features/import/opening_stock/application/opening_stock_controller.dart';
import 'package:flutter/material.dart';

/// The three steps of an upload, each showing whether it has happened yet.
///
/// No percentage and no progress bar: the upload is one request to one function,
/// so the only two things that are genuinely known are that the file was read
/// and that the answer has not come back yet. What is honest instead is the
/// elapsed clock below them - it says the screen is alive without pretending to
/// know how far along the server is.
class ImportProgressCard extends StatefulWidget {
  /// Creates a progress card for [phase].
  const ImportProgressCard({required this.phase, super.key, this.fileName});

  /// The step in flight.
  final OpeningStockImportPhase phase;

  /// The file being read, for the heading.
  final String? fileName;

  @override
  State<ImportProgressCard> createState() => _ImportProgressCardState();
}

class _ImportProgressCardState extends State<ImportProgressCard> {
  Timer? _clock;
  var _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    // One second, so the counter moves at reading speed rather than at frame
    // speed; the card lives exactly as long as the step does, so the timer needs
    // no other lifecycle than this widget's.
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _elapsedSeconds++),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = widget.fileName;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: file ?? 'Reading your file',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Step(
                label: 'Reading the file',
                state: _stateOf(OpeningStockImportPhase.reading),
              ),
              _Step(
                label: 'Sending to the server',
                state: _stateOf(OpeningStockImportPhase.sending),
              ),
              _Step(
                label: 'Classifying the products',
                state: _stateOf(OpeningStockImportPhase.classifying),
              ),
              const SizedBox(height: 16),
              Text(
                'Working… ${_elapsedSeconds}s elapsed',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// How [step] stands against the step in flight.
  ///
  /// The order the phases are declared in is the order they happen, so a step
  /// before the current one has been passed. `writing` is past all three, which
  /// is what makes every row a tick when a commit is the thing in flight.
  _StepState _stateOf(OpeningStockImportPhase step) =>
      switch (step.index.compareTo(widget.phase.index)) {
        < 0 => _StepState.done,
        0 => _StepState.active,
        _ => _StepState.pending,
      };
}

/// Whether a step is done, in flight, or not started yet.
enum _StepState { done, active, pending }

/// One step of the upload, with the mark it currently deserves.
class _Step extends StatelessWidget {
  const _Step({required this.label, required this.state});

  /// What the step is called on screen.
  final String label;

  /// Where the step stands.
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(width: 24, child: _Marker(state: state)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: state == _StepState.pending
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tick, the spinner, or the empty circle beside a step.
class _Marker extends StatelessWidget {
  const _Marker({required this.state});

  final _StepState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    _StepState.done => const Icon(
      Icons.check_circle,
      size: 20,
      color: AppColors.success,
    ),
    _StepState.active => const SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    _StepState.pending => Icon(
      Icons.radio_button_unchecked,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  };
}
