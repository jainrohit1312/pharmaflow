/**
 * The dispatch path of `send-notification`.
 *
 * One request, one attempt, one settled record. Every effect arrives through
 * `HandlerDeps`, so the whole path is exercised by `handler_test.ts` with stubs -
 * no Docker, no secret, no database, and no message that could reach a real
 * person.
 *
 * The sequence is **queue -> call -> settle**, and each state means one thing:
 *
 *   - **queue** writes the `notification_logs` row (and, when the caller asked for
 *     one, the `notifications` row it points at) through `queue_notification`, in
 *     one transaction (D-024). `status = 'queued'` is the state that means "we
 *     started". It happens **always** - including when a secret is missing -
 *     because an attempt that leaves no trace is the one thing this function must
 *     not do: the log row is what makes "we told them" answerable (D-046).
 *   - **call** is the provider round trip, outside any transaction. A provider that
 *     answers "no" is a *result*, not an exception; a provider that cannot be
 *     reached is likewise. Only a missing secret is different in kind, and it is
 *     detected here (in `deps.ts`, by `env()`) before any `fetch`.
 *   - **settle** updates the row with what happened: `sent` with the provider's id,
 *     `failed` with the provider's own words, or `skipped` when nothing was
 *     attempted.
 *
 * Two consequences worth stating, because a caller has to be able to act on them:
 *
 *   1. **Once the queue row lands, the answer is 200** with the settled `status`,
 *      whatever that status is. The `{ error: { code, message } }` envelope is for
 *      a request that recorded *nothing* - a bad method, a bad body, an
 *      unauthenticated or unlinked caller - and for a database failure. A missing
 *      secret is therefore `status: 'skipped'` rather than a 503: the attempt
 *      happened and was recorded, and a retry cannot conjure a secret.
 *   2. **The one exception is a settle that fails.** Then the response is a 500 and
 *      the row stays `queued` - which is exactly what `queued` means, and the
 *      honest answer for a caller who does not know whether the message went.
 *
 * There is no automatic dispatch of the Phase 5 alerts (D-046): this function is
 * built and reachable, and nothing calls it on a schedule.
 */

import { FunctionError, isFunctionError } from '../_shared/errors.ts';
import { failJson, okJson, preflight } from '../_shared/response.ts';
import type { DispatchReply } from './providers.ts';
import { WHATSAPP_TEXT_LIMIT } from './providers.ts';

/** The channels this function dispatches over. Push is Phase 6's (D-029). */
export const DISPATCH_CHANNELS = ['whatsapp', 'email'] as const;
export type DispatchChannel = (typeof DISPATCH_CHANNELS)[number];

/** The recipient kinds the `notification_recipient_type` enum knows. */
export const RECIPIENT_TYPES = ['customer', 'supplier', 'user', 'other'] as const;
export type RecipientType = (typeof RECIPIENT_TYPES)[number];

/** Which vendor handles each channel: what the log's `provider` column records. */
export const PROVIDERS: Record<DispatchChannel, string> = {
  whatsapp: 'whatsapp_cloud',
  email: 'sendgrid',
};

/** The request, once its fields are known to be the right shape. */
export interface DispatchPayload {
  channel: DispatchChannel;
  /** The phone number or email address. */
  to: string;
  /** The email subject. Recorded for every channel - it is the in-app title's fallback. */
  subject: string | null;
  /** The message, verbatim. */
  body: string;
  recipientType: RecipientType;
  /** A customer's, a supplier's or a colleague's id. A hint, recorded and not validated against a table. */
  recipientId: string | null;
  /** When set, the message also lands in this user's in-app list. */
  notifyUserId: string | null;
  /** What kind of notification it is, for the in-app row. The RPC defaults it to 'message'. */
  type: string | null;
  /** The in-app row's headline. Falls back to the subject. */
  title: string | null;
}

/** The two ids `queue_notification` answers with. */
export interface QueueResult {
  logId: string;
  notificationId: string | null;
}

/** How an attempt ended, and what the log row is updated to say. */
export interface SettleOutcome {
  status: 'sent' | 'failed' | 'skipped';
  /** The vendor that handled it, or null when nobody was reached. */
  provider: string | null;
  providerMessageId: string | null;
  error: string | null;
}

/** Everything the handler needs from the outside world. */
export interface HandlerDeps {
  /** The pharmacy the caller belongs to. Never taken from the request. */
  getPharmacyId(request: Request): Promise<string>;
  /** Opens the attempt: the log row, and the in-app row when there is one. */
  queue(request: Request, payload: Record<string, unknown>): Promise<QueueResult>;
  /** One WhatsApp text message. */
  whatsapp(request: Request, to: string, body: string): Promise<DispatchReply>;
  /** One email. */
  email(
    request: Request,
    to: string,
    subject: string | null,
    body: string,
  ): Promise<DispatchReply>;
  /** Records what happened to the row [logId]. */
  settle(request: Request, logId: string, outcome: SettleOutcome): Promise<void>;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The request, or an `invalid_request` failure.
 *
 * Validation is strict on purpose and it happens before anything is written: the
 * queue row records these values as the attempt's own facts, and a row that says
 * `to: "  "` is worse than a refusal that says which field was wrong.
 */
export function validateDispatch(raw: unknown): DispatchPayload {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new FunctionError(
      'invalid_request',
      'Send the notification as a JSON object.',
    );
  }

  const record = raw as Record<string, unknown>;

  const channel = text(record.channel);
  if (
    channel === null ||
    !(DISPATCH_CHANNELS as readonly string[]).includes(channel)
  ) {
    throw new FunctionError(
      'invalid_request',
      'A notification goes out over whatsapp or email.',
    );
  }

  const to = text(record.to);
  if (to === null) {
    throw new FunctionError(
      'invalid_request',
      `A ${channel} notification needs a "to": ${
        channel === 'email' ? 'an email address' : 'a phone number'
      }.`,
    );
  }

  // The body is the message itself, so it is kept exactly as it arrived - an edge
  // newline is part of what will be read. Only "nothing at all" is refused, and
  // the check is a trim so that whitespace is not a way to send an empty message.
  const body = typeof record.body === 'string' ? record.body : null;
  if (body === null || body.trim().length === 0) {
    throw new FunctionError('invalid_request', 'A notification needs a body.');
  }
  if (body.length > WHATSAPP_TEXT_LIMIT) {
    throw new FunctionError(
      'too_large',
      `That message is ${body.length} characters; a text notification is limited to ${WHATSAPP_TEXT_LIMIT}.`,
    );
  }

  const recipientType = text(record.recipient_type);
  if (
    recipientType === null ||
    !(RECIPIENT_TYPES as readonly string[]).includes(recipientType)
  ) {
    throw new FunctionError(
      'invalid_request',
      'A notification needs a recipient_type: customer, supplier, user or other.',
    );
  }

  return {
    channel: channel as DispatchChannel,
    to,
    subject: text(record.subject),
    body,
    recipientType: recipientType as RecipientType,
    recipientId: uuid(record.recipient_id, 'recipient_id'),
    notifyUserId: uuid(record.notify_user_id, 'notify_user_id'),
    type: text(record.type),
    title: text(record.title),
  };
}

/**
 * The payload `queue_notification` takes.
 *
 * The key names are the function's, not the request's: `to` becomes `destination`,
 * and nothing the caller could lie about - a pharmacy id, a status, a provider -
 * is in here at all.
 */
export function queuePayload(
  payload: DispatchPayload,
): Record<string, unknown> {
  return {
    channel: payload.channel,
    destination: payload.to,
    subject: payload.subject,
    body: payload.body,
    recipient_type: payload.recipientType,
    recipient_id: payload.recipientId,
    notify_user_id: payload.notifyUserId,
    type: payload.type,
    title: payload.title,
  };
}

/** The handler `index.ts` serves, with [deps] supplying the real world. */
export function createHandler(
  deps: HandlerDeps,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') {
      return preflight();
    }

    try {
      if (request.method !== 'POST') {
        throw new FunctionError('invalid_request', 'This endpoint accepts POST.');
      }

      const body = await readJsonBody(request);
      const payload = validateDispatch(body);

      // Before anything is written: an account with no pharmacy has no log to
      // write against and nobody whose inbox it could be.
      await deps.getPharmacyId(request);

      // Queue first, always. A refusal that leaves no trace is the one outcome
      // this function must not have (D-046), and `queued` is the honest state of
      // an attempt that has started and not finished.
      const queued = await deps.queue(request, queuePayload(payload));

      const outcome = await attempt(deps, request, payload);
      await deps.settle(request, queued.logId, outcome);

      return okJson({
        log_id: queued.logId,
        notification_id: queued.notificationId,
        status: outcome.status,
        provider: outcome.provider,
        error: outcome.error,
      });
    } catch (error) {
      if (isFunctionError(error)) {
        console.error(`send-notification refused: ${error.code} - ${error.message}`);
        return failJson(error);
      }

      console.error('send-notification failed unexpectedly', error);
      return failJson(error);
    }
  };
}

/**
 * The provider call, and what it settled to.
 *
 * Nothing in here throws: a provider refusal and a provider that never answered
 * are both results, because both have to end up as a sentence in the log row
 * rather than as an error page the caller cannot see the record behind.
 */
async function attempt(
  deps: HandlerDeps,
  request: Request,
  payload: DispatchPayload,
): Promise<SettleOutcome> {
  try {
    const reply = payload.channel === 'whatsapp'
      ? await deps.whatsapp(request, payload.to, payload.body)
      : await deps.email(request, payload.to, payload.subject, payload.body);

    if (reply.ok) {
      return {
        status: 'sent',
        provider: PROVIDERS[payload.channel],
        providerMessageId: reply.messageId,
        error: null,
      };
    }

    return {
      status: 'failed',
      provider: PROVIDERS[payload.channel],
      providerMessageId: null,
      error: reply.message,
    };
  } catch (error) {
    // A secret that was never set is not a failed delivery - it is one that was
    // never attempted, which is what `skipped` is for and why no provider is
    // recorded against it.
    const unconfigured = isFunctionError(error) && error.code === 'not_configured';

    return {
      status: unconfigured ? 'skipped' : 'failed',
      provider: unconfigured ? null : PROVIDERS[payload.channel],
      providerMessageId: null,
      error: messageOf(error),
    };
  }
}

/** What happened, in a sentence: the function's own words where it has them. */
function messageOf(error: unknown): string {
  if (isFunctionError(error)) {
    return error.message;
  }
  const reason = error instanceof Error ? error.message : 'no reason given';
  return `The provider could not be reached (${reason}).`;
}

/** A trimmed, non-empty string, or null. */
function text(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/**
 * A uuid, or null when the field was not sent.
 *
 * An id that is present but not a uuid is refused rather than dropped, which is
 * where this differs from the matcher's supplier id: that one is a filter hint,
 * while `notify_user_id` decides *whether a row is written at all*, and silently
 * answering "sent" for a call whose in-app row the caller asked for would be a
 * different outcome from the one they asked for.
 */
function uuid(value: unknown, field: string): string | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value === 'string' && UUID_PATTERN.test(value.trim())) {
    return value.trim();
  }
  throw new FunctionError(
    'invalid_request',
    `The ${field} must be a uuid, or omitted.`,
  );
}

/** The request body, or an `invalid_request` failure. */
async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new FunctionError(
      'invalid_request',
      'Send the notification as a JSON body.',
    );
  }
}
