/**
 * The one way a Phase 5 function talks to the Generative Language API.
 *
 * `ocr-purchase-bill` proved the shape: the key travels in the `x-goog-api-key`
 * header rather than the query string so it stays out of the API's own request
 * logs, a non-2xx answer is turned into a `provider_unavailable` whose message is
 * written for a person, and an unparseable body is not treated as a success.
 *
 * This lives in `_shared/` because two functions now need it (`match-product`
 * today, the embedding backfill next) and the error mapping is the part that must
 * not diverge - one function telling the user "the reader is busy" while another
 * says "HTTP 503" is one vocabulary with two dialects.
 *
 * `ocr-purchase-bill` deliberately does NOT import this yet: it is deployed and
 * live-verified, and rewriting its working `deps.ts` to route through a new
 * helper would risk a regression for a tidiness win. It should adopt this when it
 * is next touched for another reason.
 *
 * The api key arrives as an argument rather than being read here, so this module
 * depends on nothing but `errors.ts` and can be tested with a stub `fetch` - no
 * Supabase client, no network, no secret.
 */

import { FunctionError } from './errors.ts';

/** One call to the API. */
export interface GeminiCall {
  /** The endpoint, with the API key kept out of the URL. */
  url: string;
  /** The request body to POST. */
  request: unknown;
}

/** What [postGemini] uses to make the request. Injected so a test can drive it. */
export type GeminiFetch = (url: string, init: RequestInit) => Promise<Response>;

/**
 * POSTs [call] and returns the parsed body.
 *
 * A non-2xx answer becomes a `provider_unavailable` carrying the provider's own
 * words where it gave any: for a 400 that is the most useful sentence anyone can
 * read, because it means *this* function sent something the API would not accept
 * (a schema in the wrong dialect, a model name that has rotted - D-030).
 */
export async function postGemini(
  call: GeminiCall,
  apiKey: string,
  fetchImpl: GeminiFetch = fetch,
): Promise<unknown> {
  const response = await fetchImpl(call.url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-goog-api-key': apiKey,
    },
    body: JSON.stringify(call.request),
  });

  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text.length === 0 ? null : JSON.parse(text);
  } catch {
    parsed = null;
  }

  if (!response.ok) {
    throw new FunctionError(
      'provider_unavailable',
      providerMessage(response.status, parsed),
      { status: response.status },
    );
  }

  return parsed;
}

/**
 * What to tell the user when the API refuses.
 *
 * A 429 and the `503 UNAVAILABLE` this project actually meets are both "come
 * back in a moment" (the free tier answers the second, D-032), so they share a
 * sentence. Everything else keeps the provider's own detail, because that is the
 * text that identifies the mistake.
 */
export function providerMessage(status: number, body: unknown): string {
  const record =
    typeof body === 'object' && body !== null ? (body as Record<string, unknown>) : {};
  const error = typeof record.error === 'object' && record.error !== null
    ? (record.error as Record<string, unknown>)
    : {};
  const detail = typeof error.message === 'string' ? error.message : null;

  if (status === 429 || status === 503) {
    return 'The reader is busy right now. Try again in a moment.';
  }
  if (detail !== null) {
    return `The reader could not process that request (${status}): ${detail}`;
  }
  return `The reader could not process that request (${status}).`;
}
