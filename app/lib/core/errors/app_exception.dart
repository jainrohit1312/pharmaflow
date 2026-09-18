/// Exception hierarchy thrown by PharmaFlow's data, service and domain layers.
library;

/// Base type for every error the app raises deliberately.
///
/// Data sources translate third-party errors (PostgREST, GoTrue, socket
/// failures) into one of the subclasses so that upper layers can react without
/// knowing which SDK produced the failure.
sealed class AppException implements Exception {
  /// Creates an app-level exception.
  const AppException({required this.message, this.code, this.cause});

  /// Human readable description that is safe to surface to the user.
  final String message;

  /// Stable machine readable identifier, e.g. `auth/invalid-credentials`.
  final String? code;

  /// The error this exception wraps, when one exists.
  final Object? cause;

  /// Formats this exception as `Type: message (code: ...) (cause: ...)`.
  String _describe(String type) {
    final buffer = StringBuffer('$type: $message');
    if (code != null) {
      buffer.write(' (code: $code)');
    }
    if (cause != null) {
      buffer.write(' (cause: $cause)');
    }
    return buffer.toString();
  }
}

/// Thrown when authentication or authorisation fails.
final class AuthException extends AppException {
  /// Creates an authentication exception.
  const AuthException({required super.message, super.code, super.cause});

  @override
  String toString() => _describe('AuthException');
}

/// Thrown when a request never reached the backend (offline, DNS, timeout).
final class NetworkException extends AppException {
  /// Creates a network exception.
  const NetworkException({required super.message, super.code, super.cause});

  @override
  String toString() => _describe('NetworkException');
}

/// Thrown when the backend answered with an error status or a bad payload.
final class ServerException extends AppException {
  /// Creates a server exception.
  const ServerException({required super.message, super.code, super.cause});

  @override
  String toString() => _describe('ServerException');
}

/// Thrown when client-side validation rejects user input.
final class ValidationException extends AppException {
  /// Creates a validation exception.
  const ValidationException({required super.message, super.code, super.cause});

  @override
  String toString() => _describe('ValidationException');
}

/// Thrown when a requested record does not exist or is not visible.
final class NotFoundException extends AppException {
  /// Creates a not-found exception.
  const NotFoundException({required super.message, super.code, super.cause});

  @override
  String toString() => _describe('NotFoundException');
}
