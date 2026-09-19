/// Reads the error envelope a deployed Edge Function answers with.
///
/// Every function in this project refuses in the same shape — `{ error: { code,
/// message } }`, written by `_shared/response.ts` — so the app reads it in exactly
/// one place. The alternative is two readers of one contract, which is how two
/// features end up describing the same provider failure in two dialects (the
/// reason `_shared/gemini.ts` exists on the other side of the wire).
///
/// The mapping is a pure function so a test can drive it with the bodies that
/// matter: the ones the functions promise, and the ones a gateway might send
/// instead.
library;

import 'dart:convert';

import 'package:app/core/errors/app_exception.dart';

/// The exception for a failure a function described.
///
/// The function's own sentence is kept verbatim: it is written for the user, the
/// way a `check_violation` from Postgres is, and a caller that rewrote it would be
/// inventing a message for a situation it does not know. The `code` travels with
/// it so a caller can act on a specific failure — `provider_unavailable` above
/// all — without matching on the sentence.
///
/// [fallbackMessage] is used when the body carries nothing readable, which is what
/// a gateway rejection or an empty body looks like. [status] is kept in the code
/// as `http_<status>` so the sentence a user sees can still be traced.
AppException functionException(
  Object? details, {
  required String fallbackMessage,
  int? status,
}) {
  final failure = _readFailure(details);

  if (failure == null) {
    return ServerException(
      message: fallbackMessage,
      code: status == null ? null : 'http_$status',
    );
  }

  return switch (failure.code) {
    'unauthorized' => AuthException(
      message: failure.message,
      code: failure.code,
    ),
    'invalid_request' || 'forbidden' || 'too_large' => ValidationException(
      message: failure.message,
      code: failure.code,
    ),
    'not_found' => NotFoundException(
      message: failure.message,
      code: failure.code,
    ),
    // `provider_unavailable`, `not_configured`, `internal` and anything a later
    // chunk adds: a server-side problem, reported in the server's words.
    _ => ServerException(message: failure.message, code: failure.code),
  };
}

/// The code and message inside an error body, when it holds one.
_FunctionFailure? _readFailure(Object? details) {
  final body = _asObject(details);
  if (body == null) {
    return null;
  }

  final error = _asObject(body['error']);
  final message = error == null ? null : _asText(error['message']);
  if (message == null) {
    return null;
  }

  return _FunctionFailure(
    code: _asText(error?['code']) ?? 'unknown',
    message: message,
  );
}

/// [value] as a JSON object, decoding it first when it arrived as text.
///
/// The client library hands back the decoded body for a non-2xx from the
/// function — but "the function" is not the only thing that can answer (a gateway
/// rejection has its own shape), so both forms are accepted rather than assumed.
Map<String, dynamic>? _asObject(Object? value) {
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// A trimmed string, or `null`.
String? _asText(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

/// A failure a function described.
class _FunctionFailure {
  const _FunctionFailure({required this.code, required this.message});

  final String code;
  final String message;
}
