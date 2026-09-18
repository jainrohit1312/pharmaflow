/// Entry point of the PharmaFlow application.
///
/// Everything happens in `bootstrap()`: this file stays a one-liner so tooling
/// and tests can import the boot sequence without calling `runApp`.
library;

import 'package:app/bootstrap.dart';

/// Starts PharmaFlow.
void main() => bootstrap();
