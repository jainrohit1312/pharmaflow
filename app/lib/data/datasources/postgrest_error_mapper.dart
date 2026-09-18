/// Translates PostgREST failures into PharmaFlow's own exception hierarchy.
///
/// Repositories share this so that the presentation layer never sees a Supabase
/// exception type, and so the same database error is reported the same way from
/// every feature. The messages stay with the caller: "that code already exists"
/// differs per entity, so only the classification is shared.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Postgres error code for a unique constraint violation.
const String _uniqueViolation = '23505';

/// Postgres error code for a check constraint violation.
const String _checkViolation = '23514';

/// PostgREST code returned when a `single()` row does not exist.
const String _noRows = 'PGRST116';

/// Classifies [error] into an [AppException].
///
/// [fallbackMessage] is used when the failure carries nothing the user should
/// read. [uniqueViolationMessage] should name the clashing field; when it is
/// omitted, a unique violation falls back to [fallbackMessage].
AppException mapPostgrestException(
  sb.PostgrestException error, {
  required String fallbackMessage,
  String? uniqueViolationMessage,
}) {
  final code = error.code;
  final message = error.message.isEmpty ? fallbackMessage : error.message;

  return switch (code) {
    _uniqueViolation => ValidationException(
      message: uniqueViolationMessage ?? fallbackMessage,
      code: code,
      cause: error,
    ),
    // Raised by the Phase 2 stock triggers when a movement would drive a batch
    // negative, among others. Surfacing the database's own message is the most
    // useful thing to show: it names the batch and the item.
    _checkViolation => ValidationException(
      message: message,
      code: code,
      cause: error,
    ),
    _noRows => NotFoundException(
      message: 'That record no longer exists.',
      code: code,
      cause: error,
    ),
    _ => ServerException(message: message, code: code, cause: error),
  };
}
