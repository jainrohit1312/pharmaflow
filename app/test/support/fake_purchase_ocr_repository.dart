/// A [PurchaseOcrRepository] that records what it was asked and can be told to
/// fail.
///
/// It runs the **real** upload rules (`PurchaseOcrRepository.validatePick`) and
/// builds the **real** path shape, so a controller or screen that skips a check
/// the write enforces fails here rather than in front of a user. Failures are
/// listed per attempt rather than being one-shot: a retry is a second call, and a
/// single flag could not say "busy, then fine".
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';

/// A fake bill reader.
class FakePurchaseOcrRepository implements PurchaseOcrRepository {
  /// Creates a fake that answers with [bill], or a canned envelope when null.
  FakePurchaseOcrRepository({OcrPurchaseBill? bill})
    : bill = bill ?? buildOcrBill();

  /// What every successful parse answers with.
  ///
  /// Mutable on purpose: a test of a *second* read has to change what the reader
  /// says between the two, or it cannot tell a form that re-seeded itself from one
  /// still showing the first parse.
  OcrPurchaseBill bill;

  /// Failures `uploadBill` throws, one per call; `null` entries succeed.
  final List<Exception?> uploadFailures = <Exception?>[];

  /// Failures `parseBill` throws, one per call; `null` entries succeed.
  ///
  /// An empty list succeeds every time, and a list that runs out keeps using its
  /// last entry — so "busy twice, then fine" is `[busy, busy, null]` and "busy
  /// for ever" is `[busy]`.
  final List<Exception?> parseFailures = <Exception?>[];

  /// How many uploads have been asked for.
  int uploads = 0;

  /// How many reads have been asked for.
  int parses = 0;

  /// The tenant each upload was scoped to.
  final List<String> uploadedFor = <String>[];

  /// The path each read was asked about.
  final List<String> parsedPaths = <String>[];

  /// The bytes of the last upload.
  List<int>? lastBytes;

  /// The mime type of the last upload.
  String? lastMimeType;

  /// The name the last upload was stored under.
  String? lastFileName;

  @override
  Future<String> uploadBill({
    required String pharmacyId,
    required List<int> bytes,
    required String mimeType,
    String? fileName,
    DateTime? now,
  }) async {
    uploads++;
    uploadedFor.add(pharmacyId);
    lastBytes = bytes;
    lastMimeType = mimeType;
    lastFileName = fileName;

    // The real rule, so skipping it is not an option.
    final refusal = PurchaseOcrRepository.validatePick(
      mimeType: mimeType,
      sizeInBytes: bytes.length,
    );
    if (refusal != null) {
      throw ValidationException(message: refusal);
    }

    final failure = _next(uploadFailures);
    if (failure != null) {
      throw failure;
    }

    return PurchaseOcrRepository.storagePath(
      pharmacyId: pharmacyId,
      now: now ?? DateTime(2026, 9, 19),
      fileName:
          fileName ??
          PurchaseOcrRepository.newBillFileName(
            mimeType: mimeType,
            now: now ?? DateTime(2026, 9, 19),
            nonce: 42,
          ),
    );
  }

  @override
  Future<OcrPurchaseBill> parseBill({required String storagePath}) async {
    parses++;
    parsedPaths.add(storagePath);

    final failure = _next(parseFailures);
    if (failure != null) {
      throw failure;
    }
    return bill;
  }

  /// The next scripted failure: consumed in order, and the last one repeats.
  Exception? _next(List<Exception?> queue) {
    if (queue.isEmpty) {
      return null;
    }
    if (queue.length == 1) {
      return queue.first;
    }
    return queue.removeAt(0);
  }
}

/// Builds an envelope shaped like the one the deployed function returns.
///
/// The default is Chunk B1's observed body, so tests fail against the wire format
/// the app actually receives rather than one it wishes it received.
OcrPurchaseBill buildOcrBill({
  List<OcrLine> lines = const <OcrLine>[],
  OcrDocument? document,
  OcrMeta? meta,
}) {
  final defaultLines = lines.isEmpty
      ? <OcrLine>[
          OcrLine(
            rawName: 'Dolo 650 Tab 15s',
            qty: 10,
            freeQty: 1,
            rate: 100,
            mrp: 150,
            gstPercent: 12,
            batchNo: 'D650-A21',
            // A real bill prints an expiry, and the verify screen's line editor
            // requires one: a bill without it is a bill nobody could receive.
            expiryDate: DateTime(2027, 6, 30),
            hsnCode: '3004',
            confidence: 0.95,
          ),
        ]
      : lines;

  return OcrPurchaseBill(
    document:
        document ??
        const OcrDocument(
          supplierName: 'ARIHANT DISTRIBUTORS',
          invoiceNo: 'INV-2026-0042',
          subTotal: 2420,
          taxTotal: 264.5,
          grandTotal: 2684.5,
        ),
    lines: defaultLines,
    meta:
        meta ?? const OcrMeta(model: 'gemini-3.6-flash', finishReason: 'STOP'),
  );
}

/// The failure a busy reader produces (D-032's retryable code).
ServerException busyReaderFailure() => const ServerException(
  message: 'The bill reader is busy right now. Try again in a moment.',
  code: 'provider_unavailable',
);

/// The failure an unreadable bill produces (not retryable).
NotFoundException unreadableBillFailure() => const NotFoundException(
  message: 'That bill could not be read.',
  code: 'not_found',
);
