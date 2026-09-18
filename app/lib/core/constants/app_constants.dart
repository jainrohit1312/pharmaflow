/// Application-wide constants shared by every layer of the PharmaFlow client.
library;

/// Static configuration values that are stable for the lifetime of the app.
abstract final class AppConstants {
  /// Human readable application name shown in the UI and app switchers.
  static const String appName = 'PharmaFlow';

  /// Semantic version reported in the UI and in support diagnostics.
  static const String appVersion = '1.0.0';

  /// Width (in logical pixels) below which the shell drops the navigation rail
  /// and renders a bottom navigation bar instead.
  static const double mobileBreakpoint = 700;

  /// Width (in logical pixels) at or above which the navigation rail is drawn
  /// in its extended, labelled form.
  static const double extendedRailBreakpoint = 1200;

  /// Default timeout applied to outbound Supabase requests.
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Debounce applied to rapid auth-state emissions before the navigation
  /// graph is rebuilt, avoiding redirect flicker on token refresh.
  static const Duration authStateDebounce = Duration(milliseconds: 250);
}
