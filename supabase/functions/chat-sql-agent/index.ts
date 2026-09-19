/**
 * Entry point: `chat-sql-agent`.
 *
 * Answers a natural-language question about the caller's own pharmacy, from the
 * pharmacy's own reports. The model chooses *which* report and with what
 * parameters; the report supplies every figure (D-026, D-053). It writes nothing,
 * moves no stock and sends no message, and it never takes the pharmacy from the
 * request - the caller's identity decides what it can see (D-004).
 *
 * POST `{ "question": "what is low on stock?",
 *         "history": [ { "role": "user", "text": "…" } ] }`
 *   → 200 `{ answer, rpc, params, data, meta: { model, warnings } }`
 *        `rpc` is `null` and `answer` says it cannot answer, for a question no
 *        report covers - a successful "no", not an error.
 *   → 4xx/5xx `{ error: { code, message } }`
 *
 * Deployed with JWT verification on, like every other function here, and it
 * builds a client from the caller's token so each report sees the caller (D-004).
 * It never uses `service_role`, and one request makes one model call: the key is
 * a free tier shared with the bill reader (N-2), so a chat turn that retried
 * would starve the OCR flow.
 */

import { defaultDeps } from './deps.ts';
import { createHandler } from './handler.ts';

Deno.serve(createHandler(defaultDeps));
