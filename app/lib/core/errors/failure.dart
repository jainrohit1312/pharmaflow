/// Freezed union describing every failure that reaches the presentation layer.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'failure.freezed.dart';

/// A UI-safe description of something that went wrong.
///
/// Failures are value objects: screens pattern-match on the variant to pick an
/// icon, message and retry affordance without depending on SDK error types.
@freezed
sealed class Failure with _$Failure {
  /// The user is not (or is no longer) authenticated, or lacks permission.
  const factory Failure.auth({
    required String message,
    StackTrace? stackTrace,
  }) = AuthFailure;

  /// The request never reached the backend (offline, DNS, timeout).
  const factory Failure.network({
    required String message,
    StackTrace? stackTrace,
  }) = NetworkFailure;

  /// The backend answered with an error status or an unusable payload.
  const factory Failure.server({
    required String message,
    String? code,
    StackTrace? stackTrace,
  }) = ServerFailure;

  /// Client-side validation rejected the submitted values.
  const factory Failure.validation({
    required String message,
    StackTrace? stackTrace,
  }) = ValidationFailure;

  /// Anything that could not be classified into a more specific variant.
  const factory Failure.unknown({
    required String message,
    StackTrace? stackTrace,
  }) = UnknownFailure;
}

/// Maps an arbitrary [error] onto the closest [Failure] variant.
///
/// [AppException] subclasses keep their message, code and (optional)
/// [stackTrace]; every other object is reported as [Failure.unknown] using its
/// `toString()`.
Failure failureFromException(Object error, [StackTrace? stackTrace]) {
  if (error is AppException) {
    return switch (error) {
      AuthException(:final message) => Failure.auth(
        message: message,
        stackTrace: stackTrace,
      ),
      NetworkException(:final message) => Failure.network(
        message: message,
        stackTrace: stackTrace,
      ),
      ServerException(:final message, :final code) => Failure.server(
        message: message,
        code: code,
        stackTrace: stackTrace,
      ),
      ValidationException(:final message) => Failure.validation(
        message: message,
        stackTrace: stackTrace,
      ),
      // There is no dedicated `notFound` variant, so a missing record keeps the
      // server semantics (and the backend error code) intact.
      NotFoundException(:final message, :final code) => Failure.server(
        message: message,
        code: code,
        stackTrace: stackTrace,
      ),
    };
  }
  return Failure.unknown(message: error.toString(), stackTrace: stackTrace);
}
