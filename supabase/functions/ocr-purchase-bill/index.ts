/**
 * Entry point: `ocr-purchase-bill`.
 *
 * Reads one supplier bill from the caller's own pharmacy and returns what it
 * says, as JSON. It writes nothing — creating the purchase is the app's job,
 * through the same repository the manual screens use, so an OCR read can never
 * be a second way for stock or a payable to move (D-011/D-013).
 *
 * POST `{ "path": "<pharmacy_id>/<year>/<file>" }`
 *   → 200 `{ document, lines, meta: { model, image_path, warnings } }`
 *   → 4xx/5xx `{ error: { code, message } }`
 *
 * Deployed with JWT verification on, and it additionally builds a client from
 * the caller's token, so every read it makes is subject to the same row level
 * security the app's reads are (D-004). It never uses `service_role`.
 */

import { createHandler } from './handler.ts';
import { defaultDeps } from './deps.ts';

Deno.serve(createHandler(defaultDeps));
