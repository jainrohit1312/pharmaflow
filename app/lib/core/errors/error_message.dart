/// Turns any thrown object into a sentence worth showing the user.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;

/// A message safe to show the user for [error].
///
/// An [AppException] already carries a sentence written for the user, so its
/// `message` is used; anything else is reported by its `toString()`.
///
/// [ProviderException] is unwrapped first, and the unwrapping loops because
/// Riverpod can nest them. Riverpod 3 wraps whatever a provider threw before
/// handing it to a provider that watches it, so a screen would otherwise render
/// Riverpod's developer-facing dump ("Tried to use a provider that is in error
/// state...") in place of the sentence the app deliberately wrote.
String describeError(Object error) {
  var current = error;
  while (current is ProviderException) {
    current = current.exception;
  }
  return current is AppException ? current.message : current.toString();
}
