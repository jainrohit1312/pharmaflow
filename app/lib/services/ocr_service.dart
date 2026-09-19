/// The bill reader, as the app sees it: one function call and one envelope.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/function_error.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'ocr_service.g.dart';

/// The code a transport failure carries: the request never reached the reader.
const String unreachableOcrCode = 'unreachable';

/// The code the function gives a provider failure worth trying again (D-032).
const String providerUnavailableOcrCode = 'provider_unavailable';

/// The app-wide [OcrService].
///
/// A generated provider rather than the hand-written one the stub carried: D-1
/// listed the manual service providers as "convert to `@riverpod` when the
/// respective feature is built", and this is that feature's turn.
@riverpod
OcrService ocrService(Ref ref) =>
    SupabaseOcrService(ref.watch(supabaseClientProvider));

/// Turns a purchase-bill image into the data a purchase can be built from.
///
/// Deliberately a single-method interface: it is the boundary between the app and
/// one deployed function, and Chunk C widens it (product matching) rather than
/// this chunk inventing methods nothing calls.
// ignore: one_member_abstracts
abstract class OcrService {
  /// Reads the bill stored at [storagePath] and returns what it says.
  ///
  /// [storagePath] is an object in the `purchase-bills` bucket
  /// (`<pharmacy_id>/<year>/<file>`, D-028), not a URL: the function reads the
  /// bytes with the caller's own credentials, so nothing has to be public.
  ///
  /// Throws an [AppException]: a [ValidationException] for a bill the reader
  /// refused to look at, a [NotFoundException] for one it could not read, an
  /// [AuthException] for a caller with no pharmacy, and a [ServerException] —
  /// code [providerUnavailableOcrCode] — when the reader is busy. That last one
  /// is the only failure worth retrying; [isRetryableOcrError] is the one place
  /// that decides.
  Future<OcrPurchaseBill> parsePurchaseBill({required String storagePath});
}

/// An [OcrService] backed by the deployed `ocr-purchase-bill` function.
class SupabaseOcrService implements OcrService {
  /// Creates the service over the shared Supabase client.
  SupabaseOcrService(this._client);

  /// The name of the deployed function.
  static const String functionName = 'ocr-purchase-bill';

  final sb.SupabaseClient _client;

  @override
  Future<OcrPurchaseBill> parsePurchaseBill({
    required String storagePath,
  }) async {
    try {
      final response = await _client.functions.invoke(
        functionName,
        body: <String, dynamic>{'path': storagePath},
      );
      return decodeOcrBill(response.data);
    } on sb.FunctionsFetchException catch (error) {
      // Status 0: nothing came back at all, which is a connection problem rather
      // than the reader's answer, so it has its own code.
      throw NetworkException(
        message:
            'Could not reach the bill reader. Check the connection and try '
            'again.',
        code: unreachableOcrCode,
        cause: error,
      );
    } on sb.FunctionException catch (error) {
      throw ocrException(
        error.details,
        status: error.status,
        fallbackMessage: 'Unable to read that bill.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(message: 'Unable to read that bill.', cause: error);
    }
  }
}

/// The bill inside a successful response.
///
/// Pure, so a test can drive it with the bodies that matter: the one the function
/// promises, and the ones it might send anyway.
OcrPurchaseBill decodeOcrBill(Object? data) {
  if (data is Map) {
    return OcrPurchaseBill.fromJson(data.cast<String, dynamic>());
  }
  throw const ServerException(
    message: 'The bill reader answered with something unexpected. Try again.',
    code: 'unexpected_response',
  );
}

/// The exception for a failure the function described.
///
/// The mapping itself lives in [functionException], because every function here
/// refuses in the same envelope and two readers of it would drift. What stays
/// here is the part that is the reader's own: the fallback sentence.
AppException ocrException(
  Object? details, {
  required String fallbackMessage,
  int? status,
}) => functionException(
  details,
  fallbackMessage: fallbackMessage,
  status: status,
);

/// Whether [error] is worth waiting a moment and trying again.
///
/// Only two things are: the reader being busy (D-032's `provider_unavailable`,
/// which the free-tier quota produces as a `503`), and the request never reaching
/// it. Everything else — a bill the reader refused, a bill it could not find, a
/// missing secret — will fail the same way twice, and a retry would only make the
/// user wait for the same sentence.
bool isRetryableOcrError(Object? error) =>
    error is AppException &&
    (error.code == providerUnavailableOcrCode ||
        error.code == unreachableOcrCode);
