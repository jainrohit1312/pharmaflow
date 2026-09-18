/// Riverpod provider exposing the configured Supabase client.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'supabase_client.g.dart';

/// The single [SupabaseClient] created by `Supabase.initialize`.
///
/// Data sources depend on this provider rather than on the `Supabase` singleton
/// so that tests and previews can override it with a stub client.
///
/// This is a generated provider: `riverpod_generator` emits
/// `supabaseClientProvider` from the function name, so call sites are unchanged
/// from when this was a hand-written `Provider`.
///
/// Kept alive because it is process-wide state that `Supabase.initialize`
/// already created: deriving it per screen would hand back the same instance.
/// It also heads the kept-alive auth chain (client -> repository -> session ->
/// tenant scope), and `riverpod_lint` does not allow a kept-alive provider to
/// depend on an auto-dispose one.
@Riverpod(keepAlive: true)
SupabaseClient supabaseClient(Ref ref) => Supabase.instance.client;
