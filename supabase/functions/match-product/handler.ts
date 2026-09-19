/**
 * The smart match's request path.
 *
 * Takes the lines of one bill and answers with ranked candidates per line. Every
 * effect arrives through `HandlerDeps`, so the whole path is exercised by
 * `handler_test.ts` with stubs - no Docker, no API key, no database.
 *
 * Three rules shape this file, and each one is a decision rather than a style:
 *
 *   1. **The tenant is never an argument.** It is not read from the body at all:
 *      `getPharmacyId` asks the caller's own identity, and the RPC derives it
 *      again from `get_my_pharmacy_id()`. A pharmacy id in the request would be
 *      exactly the thing an attacker supplies (D-004/D-026).
 *   2. **An embedding failure never fails the bill.** The vector leg is an
 *      enhancement: the alias and trigram legs answer without it, and a matcher
 *      that refuses twenty lines because the free-tier key is busy would be worse
 *      than one that suggests nothing for a moment (N-2, D-032). The failure
 *      travels in `meta.warnings`, which is where this project already says "here
 *      is what I could not do" - and the app shows that list.
 *   3. **One embedding call per bill, not per line.** The key allows five
 *      requests a minute (N-2) and a bill is read on the same key.
 *
 * The match itself is not computed here. Ranking happens in SQL, in
 * `match_products` (D-026: parameterised, tenant from the caller's identity, the
 * model never in the path) - this function's job is to hand it the invoice text,
 * the supplier and a query vector, and to say what it could not do.
 */

import { queryEmbeddingText } from '../_shared/embedding.ts';
import { FunctionError, isFunctionError } from '../_shared/errors.ts';
import { failJson, okJson, preflight } from '../_shared/response.ts';

/**
 * How many lines of one bill are matched.
 *
 * A bill past this is not refused, it is truncated with a warning: the caller
 * gets suggestions for the lines it did match, and the rest are matched by hand
 * exactly as they are today. Fifty is well past a plausible invoice (the reader's
 * own prompt is written for a table of a few dozen rows) and keeps one request's
 * payload and query count bounded.
 */
export const MAX_MATCH_LINES = 50;

/** How many candidates each line is answered with. */
export const MATCH_LIMIT = 5;

/** One line of the bill, as the caller sent it. */
export interface MatchLine {
  /** The invoice text, or `null` for a line the reader could not read. */
  rawName: string | null;
  /** The supplier's id, when the caller knows it. An alias is scoped by it. */
  supplierId: string | null;
}

/** One query, in the shape the RPC's `p_queries` wants. */
export interface MatchQuery {
  raw_name: string | null;
  supplier_id: string | null;
  query_embedding: number[] | null;
}

/** Everything the handler needs from the outside world. */
export interface HandlerDeps {
  /** The embedding model to ask. */
  model: string;
  /** The pharmacy the caller belongs to. Never taken from the request. */
  getPharmacyId(request: Request): Promise<string>;
  /** One vector per text, in the same order. A `null` entry means "none". */
  embed(request: Request, texts: string[]): Promise<(number[] | null)[]>;
  /** The ranked candidates, from `match_products`. */
  match(request: Request, queries: MatchQuery[]): Promise<unknown>;
}

/** A stable uuid, which is all the function needs a supplier id to look like. */
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The bill's lines, from whatever the caller sent.
 *
 * A line may be a bare string (`"Dolo 650"`) or an object with a `raw_name` and
 * an optional `supplier_id`; anything else is refused with the position that was
 * wrong, because a caller whose third line is a number wants to know *which* line
 * rather than that "the request was invalid".
 *
 * A line with no readable text is kept rather than dropped: the answer is lined
 * up with the bill by position, and a missing entry would silently shift every
 * later line onto the wrong product.
 */
export function validateLines(raw: unknown): MatchLine[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new FunctionError(
      'invalid_request',
      'Send the lines of the bill to match.',
    );
  }

  return raw.map((entry, index) => {
    if (typeof entry === 'string') {
      return { rawName: entry, supplierId: null };
    }
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      throw new FunctionError(
        'invalid_request',
        `Line ${index + 1} is not a line: send a string or an object with a raw_name.`,
      );
    }

    const record = entry as Record<string, unknown>;
    const name = record.raw_name;
    const supplier = record.supplier_id;

    return {
      rawName: typeof name === 'string' ? name : null,
      // A supplier id that is not a uuid is dropped here rather than sent on: the
      // RPC would read it as "no supplier" anyway, and a payload should not carry
      // a value nobody is going to use. The RPC keeps its own guard, because it
      // is reachable without this function.
      supplierId:
        typeof supplier === 'string' && UUID_PATTERN.test(supplier.trim())
          ? supplier.trim()
          : null,
    };
  });
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
      const lines = validateLines((body as Record<string, unknown>).lines);
      const truncated = lines.length > MAX_MATCH_LINES;
      const selected = truncated ? lines.slice(0, MAX_MATCH_LINES) : lines;

      // Before anything else is done: an account with no pharmacy has no
      // catalogue, and saying so is better than answering with nothing.
      await deps.getPharmacyId(request);

      const warnings: string[] = [];
      if (truncated) {
        warnings.push(
          `Only the first ${MAX_MATCH_LINES} lines of this bill were matched.`,
        );
      }

      const embeddings = await embedLines(deps, request, selected, warnings);

      const queries: MatchQuery[] = selected.map((line, index) => ({
        raw_name: line.rawName,
        supplier_id: line.supplierId,
        query_embedding: embeddings[index],
      }));

      const matched = await deps.match(request, queries);
      let matches: unknown[] = [];
      if (Array.isArray(matched)) {
        matches = matched;
      } else {
        warnings.push(
          'The catalogue match came back in a shape this app does not understand.',
        );
      }

      const embedded = embeddings.filter((vector) => vector !== null).length;

      return okJson({
        matches,
        meta: {
          model: deps.model,
          line_count: selected.length,
          embedded,
          // What a screen needs to say "the suggestions are name-based this time"
          // rather than "there is nothing like this in your catalogue".
          vector_used: embedded > 0,
          warnings,
        },
      });
    } catch (error) {
      if (isFunctionError(error)) {
        console.error(`match-product refused: ${error.code} - ${error.message}`);
        return failJson(error);
      }

      console.error('match-product failed unexpectedly', error);
      return failJson(error);
    }
  };
}

/**
 * One vector per line, or `null` where there is none.
 *
 * Only lines with text worth embedding are sent, so a bill with three blank rows
 * does not spend three of the batch's slots. A failure anywhere in here is turned
 * into a warning and the whole batch falls back to no vectors: the point of this
 * leg is to *add* candidates, and a matcher that returns an error page instead is
 * a matcher the screen has to work around.
 */
async function embedLines(
  deps: HandlerDeps,
  request: Request,
  lines: MatchLine[],
  warnings: string[],
): Promise<(number[] | null)[]> {
  const embeddings: (number[] | null)[] = lines.map(() => null);

  const texts: string[] = [];
  const positions: number[] = [];
  lines.forEach((line, index) => {
    const text = queryEmbeddingText(line.rawName);
    if (text !== null) {
      texts.push(text);
      positions.push(index);
    }
  });

  if (texts.length === 0) {
    return embeddings;
  }

  try {
    const vectors = await deps.embed(request, texts);
    positions.forEach((position, index) => {
      embeddings[position] = vectors[index] ?? null;
    });
    if (positions.some((position) => embeddings[position] === null)) {
      warnings.push(
        'Some lines were not embedded, so those were matched by name and alias only.',
      );
    }
  } catch (error) {
    warnings.push(embeddingWarning(error));
  }

  return embeddings;
}

/** Why the vector leg is missing, in a sentence the caller can act on. */
function embeddingWarning(error: unknown): string {
  const reason = isFunctionError(error)
    ? error.message
    : error instanceof Error
      ? error.message
      : 'the embedding model could not be reached';
  return `The lines could not be embedded (${reason}), so they were matched by name and alias only.`;
}

/** The request body, or an `invalid_request` failure. */
async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new FunctionError(
      'invalid_request',
      'Send the bill lines as a JSON body.',
    );
  }
}
