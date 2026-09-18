/// Purchase-bill OCR contract (phase 5) — abstract surface, not yet wired up.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// TODO(phase-5): parse supplier purchase bills from images.

/// Turns a purchase-bill image into structured draft data.
///
/// Deliberately a single-method interface: it is a forward-looking service
/// boundary that phase 5 will widen (line items, supplier matching, totals).
// ignore: one_member_abstracts
abstract class OcrService {
  /// Extracts the bill at [imageUrl] into a map of parsed fields.
  Future<Map<String, dynamic>> parsePurchaseBill({required String imageUrl});
}

/// An [OcrService] whose only method throws [UnimplementedError].
class UnimplementedOcrService implements OcrService {
  /// Creates the placeholder implementation.
  const UnimplementedOcrService();

  /// Throws [UnimplementedError] until phase 5 lands.
  @override
  Future<Map<String, dynamic>> parsePurchaseBill({required String imageUrl}) {
    throw UnimplementedError('TODO(phase-5)');
  }
}

/// The app-wide [OcrService].
final Provider<OcrService> ocrServiceProvider = Provider<OcrService>(
  (ref) => const UnimplementedOcrService(),
);
