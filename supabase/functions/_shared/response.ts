/**
 * The one JSON envelope every Phase 5 function answers with, and the CORS
 * headers that let a browser call it at all.
 *
 * Success is the body the function's own contract describes; failure is always
 * `{ error: { code, message, detail? } }`. One shape for every function means
 * the app has one response mapper (Chunk B's `parseFunctionResponse`) instead
 * of one per feature.
 *
 * CORS is not optional here: the app's first platform is the browser (D-005),
 * and a Flutter web build talks to `functions/v1/...` cross-origin from both
 * `localhost` during development and the deployed origin afterwards. Supabase
 * does not add these headers for you, and without them the browser reports an
 * opaque network failure with no hint of what went wrong. `*` is correct
 * because authentication is a bearer token, which a browser will not attach to
 * a cross-origin request by itself — nothing here relies on a cookie.
 */

import { FunctionError, isFunctionError, type FunctionErrorCode } from './errors.ts';

/** HTTP status for each situation. The app reads the code, not this. */
const STATUS: Record<FunctionErrorCode, number> = {
  unauthorized: 401,
  forbidden: 403,
  invalid_request: 400,
  not_found: 404,
  too_large: 413,
  not_configured: 503,
  provider_unavailable: 502,
  internal: 500,
};

const CORS_HEADERS: Record<string, string> = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers':
    'authorization, apikey, content-type, x-client-info, x-supabase-api-version',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-max-age': '86400',
};

/** JSON [body] with [status], plus the CORS headers every response needs. */
export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      'content-type': 'application/json; charset=utf-8',
    },
  });
}

/** The answer to a browser's preflight. */
export function preflight(): Response {
  return new Response(null, { status: 204, headers: CORS_HEADERS });
}

/** A successful answer. */
export function okJson(body: unknown): Response {
  return json(200, body);
}

/**
 * A failure the caller can act on.
 *
 * The message is written to be read by a person: it reaches the user verbatim
 * through the app's error mapper, the same way a `check_violation` from
 * Postgres does.
 */
export function failJson(error: unknown): Response {
  if (isFunctionError(error)) {
    return json(STATUS[error.code], {
      error: {
        code: error.code,
        message: error.message,
        ...(error.detail === undefined ? {} : { detail: error.detail }),
      },
    });
  }

  const fallback = new FunctionError(
    'internal',
    'Something went wrong reading that bill. Try again, and report it if it keeps happening.',
  );
  return json(STATUS[fallback.code], {
    error: { code: fallback.code, message: fallback.message },
  });
}
