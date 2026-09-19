/// The catalogue matcher, as the app sees it: one call for a whole bill, and one
/// write that records what the human confirmed.
///
/// Two halves of one capability, deliberately in one place. `matchBill` asks the
/// deployed `match-product` function what the lines of a bill might be;
/// `learnAliases` tells the database what the human decided, through the
/// `learn_product_aliases` RPC (migration 00024). They are the ask and the answer,
/// and a screen that suggests without ever teaching would be a matcher that never
/// gets better.
///
/// **The suggestion is asked for in one batch.** A twenty-line bill is one round
/// trip and one embedding request — not one per line — because the model key is on
/// a free tier (N-2, D-036) and because the three legs then rank every line
/// against the same catalogue snapshot.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/function_error.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/product_match.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'match_service.g.dart';

/// The code a transport failure carries: the request never reached the matcher.
///
/// Its own code rather than the reader's, because the two failures are different
/// situations with different retries: a bill that could not be read is a job the
/// user has to redo, while suggestions that could not be fetched are a convenience
/// that quietly did not happen.
const String unreachableMatchCode = 'unreachable';

/// The app-wide [MatchService].
@riverpod
MatchService matchService(Ref ref) =>
    SupabaseMatchService(ref.watch(supabaseClientProvider));

/// One line of a bill, as the matcher wants it.
class MatchLineRequest {
  /// Creates a line to match.
  const MatchLineRequest({this.rawName, this.supplierId});

  /// The invoice text as printed, or `null` for a line with nothing readable.
  ///
  /// Sent as printed — whitespace-collapsed by the function, never normalized —
  /// because the model reads the words the supplier actually used (D-037).
  final String? rawName;

  /// The supplier the bill names, when the user has chosen one.
  ///
  /// This is *not* the tenant: the pharmacy is derived from the caller's identity
  /// on the server (D-004). A supplier id only scopes which learned aliases may
  /// answer.
  final String? supplierId;

  /// This line as the function reads it.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'raw_name': rawName,
    'supplier_id': supplierId,
  };
}

/// One invoice text a human confirmed means one product.
class ConfirmedAlias {
  /// Creates a confirmation to record.
  const ConfirmedAlias({
    required this.rawName,
    required this.productId,
    this.supplierId,
  });

  /// The text exactly as the bill printed it.
  final String rawName;

  /// The product the human chose for it.
  final String productId;

  /// The bill's supplier, when it has one. The server decides what to do with a
  /// supplier it does not recognise.
  final String? supplierId;

  /// This confirmation as the RPC reads it.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'raw_name': rawName,
    'product_id': productId,
    'supplier_id': supplierId,
  };
}

/// Turns invoice text into catalogue candidates, and confirms the choices back.
abstract class MatchService {
  /// The ranked candidates for each line of one bill, aligned by position.
  ///
  /// Throws an [AppException]: a [NetworkException] (code
  /// [unreachableMatchCode]) when nothing came back, and whatever
  /// [matchException] makes of a refusal. A caller offering suggestions treats
  /// every one of them as "no suggestions this time" — the vector leg is an
  /// enhancement and a matcher that fails a bill because the catalogue could not
  /// be searched would be worse than one that suggests nothing for a moment.
  Future<ProductMatches> matchBill({required List<MatchLineRequest> lines});

  /// Records what the human confirmed, and returns how many aliases were learned.
  ///
  /// Best effort by contract: this is called *after* a purchase is saved, so a
  /// caller must never let a failure here fail anything. The server skips
  /// anything it cannot use — blank text, a product that is not this pharmacy's, a
  /// supplier it does not recognise — and answers rather than raising.
  Future<int> learnAliases({required List<ConfirmedAlias> aliases});
}

/// A [MatchService] backed by the deployed function and the learning RPC.
class SupabaseMatchService implements MatchService {
  /// Creates the service over the shared Supabase client.
  SupabaseMatchService(this._client);

  /// The name of the deployed function.
  static const String functionName = 'match-product';

  /// The RPC that records confirmed aliases (migration 00024).
  static const String learnRpcName = 'learn_product_aliases';

  final sb.SupabaseClient _client;

  @override
  Future<ProductMatches> matchBill({
    required List<MatchLineRequest> lines,
  }) async {
    try {
      final response = await _client.functions.invoke(
        functionName,
        body: <String, dynamic>{
          'lines': <Map<String, dynamic>>[
            for (final line in lines) line.toJson(),
          ],
        },
      );
      return decodeProductMatches(response.data);
    } on sb.FunctionsFetchException catch (error) {
      // Status 0: nothing came back at all, which is a connection problem rather
      // than the matcher's answer, so it has its own code.
      throw NetworkException(
        message:
            'Could not reach the catalogue matcher. Check the connection and try '
            'again.',
        code: unreachableMatchCode,
        cause: error,
      );
    } on sb.FunctionException catch (error) {
      throw matchException(error.details, status: error.status);
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to look for matches in the catalogue.',
        cause: error,
      );
    }
  }

  @override
  Future<int> learnAliases({required List<ConfirmedAlias> aliases}) async {
    if (aliases.isEmpty) {
      // Nothing to teach, and no round trip for a bill nobody picked from.
      return 0;
    }

    try {
      final data = await _client.rpc<dynamic>(
        learnRpcName,
        params: <String, dynamic>{
          'p_aliases': <Map<String, dynamic>>[
            for (final alias in aliases) alias.toJson(),
          ],
        },
      );
      return decodeLearnedAliases(data);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record what was confirmed on that bill.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record what was confirmed on that bill.',
        cause: error,
      );
    }
  }
}

/// The matches inside a successful response.
///
/// Pure, so a test can drive it with the bodies that matter: the one the function
/// promises, and the ones it might send anyway.
ProductMatches decodeProductMatches(Object? data) {
  if (data is Map) {
    return ProductMatches.fromJson(data.cast<String, dynamic>());
  }
  throw const ServerException(
    message:
        'The catalogue matcher answered with something unexpected. Try again.',
    code: 'unexpected_response',
  );
}

/// How many aliases a learning write recorded.
///
/// Pure, and strict about the envelope: a reply that is not `{ learned: n, … }`
/// means the write did not happen, and saying so is more honest than reporting
/// zero learned aliases as though the database had agreed.
int decodeLearnedAliases(Object? data) {
  if (data is Map && data['learned'] is num) {
    return (data['learned'] as num).toInt();
  }
  throw const ServerException(
    message: 'The catalogue could not be told what was confirmed.',
    code: 'unexpected_response',
  );
}

/// The exception for a failure the matcher described.
///
/// The mapping is [functionException]'s — one function, one envelope, one reader.
/// What this adds is the matcher's own fallback sentence, so its two call sites
/// cannot describe the same failure in two ways.
AppException matchException(Object? details, {int? status}) =>
    functionException(
      details,
      fallbackMessage: 'Unable to look for matches in the catalogue.',
      status: status,
    );
