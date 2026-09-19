/**
 * Entry point: `match-product`.
 *
 * Ranks the caller's own catalogue against the lines of one supplier bill and
 * returns the candidates, each with the reason it was suggested. It writes
 * nothing, moves no stock, and never takes the pharmacy from the request - the
 * caller's identity decides which catalogue it can see (D-004, D-026).
 *
 * POST `{ "lines": [ { "raw_name": "Dolo650Tab15s", "supplier_id": "<uuid>" } ] }`
 *   → 200 `{ matches: [ { raw_name, candidates: [ … ] } ],
 *             meta: { model, line_count, embedded, vector_used, warnings } }`
 *   → 4xx/5xx `{ error: { code, message } }`
 *
 * Deployed with JWT verification on, like every other function here, and it
 * builds a client from the caller's token so the RPC it calls sees the caller
 * (D-004). It never uses `service_role`.
 */

import { defaultDeps } from './deps.ts';
import { createHandler } from './handler.ts';

Deno.serve(createHandler(defaultDeps));
