/**
 * Entry point: `backfill-embeddings`.
 *
 * Moves the caller's catalogue one batch at a time towards having a vector per
 * product, so the match's vector leg has something to compare against. It writes
 * exactly one column on the caller's own `products` rows and nothing else: no
 * batch, no stock, no purchase, no ledger entry (D-011/D-013).
 *
 * POST `{"limit": 20}`   (a bare POST is one default batch)
 *   → 200 `{ embedded, remaining, unembeddable, skipped, model }`
 *   → 4xx/5xx `{ error: { code, message } }`
 *
 * The loop is the operator's: run it again while `remaining` is greater than zero.
 * **Do not run it while a bill is being read** - the reader and the model share one
 * key (N-2).
 *
 * Deployed with JWT verification on, like every other function here, and it builds
 * a client from the caller's token so the RPCs it calls see the caller (D-004). It
 * never uses `service_role`.
 */

import { defaultDeps } from './deps.ts';
import { createHandler } from './handler.ts';

Deno.serve(createHandler(defaultDeps));
