/**
 * The caller-scoped Supabase client, and the tenant it resolves to.
 *
 * Every Phase 5 function acts as the signed-in user, never as `service_role`
 * (D-004). That is not a courtesy: row level security is the only thing that
 * makes one pharmacy's data unreachable from another, and a function that
 * reached past it would be a way around every policy in the schema. So the
 * client below carries the caller's own `Authorization` header, and every read
 * it makes is filtered by the same policies the app's reads are.
 *
 * The tenant is then re-derived from that identity — `get_my_pharmacy_id()`
 * reads the caller's own profile row — rather than taken from the request. A
 * caller-supplied tenant id would be exactly the thing an attacker supplies.
 */

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';
import { FunctionError } from './errors.ts';

/** The private bucket OCR bills live in (migration 00022, D-028). */
export const BILL_BUCKET = 'purchase-bills';

/**
 * Reads a function secret.
 *
 * `SUPABASE_URL` and `SUPABASE_ANON_KEY` are provided by the platform.
 * Everything else this project needs is set with `supabase secrets set` and
 * never appears in the repository.
 */
export function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new FunctionError(
      'not_configured',
      `This function is missing its ${name} secret.`,
    );
  }
  return value;
}

/**
 * A client that acts as the caller of [request].
 *
 * A missing or non-bearer `Authorization` fails here rather than at the first
 * query, so "nobody signed in" is reported as such instead of looking like an
 * empty result set.
 */
export function userClient(request: Request): SupabaseClient {
  const authorization = request.headers.get('authorization') ?? '';
  if (!authorization.toLowerCase().startsWith('bearer ')) {
    throw new FunctionError(
      'unauthorized',
      'Sign in before reading a bill.',
    );
  }

  return createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * The pharmacy [client]'s user belongs to.
 *
 * This is the same function every RLS policy calls, so the tenant a function
 * acts for is the tenant the database would enforce anyway. A signed-in account
 * with no pharmacy (onboarding unfinished) is refused here, with its own
 * message, rather than being handed an empty result set to interpret.
 */
export async function requirePharmacyId(client: SupabaseClient): Promise<string> {
  const { data, error } = await client.rpc('get_my_pharmacy_id');

  if (error) {
    throw new FunctionError(
      'internal',
      `Could not read the pharmacy this account belongs to: ${error.message}`,
    );
  }
  if (typeof data !== 'string' || data.length === 0) {
    throw new FunctionError(
      'unauthorized',
      'This account is not linked to a pharmacy yet.',
    );
  }
  return data;
}
