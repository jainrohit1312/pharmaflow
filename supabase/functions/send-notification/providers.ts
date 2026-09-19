/**
 * The two dispatch providers, and the one way this project talks to each.
 *
 * WhatsApp goes through the Cloud API (`graph.facebook.com`) and email through
 * SendGrid, and they are different enough that one "generic poster" would have to
 * grow a branch per provider: WhatsApp names the sender in the *URL* and answers
 * with the message id in the body, SendGrid names the sender in the body and
 * answers with the id in a *header* and an empty body. So the request builders are
 * separate functions, and the two posters keep their own shape.
 *
 * What they share is the part that must not diverge: the token travels in an
 * `Authorization` header and never in the URL (the shape `_shared/gemini.ts`
 * established for the API key, so a key stays out of the provider's own request
 * logs), a non-2xx answer is turned into a sentence written for a person, and a
 * provider that cannot be reached at all is a *result* rather than an exception -
 * the handler settles it like any other failure and the log row says what
 * happened. Nothing here throws.
 *
 * There is no third-party credential in this phase (D-046): no WhatsApp account,
 * no SendGrid key, no recipient numbers. That is why the missing secret is
 * detected by `env()` in `deps.ts`, one layer up, before either poster is called -
 * so an unconfigured deploy never reaches a `fetch` at all. It also means the code
 * below has never carried a real message, and is written to be read rather than to
 * be believed: `providers_test.ts` drives every branch with a stub `fetch`.
 */

/** One call to a provider, ready to send. */
export interface DispatchRequest {
  /** The endpoint. The credential is not in it. */
  url: string;
  /** The JSON body to POST. */
  body: unknown;
}

/**
 * What a provider answered, as far as this project needs to understand it.
 *
 * `status` 0 is this project's own: it means nobody answered at all, which is
 * neither a 4xx nor a 5xx and should not be reported as one.
 */
export interface DispatchReply {
  /** Whether the provider accepted the message for delivery. */
  ok: boolean;
  /** The provider's HTTP status, or 0 when it could not be reached. */
  status: number;
  /** The provider's own id for the message, when it gave one. */
  messageId: string | null;
  /** A sentence for a person: what happened, in the provider's own words where it had any. */
  message: string;
}

/** What [postWhatsApp] and [postSendGrid] use to make the request. Injected so a test can drive it. */
export type DispatchFetch = (url: string, init: RequestInit) => Promise<Response>;

/**
 * The Graph API version WhatsApp calls are pinned to.
 *
 * Meta versions this API and retires versions on a schedule, so the version is a
 * named constant rather than a string inside a template - the same reasoning that
 * names the vision model in code (D-030): a version change is a one-line deploy,
 * not a search. `deps.ts` lets `WHATSAPP_API_VERSION` override it without one.
 */
export const DEFAULT_WHATSAPP_API_VERSION = 'v22.0';

/** How long a WhatsApp text message may be, and comfortably inside SendGrid's own ceiling. */
export const WHATSAPP_TEXT_LIMIT = 4096;

/**
 * A text message, in the shape the Cloud API wants it.
 *
 * `recipient_type: 'individual'` is the API's own field and its own value, not a
 * guess: the alternative is a group, which this project never sends to.
 */
export function whatsappMessage(input: {
  version: string;
  phoneNumberId: string;
  to: string;
  body: string;
}): DispatchRequest {
  return {
    url: `https://graph.facebook.com/${input.version}/${
      encodeURIComponent(input.phoneNumberId)
    }/messages`,
    body: {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: input.to,
      type: 'text',
      text: { body: input.body },
    },
  };
}

/**
 * One plain-text email, in the shape SendGrid's v3 API wants it.
 *
 * `subject` is required by the API even when the caller has none, so an absent
 * one becomes an empty string rather than the word "null" in a subject line.
 */
export function sendgridMail(input: {
  from: string;
  to: string;
  subject: string | null;
  body: string;
}): DispatchRequest {
  return {
    url: 'https://api.sendgrid.com/v3/mail/send',
    body: {
      personalizations: [{ to: [{ email: input.to }] }],
      from: { email: input.from },
      subject: input.subject ?? '',
      content: [{ type: 'text/plain', value: input.body }],
    },
  };
}

/** POSTs a WhatsApp text message. Never throws; a provider refusal is the reply. */
export async function postWhatsApp(
  request: DispatchRequest,
  token: string,
  fetchImpl: DispatchFetch = fetch,
): Promise<DispatchReply> {
  const posted = await post(request, token, fetchImpl);
  if (!posted.reached) {
    return { ok: false, status: 0, messageId: null, message: posted.message };
  }

  if (!posted.response.ok) {
    return {
      ok: false,
      status: posted.response.status,
      messageId: null,
      message: providerMessage('WhatsApp', posted.response.status, posted.parsed),
    };
  }

  // A 200 carries `{ messages: [ { id: "wamid…" } ] }`. A 200 without one is still
  // an acceptance - the message is queued for delivery either way - so the id is
  // allowed to be missing rather than turning an accepted message into a failure.
  const messages = Array.isArray(asRecord(posted.parsed).messages)
    ? (asRecord(posted.parsed).messages as unknown[])
    : [];
  const id = asRecord(messages[0]).id;

  return {
    ok: true,
    status: posted.response.status,
    messageId: typeof id === 'string' ? id : null,
    message: 'WhatsApp accepted the message.',
  };
}

/** POSTs an email through SendGrid. Never throws; a provider refusal is the reply. */
export async function postSendGrid(
  request: DispatchRequest,
  apiKey: string,
  fetchImpl: DispatchFetch = fetch,
): Promise<DispatchReply> {
  const posted = await post(request, apiKey, fetchImpl);
  if (!posted.reached) {
    return { ok: false, status: 0, messageId: null, message: posted.message };
  }

  if (!posted.response.ok) {
    return {
      ok: false,
      status: posted.response.status,
      messageId: null,
      message: providerMessage('SendGrid', posted.response.status, posted.parsed),
    };
  }

  // SendGrid answers 202 with an empty body and the id in `X-Message-Id`, which is
  // why this poster and the WhatsApp one are not one function.
  return {
    ok: true,
    status: posted.response.status,
    messageId: posted.response.headers.get('x-message-id'),
    message: 'SendGrid accepted the message.',
  };
}

/** The body of a refusal, in the provider's own words, or a sentence saying which failure it was. */
export function providerMessage(
  provider: string,
  status: number,
  body: unknown,
): string {
  const detail = providerDetail(body);

  if (status === 429 || status === 503) {
    return `${provider} is rate-limiting this account right now (${status}). Try again in a moment.`;
  }
  if (detail !== null) {
    return `${provider} refused the message (${status}): ${detail}`;
  }
  return `${provider} refused the message (${status}).`;
}

/** The POST, and the two ways it can fail before a provider answers anything. */
type Posted =
  | { reached: true; response: Response; parsed: unknown }
  | { reached: false; message: string };

async function post(
  request: DispatchRequest,
  token: string,
  fetchImpl: DispatchFetch,
): Promise<Posted> {
  let response: Response;
  try {
    response = await fetchImpl(request.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(request.body),
    });
  } catch (error) {
    // A DNS failure, a TLS failure, a provider having a bad day: the caller can
    // retry, so this is a sentence rather than a throw.
    const reason = error instanceof Error ? error.message : 'no reason given';
    return {
      reached: false,
      message: `The provider could not be reached (${reason}).`,
    };
  }

  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text.length === 0 ? null : JSON.parse(text);
  } catch {
    // A body that is not JSON is not a success marker either way; the status is
    // what this project reads.
    parsed = null;
  }

  return { reached: true, response, parsed };
}

/**
 * The provider's message from its refusal.
 *
 * Two shapes, because there are two providers: WhatsApp nests it at
 * `error.message`, SendGrid puts a list at `errors[0].message`. Both are worth
 * reading - they are the text that names the mistake, the way a 400 from the
 * vision model is (D-030).
 */
function providerDetail(body: unknown): string | null {
  const record = asRecord(body);

  const nested = asRecord(record.error).message;
  if (typeof nested === 'string' && nested.length > 0) {
    return nested;
  }

  const errors = Array.isArray(record.errors) ? (record.errors as unknown[]) : [];
  const first = asRecord(errors[0]).message;
  if (typeof first === 'string' && first.length > 0) {
    return first;
  }

  return null;
}

/** [value] as an object, or an empty one - so a missing field is a missing field and not a crash. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
