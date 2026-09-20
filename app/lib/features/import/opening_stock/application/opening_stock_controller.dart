/// The opening-stock import's state machine.
///
/// One value holds the whole screen: which step it is on, the chosen file, what
/// the first pass made of it, the preview the owner is reading, and the result
/// of the commit. The steps are named for what the user sees rather than for what
/// is in flight, so the screen renders a stage instead of inferring one from
/// several flags.
///
/// The file is read twice on purpose, and the two reads answer different
/// questions. The first is the screen's own - "is this the file I meant?" - and it
/// counts the first hundred rows without reading the rest. The second is the
/// import's, and it is the one that has to succeed before anything is sent. The
/// server classifies; nothing here decides what a row means (D-023).
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
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

  /// A file was chosen and its first rows read; the screen shows what it is and
  /// waits for the owner to send it.
  confirmed,

  /// The chosen file is being read in full and classified by the server.
  processing,

  /// The server has classified every row and the preview is on screen.
  preview,

  /// The commit is in flight.
  committing,

  /// The import is written and the summary is on screen.
  success,

  /// Something failed: the screen shows which step, and why.
  error,
}

/// Which step of an import the screen is naming.
///
/// Four steps, of which the processing card shows three. The client can see two
/// boundaries of the upload and no more: the local read finishes, and the
/// server's answer arrives. Sending and classifying are one request to one
/// function, so the send is marked done the moment the payload is handed over
/// rather than guessed at - a socket that is open and a server that is thinking
/// produce no signal this app could tell apart, and a step that ticks on a timer
/// would be an invented one (D-073).
///
/// [writing] is the commit. It is not on the processing card, which is about
/// reading and checking the file; it names the step in a failure, so a write that
/// was refused does not have to be reported as a classification that was not.
enum OpeningStockImportPhase {
  /// Decoding the bytes and splitting the records, locally.
  reading,

  /// Handing the rows to the server.
  sending,

  /// Waiting for the server's classification, which is the slow one.
  classifying,

  /// Writing the previewed rows into stock.
  writing,
}

/// A failure the screen shows in full: the step, the sentence, and the row.
class OpeningStockFailure {
  /// Creates a failure.
  const OpeningStockFailure({
    required this.phase,
    required this.error,
    this.rowNumber,
  });

  /// The step that failed.
  final OpeningStockImportPhase phase;

  /// What was thrown, kept whole so the sentence is written in one place.
  final Object error;

  /// The row at fault, when one row is at fault rather than the file.
  final int? rowNumber;

  /// The sentence to show the owner.
  String get message => describeError(error);
}

/// Everything the opening-stock screen renders.
class OpeningStockState {
  /// Creates a state.
  const OpeningStockState({
    this.stage = OpeningStockStage.idle,
    this.fileName,
    this.fileSizeBytes,
    this.estimatedRowCount,
    this.estimateTruncated = false,
    this.phase = OpeningStockImportPhase.reading,
    this.preview,
    this.result,
    this.auditJob,
    this.failure,
    this.saveError,
    this.savedTo,
    this.isPicking = false,
    this.isSaving = false,
  });

  /// Which step this is.
  final OpeningStockStage stage;

  /// The chosen file's name, once one has been chosen.
  final String? fileName;

  /// How large the chosen file was, in bytes.
  final int? fileSizeBytes;

  /// How many rows the first pass over the chosen file counted.
  final int? estimatedRowCount;

  /// Whether that count stopped at the first pass's limit, so the file holds at
  /// least [estimatedRowCount] rows.
  final bool estimateTruncated;

  /// Which step of the upload is in flight, while [stage] is processing.
  final OpeningStockImportPhase phase;

  /// What the server made of the file, once it has classified it.
  final OpeningStockPreview? preview;

  /// What the commit did, once it has run.
  final OpeningStockCommitResult? result;

  /// The committed import read back, for the audit CSV.
  final ImportJob? auditJob;

  /// Why the last attempt failed, when it did.
  final OpeningStockFailure? failure;

  /// Why saving the audit CSV failed, when it did.
  ///
  /// Apart from [failure] on purpose: a download that failed is a footnote under
  /// a finished import, not a step the import itself did not reach, so it leaves
  /// the summary on screen and adds a line to it.
  final Object? saveError;

  /// Where the audit CSV was written, once the owner has saved one.
  final String? savedTo;

  /// Whether the file dialog is open, or a chosen file is being read.
  final bool isPicking;

  /// Whether the audit CSV is being rendered and saved.
  final bool isSaving;

  /// The failure to show on the error step.
  ///
  /// The error step is only ever reached with a failure in hand, so this is that
  /// failure; the stand-in is for a state built by hand that should not exist,
  /// and it exists so that such a state renders a sentence rather than a blank
  /// screen.
  OpeningStockFailure get shownFailure =>
      failure ??
      const OpeningStockFailure(
        phase: OpeningStockImportPhase.reading,
        error: ServerException(
          message: 'That import could not be read, and the reason was lost.',
          code: 'import/unknown-failure',
        ),
      );

  /// Whether the owner may leave this step - false while it is mid-flight.
  bool get isBusy =>
      stage == OpeningStockStage.processing ||
      stage == OpeningStockStage.committing;

  /// Whether the commit may be pressed: a clean preview, not already imported.
  bool get canCommit =>
      stage == OpeningStockStage.preview &&
      (preview?.summary.canImport ?? false) &&
      preview?.existingJob == null;

  /// Whether the file's content is already imported, so there is nothing to do.
  bool get isAlreadyImported =>
      stage == OpeningStockStage.preview && preview?.existingJob != null;

  /// A copy of this state with the given fields replaced.
  ///
  /// [stage] and [failure] move together: a stage other than
  /// [OpeningStockStage.error] carries no failure, so a retry that reached the
  /// preview again cannot leave the previous attempt's failure behind for the
  /// next screen to find. The argument is still honoured when [stage] is left
  /// alone, which is how the error step is entered.
  ///
  /// [clearSaveError] is the one field that cannot be set by passing `null`,
  /// because an argument left out reads the same as one passed as `null` and a
  /// failed save has to be forgettable once a later one succeeds.
  OpeningStockState copyWith({
    OpeningStockStage? stage,
    String? fileName,
    int? fileSizeBytes,
    int? estimatedRowCount,
    bool? estimateTruncated,
    OpeningStockImportPhase? phase,
    OpeningStockPreview? preview,
    OpeningStockCommitResult? result,
    ImportJob? auditJob,
    OpeningStockFailure? failure,
    String? savedTo,
    Object? saveError,
    bool clearSaveError = false,
    bool? isPicking,
    bool? isSaving,
  }) {
    final nextStage = stage ?? this.stage;

    return OpeningStockState(
      stage: nextStage,
      fileName: fileName ?? this.fileName,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      estimatedRowCount: estimatedRowCount ?? this.estimatedRowCount,
      estimateTruncated: estimateTruncated ?? this.estimateTruncated,
      phase: phase ?? this.phase,
      preview: preview ?? this.preview,
      result: result ?? this.result,
      auditJob: auditJob ?? this.auditJob,
      failure: nextStage == OpeningStockStage.error
          ? failure ?? this.failure
          : null,
      saveError: clearSaveError ? null : saveError ?? this.saveError,
      isPicking: isPicking ?? this.isPicking,
      isSaving: isSaving ?? this.isSaving,
    );
  }
}

/// Drives the opening-stock import screen.
///
/// Every step that can fail wraps its own work in a catch and puts a
/// [OpeningStockFailure] on the state, so no path through this class can end in
/// a step that quietly does nothing: the screen always has either a next step or
/// a sentence.
@riverpod
class OpeningStockController extends _$OpeningStockController {
  /// The rows last read from the chosen file.
  ///
  /// Held on the notifier rather than in the state, because the screen never
  /// renders them again: what it has to do is survive until the commit, so the
  /// payload the server re-reads is the payload it classified. A field on this
  /// notifier is what keeps it per-instance.
  List<OpeningStockCsvRow> _rows = const <OpeningStockCsvRow>[];

  /// The chosen file's text, held so that uploading and retrying do not ask for
  /// the file a second time.
  String? _content;

  @override
  OpeningStockState build() => const OpeningStockState();

  /// Asks for a file, reads it, and stops on what it is.
  ///
  /// Nothing is sent from here: the owner sees the file's name, its size and a
  /// count of its first rows, and uploads it as a separate, deliberate act.
  Future<void> pickFile() async {
    state = const OpeningStockState(isPicking: true);

    try {
      final picked = await ref.read(openingStockFilePickerProvider).pick();
      if (!ref.mounted) {
        return;
      }
      if (picked == null) {
        // The user changed their mind: back to the offer, not an error.
        _content = null;
        _rows = const <OpeningStockCsvRow>[];
        state = const OpeningStockState();
        return;
      }

      final estimate = estimateOpeningStockRows(picked.content);
      _content = picked.content;
      state = OpeningStockState(
        stage: OpeningStockStage.confirmed,
        fileName: picked.fileName,
        fileSizeBytes: picked.byteLength,
        estimatedRowCount: estimate.rowCount,
        estimateTruncated: estimate.truncated,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      _content = null;
      state = state.copyWith(isPicking: false);
      _fail(OpeningStockImportPhase.reading, error);
    }
  }

  /// Reads the chosen file in full and has the server classify it.
  ///
  /// Separate from [pickFile] because the two failure modes stay distinct: a file
  /// this app cannot *read* never reaches the server, and a file the server will
  /// not accept comes back as row-numbered notes.
  Future<void> uploadAndPreview() async {
    final fileName = state.fileName;
    final content = _content;
    if (fileName == null || content == null) {
      // Unreachable from the screen - the upload button exists only on the
      // confirmed step, which cannot be reached without a file - and an explicit
      // failure rather than a silent return, so that a caller which reaches it
      // finds out instead of watching nothing happen.
      _fail(
        OpeningStockImportPhase.reading,
        const ValidationException(
          message: 'Choose a file before uploading one.',
          code: 'import/no-file',
        ),
      );
      return;
    }

    state = state.copyWith(
      stage: OpeningStockStage.processing,
      phase: OpeningStockImportPhase.reading,
    );

    // Where a throw came from, tracked as the work moves. The exception's own
    // type cannot say it: a file the CSV reader refuses and a file the server
    // refuses are both ordinary failures by the time they arrive here, and only
    // the parse reaching its end tells the two apart.
    var inRequest = false;

    try {
      // Synchronous, and read before the request rather than after: a write path
      // scoped by a pharmacy that has not arrived yet should say so instead of
      // sending a request the server can only refuse (D-015).
      ref.read(requirePharmacyIdProvider);
      final rows = parseOpeningStockCsv(content);

      if (!ref.mounted) {
        return;
      }
      _rows = rows;
      state = state.copyWith(phase: OpeningStockImportPhase.sending);

      // The request is created first and the step advanced after it, which is
      // what "sending is done" means here: the payload is in the transport's
      // hands from the moment the call is made, and everything the owner then
      // waits for is the server classifying a few dozen kilobytes of rows.
      final request = ref.read(openingStockRepositoryProvider).preview(rows);
      inRequest = true;
      state = state.copyWith(phase: OpeningStockImportPhase.classifying);
      final preview = await request;

      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        stage: OpeningStockStage.preview,
        preview: preview,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      _fail(_uploadPhase(inRequest: inRequest, error: error), error);
    }
  }

  /// Which step a throw out of [uploadAndPreview] belongs to.
  ///
  /// Before the request exists the file is at fault. Once it does, the two
  /// answers are told apart by whether anything came back, because the advice
  /// differs: nothing came back, so the answer is about the connection, where a
  /// server that answered and refused is an answer about the file.
  OpeningStockImportPhase _uploadPhase({
    required bool inRequest,
    required Object error,
  }) {
    if (!inRequest) {
      return OpeningStockImportPhase.reading;
    }
    return error is NetworkException || error is TimeoutException
        ? OpeningStockImportPhase.sending
        : OpeningStockImportPhase.classifying;
  }

  /// Writes the previewed file, in one transaction, or finds it already written.
  Future<void> commit() async {
    final preview = state.preview;
    final fileName = state.fileName;
    if (preview == null || fileName == null || !preview.summary.canImport) {
      // Also unreachable from the screen: the import button is disabled unless
      // `canCommit`, which requires all three of these.
      _fail(
        OpeningStockImportPhase.writing,
        const ValidationException(
          message: 'There is nothing ready to import.',
          code: 'import/nothing-to-commit',
        ),
      );
      return;
    }

    state = state.copyWith(
      stage: OpeningStockStage.committing,
      phase: OpeningStockImportPhase.writing,
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
      state = state.copyWith(stage: OpeningStockStage.success, result: result);
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      _fail(OpeningStockImportPhase.writing, error);
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
      _saveFailure(
        const ValidationException(
          message: 'There is no finished import to save yet.',
          code: 'import/nothing-to-save',
        ),
      );
      return;
    }

    state = state.copyWith(isSaving: true, clearSaveError: true);

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
      state = state.copyWith(
        auditJob: job,
        savedTo: saved ?? state.savedTo,
        isSaving: false,
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(isSaving: false);
      _saveFailure(error);
    }
  }

  /// Tries the failed step again, from whatever the screen still holds.
  ///
  /// A failed write is retried as a write, because the preview and the rows are
  /// still in hand. A failed check is retried as an upload. A file that could not
  /// be read at all leaves nothing to retry, so the picker reopens - which is the
  /// only way back from a file the platform handed over empty.
  Future<void> retry() {
    if (state.failure?.phase == OpeningStockImportPhase.writing) {
      return commit();
    }
    if (_content == null) {
      return pickFile();
    }
    return uploadAndPreview();
  }

  /// Back to the offer, discarding the chosen file and the preview.
  void reset() {
    _rows = const <OpeningStockCsvRow>[];
    _content = null;
    state = const OpeningStockState();
  }

  /// Moves to the failure step, keeping whatever the screen still needs.
  ///
  /// The chosen file, its size and the preview all survive, because the retry
  /// that follows needs them: pressing "Try again" must not ask the owner to pick
  /// the same file a second time.
  void _fail(OpeningStockImportPhase phase, Object error) {
    state = state.copyWith(
      stage: OpeningStockStage.error,
      failure: OpeningStockFailure(
        phase: phase,
        error: error,
        rowNumber: error is OpeningStockCsvException ? error.rowNumber : null,
      ),
    );
  }

  /// Adds a line about a failed audit download, without leaving the summary.
  void _saveFailure(Object error) {
    state = state.copyWith(saveError: error);
  }
}
