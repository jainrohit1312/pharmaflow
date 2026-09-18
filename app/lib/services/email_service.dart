/// Transactional email contract (phase 5) — abstract surface, not wired up.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// TODO(phase-5): send mail through the Supabase edge function.

/// Sends transactional email from the app.
///
/// Deliberately a single-method interface: it is a forward-looking service
/// boundary that phase 5 will widen (attachments, templates, retries).
// ignore: one_member_abstracts
abstract class EmailService {
  /// Sends [body] to [to] under [subject].
  Future<void> send({
    required String to,
    required String subject,
    required String body,
  });
}

/// An [EmailService] whose only method throws [UnimplementedError].
class UnimplementedEmailService implements EmailService {
  /// Creates the placeholder implementation.
  const UnimplementedEmailService();

  /// Throws [UnimplementedError] until phase 5 lands.
  @override
  Future<void> send({
    required String to,
    required String subject,
    required String body,
  }) {
    throw UnimplementedError('TODO(phase-5)');
  }
}

/// The app-wide [EmailService].
final Provider<EmailService> emailServiceProvider = Provider<EmailService>(
  (ref) => const UnimplementedEmailService(),
);
