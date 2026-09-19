/// Data access for the bill reader: the image goes up, the parse comes back.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/services/ocr_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'purchase_ocr_repository.g.dart';

/// Exposes the single [PurchaseOcrRepository] used by the OCR feature.
@riverpod
PurchaseOcrRepository purchaseOcrRepository(Ref ref) => PurchaseOcrRepository(
  ref.watch(supabaseClientProvider),
  ref.watch(ocrServiceProvider),
);

/// Uploads a picked bill, and asks the reader what it says.
///
/// Two steps rather than one on purpose: the screen shows the image while it is
/// being read, and "read it again" (D-032's retry) must not upload a second copy
/// of the same bill.
class PurchaseOcrRepository {
  /// Creates a repository over the shared client and the reader behind it.
  PurchaseOcrRepository(this._client, this._ocr);

  /// The private bucket bills live in (migration 00022, D-028).
  static const String bucket = 'purchase-bills';

  /// The largest bill the bucket accepts, in bytes.
  ///
  /// Mirrors the bucket's own `file_size_limit`. The bucket remains the
  /// authority — this mirror exists so a 40 MB photo is refused with a sentence
  /// rather than after uploading it over a phone connection.
  static const int maxBillBytes = 10 * 1024 * 1024;

  /// The mime types the bucket accepts.
  ///
  /// Mirrors `storage.buckets.allowed_mime_types` for the same reason.
  static const List<String> allowedMimeTypes = <String>[
    'image/jpeg',
    'image/png',
    'image/webp',
    'application/pdf',
  ];

  /// Extensions accepted, keyed by the mime type they belong to.
  static const Map<String, String> _extensionByMime = <String, String>{
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'application/pdf': 'pdf',
  };

  /// The same table the other way round, for a file that arrived untyped.
  static const Map<String, String> _mimeByExtension = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'pdf': 'application/pdf',
  };

  final sb.SupabaseClient _client;
  final OcrService _ocr;

  /// Why [mimeType] and [sizeInBytes] cannot be uploaded, or `null` when they can.
  ///
  /// Both halves are checked here rather than at the bucket, so the same rule
  /// answers on the screen (immediately, as the user picks) and inside the write
  /// (so a screen that forgets to ask cannot upload something the bucket will
  /// only refuse afterwards).
  static String? validatePick({
    required String? mimeType,
    required int sizeInBytes,
  }) {
    if (mimeType == null || mimeType.trim().isEmpty) {
      return 'That file has no type, so the reader cannot open it. Pick a photo '
          'or a PDF.';
    }
    if (!allowedMimeTypes.contains(mimeType)) {
      return 'The reader opens JPEG, PNG, WebP and PDF bills, not '
          '${mimeType.split('/').last.toUpperCase()}.';
    }
    if (sizeInBytes <= 0) {
      return 'That file is empty.';
    }
    if (sizeInBytes > maxBillBytes) {
      return 'That bill is larger than 10 MB. Photograph it at a smaller size.';
    }
    return null;
  }

  /// The file extension for [mimeType].
  ///
  /// Only called with a mime type [validatePick] has already accepted.
  static String extensionFor(String mimeType) =>
      _extensionByMime[mimeType] ?? 'bin';

  /// The mime type [fileName] suggests, or `null` for an unknown extension.
  ///
  /// `image_picker` reports a file's type only on some platforms (`XFile.mimeType`
  /// is frequently null outside a browser), so a bill that arrives without a type
  /// is typed from its extension rather than refused as "no type at all". `jpeg`
  /// and `jpg` are both accepted because both are common.
  static String? mimeForFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot < 0
        ? null
        : _mimeByExtension[fileName.substring(dot + 1).toLowerCase()];
  }

  /// A collision-resistant file name for a newly picked bill.
  ///
  /// The uuid Postgres would generate is not available to the client (the repo
  /// has no uuid package), so the name is the epoch millisecond plus a random
  /// suffix: unique in practice, and readable in a bucket listing. [nonce] exists
  /// so a test can pin the name.
  static String newBillFileName({
    required String mimeType,
    required DateTime now,
    int? nonce,
  }) =>
      'bill-${now.toUtc().millisecondsSinceEpoch}-'
      '${nonce ?? Random().nextInt(1 << 30)}.${extensionFor(mimeType)}';

  /// The object path for a bill (D-028: the first segment is the tenant).
  static String storagePath({
    required String pharmacyId,
    required DateTime now,
    required String fileName,
  }) => '$pharmacyId/${now.year}/$fileName';

  /// Uploads [bytes] and returns the object's path.
  ///
  /// The path's first segment is [pharmacyId], which the storage policy compares
  /// with `get_my_pharmacy_id()` — so an upload for another tenant is refused by
  /// the database rather than by this method.
  Future<String> uploadBill({
    required String pharmacyId,
    required List<int> bytes,
    required String mimeType,
    String? fileName,
    DateTime? now,
  }) async {
    final refusal = validatePick(mimeType: mimeType, sizeInBytes: bytes.length);
    if (refusal != null) {
      throw ValidationException(message: refusal);
    }

    final timestamp = now ?? DateTime.now();
    final path = storagePath(
      pharmacyId: pharmacyId,
      now: timestamp,
      fileName: fileName ?? newBillFileName(mimeType: mimeType, now: timestamp),
    );

    try {
      await _client.storage
          .from(bucket)
          .uploadBinary(
            path,
            _asBytes(bytes),
            fileOptions: sb.FileOptions(contentType: mimeType),
          );
      return path;
    } on sb.StorageException catch (error) {
      throw _storageFailure(error);
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Could not upload that bill.',
        cause: error,
      );
    }
  }

  /// What the reader makes of the bill already at [storagePath].
  Future<OcrPurchaseBill> parseBill({required String storagePath}) =>
      _ocr.parsePurchaseBill(storagePath: storagePath);
}

/// The exception for a storage refusal.
///
/// A refusal the bucket makes about the *file* — too large, wrong type — is
/// something the user can fix by choosing differently, so it is a validation
/// failure; anything else is the server's problem. Either way the bucket's own
/// sentence is kept: it is the only description of what actually went wrong.
AppException _storageFailure(sb.StorageException error) {
  const fixable = <String>{'400', '413', '415'};
  final message = error.message.trim().isEmpty
      ? 'Could not upload that bill.'
      : error.message;

  return fixable.contains(error.statusCode)
      ? ValidationException(message: message, code: error.statusCode)
      : ServerException(message: message, code: error.statusCode, cause: error);
}

/// [bytes] as the byte buffer the storage client wants.
///
/// The caller is `image_picker`, which hands back a `Uint8List` — but the
/// repository's signature says `List<int>` so a test can pass a plain list, and
/// this is the one place that difference is absorbed.
Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
