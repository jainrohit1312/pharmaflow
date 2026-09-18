/// WhatsApp invoice delivery contract (phase 5) — not yet wired up.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// TODO(phase-5): send invoices through the WhatsApp Business API.

/// Sends invoices to customers over WhatsApp.
abstract class WhatsappService {
  /// Sends [message] to [phone], optionally attaching [documentUrl].
  Future<void> sendInvoice({
    required String phone,
    required String message,
    String? documentUrl,
  });

  /// Whether WhatsApp is usable on this device right now.
  Future<bool> isAvailable();
}

/// A [WhatsappService] whose methods all throw [UnimplementedError].
class UnimplementedWhatsappService implements WhatsappService {
  /// Creates the placeholder implementation.
  const UnimplementedWhatsappService();

  /// Throws [UnimplementedError] until phase 5 lands.
  @override
  Future<void> sendInvoice({
    required String phone,
    required String message,
    String? documentUrl,
  }) {
    throw UnimplementedError('TODO(phase-5)');
  }

  /// Throws [UnimplementedError] until phase 5 lands.
  @override
  Future<bool> isAvailable() {
    throw UnimplementedError('TODO(phase-5)');
  }
}

/// The app-wide [WhatsappService].
final Provider<WhatsappService> whatsappServiceProvider =
    Provider<WhatsappService>((ref) => const UnimplementedWhatsappService());
