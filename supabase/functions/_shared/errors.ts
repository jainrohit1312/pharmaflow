/**
 * The failure vocabulary of every Phase 5 Edge Function.
 *
 * A function's caller is the Flutter app (or, later, another function), and the
 * only thing it can act on is a small set of situations. Each of those gets a
 * name here, and the name — not the HTTP status — is what the app switches on,
 * so a message can be reworded without changing behaviour, and a status can be
 * corrected without changing the app.
 *
 * `not_configured` is deliberately its own name rather than a flavour of
 * `internal`: "the server is missing a secret" is an operator's problem, not a
 * user's, and the two deserve different words on screen.
 */

/** Every situation a Phase 5 function reports instead of throwing at the caller. */
export type FunctionErrorCode =
  | 'unauthorized'
  | 'forbidden'
  | 'invalid_request'
  | 'not_found'
  | 'too_large'
  | 'not_configured'
  | 'provider_unavailable'
  | 'internal';

/**
 * An error a function knows how to describe.
 *
 * Anything else that escapes a handler is reported as `internal`: an unexpected
 * throw is a bug, and dressing it up as a known situation would hide that.
 */
export class FunctionError extends Error {
  /** The situation, as the caller sees it. */
  readonly code: FunctionErrorCode;

  /** Extra, non-secret context for the logs and the caller. */
  readonly detail?: unknown;

  constructor(code: FunctionErrorCode, message: string, detail?: unknown) {
    super(message);
    this.name = 'FunctionError';
    this.code = code;
    this.detail = detail;
  }
}

/** Whether [error] is a failure a handler raised deliberately. */
export function isFunctionError(error: unknown): error is FunctionError {
  return error instanceof FunctionError;
}
