/**
 * The real world behind the handler's seams: the caller's own credentials, the
 * private bucket, and the model's endpoint.
 *
 * Nothing in this file makes a decision — every rule (who may read what, how a
 * reply is normalized, what is refused and why) lives in `handler.ts` and
 * `gemini.ts`, where it can be tested. This is the wiring, and its job is to be
 * small enough to read in one sitting.
 */

import { BILL_BUCKET, env, requirePharmacyId, userClient } from '../_shared/client.ts';
import { FunctionError } from '../_shared/errors.ts';
import { DEFAULT_VISION_MODEL, mimeForPath } from './gemini.ts';
import type { GeminiCall, HandlerDeps } from './handler.ts';

/** The model to ask. A deployment can move it without a redeploy of the code. */
const model = Deno.env.get('GEMINI_VISION_MODEL')?.trim() || DEFAULT_VISION_MODEL;

export const defaultDeps: HandlerDeps = {
  model,

  /**
   * The caller's pharmacy, read as the caller.
   *
   * Two clients are built per request rather than one shared one: everything in
   * this function must carry the *caller's* token, and a module-level client
   * would be a place for a later change to accidentally reach past RLS.
   */
  getPharmacyId: (request) => requirePharmacyId(userClient(request)),

  downloadBill: async (request, path) => {
    const client = userClient(request);
    const { data, error } = await client.storage.from(BILL_BUCKET).download(path);

    if (error || data === null) {
      // "Does not exist" and "the policy refuses you" are deliberately the same
      // answer: distinguishing them would tell a stranger which of another
      // pharmacy's bills exist. The real reason goes to the logs.
      console.error(`ocr-purchase-bill could not read ${path}: ${error?.message ?? 'no data'}`);
      throw new FunctionError('not_found', 'That bill could not be read.');
    }

    const bytes = new Uint8Array(await data.arrayBuffer());
    return {
      bytes,
      mimeType: data.type || mimeForPath(path) || 'application/octet-stream',
    };
  },

  callGemini: async ({ url, request }: GeminiCall) => {
    // Read here, not at module load: a missing secret should be a sentence the
    // app can show ("the reader is not configured"), not a function that fails
    // to start and answers with the platform's own error page.
    const apiKey = env('GEMINI_API_KEY');

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        // The key travels in a header rather than the query string, so it stays
        // out of URLs and out of the API's request logs.
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify(request),
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
  },
};

/**
 * What to tell the user when the model's API refuses.
 *
 * A 400 here means *this function* sent something the API did not accept (a
 * schema in the wrong dialect, a mime type it cannot read), so the API's own
 * words are the most useful thing anyone can read in the logs — and they are
 * included in the message rather than swallowed.
 */
function providerMessage(status: number, body: unknown): string {
  const record =
    typeof body === 'object' && body !== null ? (body as Record<string, unknown>) : {};
  const error = typeof record.error === 'object' && record.error !== null
    ? (record.error as Record<string, unknown>)
    : {};
  const detail = typeof error.message === 'string' ? error.message : null;

  if (status === 429) {
    return 'The bill reader is busy right now. Try again in a moment.';
  }
  if (detail !== null) {
    return `The bill reader could not process that image (${status}): ${detail}`;
  }
  return `The bill reader could not process that image (${status}).`;
}
