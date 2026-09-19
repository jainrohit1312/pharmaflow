/**
 * Entry point: `send-notification`.
 *
 * Sends one message over WhatsApp or email **as the caller**, records the attempt
 * in `notification_logs` whatever happens to it, and - when the caller asks for it
 * - also puts the message in the recipient's in-app list. It moves no stock and
 * reads no business table: the pharmacy comes from the caller's own identity, so a
 * request cannot write into a tenant it does not belong to (D-004).
 *
 * POST
 *   `{ "channel": "whatsapp" | "email",
 *      "to": "<phone or email>",
 *      "subject": "…" | null,              // email's subject; also the in-app title's fallback
 *      "body": "…",
 *      "recipient_type": "customer" | "supplier" | "user" | "other",
 *      "recipient_id": "<uuid>" | null,
 *      "notify_user_id": "<uuid>" | null,  // also land in this user's in-app list
 *      "type": "…" | null,                 // the in-app row's kind; defaults to 'message'
 *      "title": "…" | null }               // the in-app row's headline; defaults to the subject
 *   → 200 `{ log_id, notification_id, status: "sent" | "failed" | "skipped",
 *             provider, error }`
 *   → 4xx/5xx `{ error: { code, message } }`
 *
 * **The 200 is the attempt's outcome, not a promise of delivery.** `status` is
 * `sent` when the provider accepted the message, `failed` when it refused it (and
 * `error` carries the provider's own words), and `skipped` when nothing was
 * attempted at all - which, in this phase, is what a missing `WHATSAPP_TOKEN` or
 * `SENDGRID_API_KEY` means. There is no third-party credential in Phase 5 (D-046),
 * so `skipped` is the honest answer here and the log row still lands.
 *
 * The `{ error: { code, message } }` envelope is reserved for a request that
 * recorded nothing: a bad method or body, an unauthenticated caller, an account
 * with no pharmacy, a database failure - and for the one case where the attempt was
 * recorded but its outcome could not be, which is a 500 that leaves the row
 * `queued`.
 *
 * Deployed with JWT verification on, like every other function here, and it builds
 * a client from the caller's token so the RPC and the log update see the caller
 * (D-004). It never uses `service_role`.
 */

import { defaultDeps } from './deps.ts';
import { createHandler } from './handler.ts';

Deno.serve(createHandler(defaultDeps));
