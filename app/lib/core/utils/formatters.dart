/// Locale-aware formatters for currency, dates and times.
library;

import 'package:intl/intl.dart';

/// Indian-locale formatting helpers.
///
/// Every formatter is created once and cached in a `static final` field, since
/// `NumberFormat`/`DateFormat` construction is comparatively expensive and
/// these are called from list builders.
abstract final class Formatters {
  /// Formats [amount] as Indian-grouped rupees, e.g. `₹1,23,456.00`.
  static String currency(num amount) => _currency.format(amount);

  /// Formats [date] as `18/09/2026`.
  static String dateDdMmYyyy(DateTime date) => _ddMmYyyy.format(date);

  /// Formats [date] as `18 Sep 2026`.
  static String dateDdMmmYyyy(DateTime date) => _ddMmmYyyy.format(date);

  /// Formats [d] as `18 Sep 2026 14:05`.
  static String dateTimeDdMmmYyyyHm(DateTime d) => _ddMmmYyyyHm.format(d);

  /// Formats [d] as `14:05` using the 24-hour clock.
  static String timeHm(DateTime d) => _hm.format(d);

  /// Formats [d] as `18/09/2026`, or returns `null` when [d] is `null`.
  static String? dateDdMmYyyyOrNull(DateTime? d) =>
      d == null ? null : _ddMmYyyy.format(d);

  /// Formats [date] as the `YYYY-MM-DD` a Postgres `date` column expects.
  ///
  /// Used for query parameters and inserts, not for display: PostgREST compares a
  /// `date` column against this string, and a full timestamp would silently
  /// compare as a different day.
  static String dateIso(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );
  static final DateFormat _ddMmYyyy = DateFormat('dd/MM/yyyy');
  static final DateFormat _ddMmmYyyy = DateFormat('dd MMM yyyy');
  static final DateFormat _ddMmmYyyyHm = DateFormat('dd MMM yyyy HH:mm');
  static final DateFormat _hm = DateFormat('HH:mm');
}
