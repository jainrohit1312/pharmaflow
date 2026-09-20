/// The opening-stock import's state machine.
///
/// One value holds the whole screen: which step it is on, the chosen file, the
/// preview the owner is reading, and the result of the commit. The steps are
/// named for what the user sees rather than for what is in flight, so the screen
/// renders a stage instead of inferring one from several flags.
///
/// Parsing is not a stage of its own on the server's behalf: the client reads the
/// bytes and splits the records (a local, instant job), then the *server* does
/// the classifying, which is the step that can be slow and is therefore the one
/// with a waiting state.
library;

import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_audit_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_file_picker.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'opening_stock_controller.g.dart';

/// Which step of the import the screen is showing.
enum OpeningStockStage {
  /// Nothing chosen yet: the screen offers the file picker.
  idle,

  /// A file was chosen and the client is reading and splitting it.
  reading,

  /// The server is classifying the rows; nothing has been written.
  previewing,

  /// The preview is on screen and the owner may commit it.
  preview,

  /// The commit is in flight.
  committing,

  /// The import is written and the summary is on screen.
  success,

  /// Something failed, with a sentence to show.
  error,
}

/// Everything the opening-stock screen renders.
class OpeningStockState {
  /// Creates a state.
  const OpeningStockState({
    this.stage = OpeningStockStage.idle,
    this.fileName,
    this.preview,
    this.result,
    this.auditJob,
    this.error,
    this.savedTo,
    this.isSaving = false,
  });

  /// Which step this is.
  final OpeningStockStage stage;

  /// The chosen file's name, once one has been chosen.
  final String? fileName;

  /// What the server made of the file, once it has classified it.
  final OpeningStockPreview? preview;

  /// What the commit did, once it has run.
  final OpeningStockCommitResult? result;

  /// The committed import read back, for the audit CSV.
  final ImportJob? auditJob;

  /// Why the last attempt failed, when it did.
  final Object? error;

  /// Where the audit CSV was written, once the user has saved one.
  final String? savedTo;

  /// Whether the audit CSV is being rendered and saved.
  final bool isSaving;

  /// Whether something is in flight, whichever step it belongs to.
  bool get isBusy =>
      stage == OpeningStockStage.reading ||
      stage == OpeningStockStage.previewing ||
      stage == OpeningStockStage.committing;

  /// Whether the commit may be pressed: a clean preview, not already imported.
  bool get canCommit =>
      stage == OpeningStockStage.preview &&
      (preview?.summary.canImport ?? false) &&
      preview?.existingJob == null;

  /// Whether the file's content is already imported, so there is nothing to do.
  bool get isAlreadyImported =>
      stage == OpeningStockStage.preview && preview?.existingJob != null;
}

/// Drives the opening-stock import screen.
@riverpod
class OpeningStockController extends _$OpeningStockController {
  /// The rows last read from the chosen file.
  ///
  /// Held on the notifier rather than in the state, because the screen never
  /// renders them again: what it has to do is survive until the commit, so the
  /// payload the server re-reads is the payload it classified. A field on this
  /// notifier is what keeps it per-instance.
  List<OpeningStockCsvRow> _rows = const <OpeningStockCsvRow>[];

  @override
  OpeningStockState build() => const OpeningStockState();

  /// Asks for a file, reads it and has the server classify it.
  Future<void> pickFile() async {
    state = const OpeningStockState(stage: OpeningStockStage.reading);

    try {
      final picked = await ref.read(openingStockFilePickerProvider).pick();
      if (picked == null) {
        // The user changed their mind: back to the offer, not an error.
        state = const OpeningStockState();
        return;
      }
      await parsePreview(fileName: picked.fileName, content: picked.content);
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(stage: OpeningStockStage.error, error: error);
    }
  }

  /// Reads [content] into rows and asks the server to classify them.
  ///
  /// Separate from [pickFile] so a test can drive the whole preview path without
  /// a file dialog, and so the two failure modes stay distinct: a file this app
  /// cannot *read* never reaches the server, and a file the server will not
  /// accept comes back as row-numbered notes.
  Future<void> parsePreview({
    required String fileName,
    required String content,
  }) async {
    state = OpeningStockState(
      stage: OpeningStockStage.reading,
      fileName: fileName,
    );

    try {
      // Synchronous, and read before the call rather than after: a write path
      // scoped by a pharmacy that has not arrived yet should say so instead of
      // sending a request the server can only refuse (D-015).
      ref.read(requirePharmacyIdProvider);
      final rows = parseOpeningStockCsv(content);

      if (!ref.mounted) {
        return;
      }
      _rows = rows;
      state = OpeningStockState(
        stage: OpeningStockStage.previewing,
        fileName: fileName,
      );

      final preview = await ref
          .read(openingStockRepositoryProvider)
          .preview(rows);

      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: OpeningStockStage.preview,
        fileName: fileName,
        preview: preview,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: OpeningStockStage.error,
        fileName: fileName,
        error: error,
      );
    }
  }

  /// Writes the previewed file, in one transaction, or finds it already written.
  Future<void> commit() async {
    final preview = state.preview;
    final fileName = state.fileName;
    if (preview == null || fileName == null) {
      return;
    }
    if (!preview.summary.canImport) {
      return;
    }

    state = OpeningStockState(
      stage: OpeningStockStage.committing,
      fileName: fileName,
      preview: preview,
    );

    try {
      ref.read(requirePharmacyIdProvider);
      final rows = _rows;
      final result = await ref
          .read(openingStockRepositoryProvider)
          .commit(rows: rows, fileName: fileName);

      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: OpeningStockStage.success,
        fileName: fileName,
        preview: preview,
        result: result,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: OpeningStockStage.error,
        fileName: fileName,
        preview: preview,
        error: error,
      );
    }
  }

  /// Renders the committed import's audit trail and saves it where asked.
  ///
  /// The rows are read back from the database rather than re-rendered from the
  /// preview, so the file says what was stored - including the batch numbers the
  /// import generated.
  Future<void> saveAudit() async {
    final result = state.result;
    if (result == null) {
      return;
    }

    state = OpeningStockState(
      stage: state.stage,
      fileName: state.fileName,
      preview: state.preview,
      result: result,
      auditJob: state.auditJob,
      error: state.error,
      isSaving: true,
    );

    try {
      var job = state.auditJob;
      job ??= await ref.read(openingStockRepositoryProvider).job(result.jobId);

      final saved = await ref
          .read(openingStockCsvSaverProvider)
          .save(
            fileName: openingStockAuditFileName(job),
            content: buildOpeningStockAuditCsv(job),
          );

      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: state.stage,
        fileName: state.fileName,
        preview: state.preview,
        result: result,
        auditJob: job,
        savedTo: saved ?? state.savedTo,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = OpeningStockState(
        stage: state.stage,
        fileName: state.fileName,
        preview: state.preview,
        result: result,
        auditJob: state.auditJob,
        error: error,
      );
    }
  }

  /// Back to the offer, discarding the chosen file and the preview.
  void reset() {
    _rows = const <OpeningStockCsvRow>[];
    state = const OpeningStockState();
  }
}
