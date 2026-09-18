/// Platform capability flags used for responsive and platform-aware layout.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// True when the app is compiled for the web (`dart2js`/`dartdevc`).
bool get isWeb => kIsWeb;

/// True on Windows, Linux and macOS desktop builds.
///
/// `Platform` is only reached after the `!kIsWeb` short-circuit: on the web
/// `dart:io` is patched with an unsupported stub whose getters throw when
/// touched, so the guard must stay outermost.
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// True on Android and iOS builds.
///
/// Guarded by `!kIsWeb` for the same reason as [isDesktop].
bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
