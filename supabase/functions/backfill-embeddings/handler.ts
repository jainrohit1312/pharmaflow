/**
 * The embedding backfill's request path: **one invocation, one batch**.
 *
 * `products.embedding is null` is the work list (D-027), and this function moves
 * one batch of vectors into it: read the batch, embed it in one
 * `batchEmbedContents` request, write it back, and report how much is left. It
 * does **not** loop. The operator repeats the invocation until `remaining` is 0,
 * which is what makes the backfill stoppable - and what keeps it from holding the
 * model key for minutes on end while a bill is waiting to be read (N-2: the
 * reader and the model share one key).
 *
 * Four rules shape this file, each one a decision:
 *
 *   1. **All or nothing per batch.** If the model fails, is busy, or answers with
 *      fewer vectors than it was asked for, the batch is refused and **nothing is
 *      written**. A half-embedded batch would be invisible afterwards - `NULL` is
 *      the marker, so the rows that did not get a vector simply stay in the work
 *      list looking untouched - which is exactly why the write happens only once
 *      the whole batch is in hand.
 *   2. **One batch is one embedding request.** C3's first live measurement sized
 *      the batch: 20 texts per request is safe (D-041), and the key's per-minute
 *      ceiling is not the reader's (D-041 again).
 *   3. **The tenant is never an argument.** `getPharmacyId` asks the caller's own
 *      identity and the RPCs derive it again from `get_my_pharmacy_id()`
 *      (D-004/D-026); the caller's own JWT is what makes every read and write
 *      land in the caller's catalogue.
 *   4. **The catalogue text is the database's.** `products_to_embed` returns the
 *      string `product_embedding_text()` produces (D-037) and this file embeds it
 *      verbatim - it never composes a catalogue string of its own, because that
 *      would be a second convention and the symptom of two conventions is a
 *      matcher that ranks at random.
 */

import { FunctionError, isFunctionError } from '../_shared/errors.ts';
import { failJson, okJson, preflight } from '../_shared/response.ts';

/**
 * How many catalogue rows one invocation embeds.
 *
 * The measured-safe batch size (D-041: four 20-text requests in a row, all
 * answered, `vector_used` true throughout). A caller may ask for less; asking for
 * more is clamped, and the clamp is a payload guard rather than a measurement.
 */
export const DEFAULT_BATCH = 20;

/** The most one invocation will embed, however large a `limit` it is sent. */
export const MAX_BATCH = 100;

/** One row the backfill has to embed. */
export interface EmbedItem {
  /** The catalogue product. */
  productId: string;
  /** The catalogue text, exactly as `product_embedding_text()` built it. */
  text: string;
}

/** What one read of the work list answered. */
export interface EmbedBatch {
  items: EmbedItem[];
  /** Rows still to embed after this batch, according to the database. */
  remaining: number;
  /** Rows that can never be embedded, because they have no text to embed. */
  unembeddable: number;
}

/** What one write answered. */
export interface EmbedWrite {
  written: number;
  remaining: number;
  unembeddable: number;
  skipped: unknown[];
}

/** Everything the handler needs from the outside world. */
export interface HandlerDeps {
  /** The embedding model to ask. */
  model: string;
  /** The pharmacy the caller belongs to. Never taken from the request. */
  getPharmacyId(request: Request): Promise<string>;
  /** The next batch of work, and how much of it there is. */
  read(request: Request, limit: number): Promise<EmbedBatch>;
  /** One vector per text, in the same order. */
  embed(request: Request, texts: string[]): Promise<number[][]>;
  /** Writes the batch, and answers with what is left. */
  write(
    request: Request,
    items: { productId: string; embedding: number[] }[],
  ): Promise<EmbedWrite>;
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
        throw new FunctionError(
          'invalid_request',
          'This endpoint accepts POST.',
        );
      }

      const limit = readLimit(await readJsonBody(request));

      // Before anything else: an account with no pharmacy has no catalogue, and
      // saying so is better than answering "nothing to do".
      await deps.getPharmacyId(request);

      const batch = await deps.read(request, limit);

      if (batch.items.length === 0) {
        // Nothing to do is an answer, not a failure - and it must cost no model
        // request, because the point of asking is to find out whether there is
        // any work.
        return okJson({
          embedded: 0,
          remaining: 0,
          unembeddable: batch.unembeddable,
          skipped: [],
          model: deps.model,
        });
      }

      const vectors = await embedAll(deps, request, batch.items);
      const written = await deps.write(
        request,
        batch.items.map((item, index) => ({
          productId: item.productId,
          embedding: vectors[index],
        })),
      );

      return okJson({
        embedded: written.written,
        remaining: written.remaining,
        unembeddable: written.unembeddable,
        // Empty on a healthy batch. A non-empty list is the database saying an
        // entry was unusable, and an operator who is looping on `remaining`
        // deserves to know why a batch was short.
        skipped: written.skipped,
        model: deps.model,
      });
    } catch (error) {
      if (isFunctionError(error)) {
        console.error(`backfill-embeddings refused: ${error.code} - ${error.message}`);
        return failJson(error);
      }

      console.error('backfill-embeddings failed unexpectedly', error);
      return failJson(error);
    }
  };
}

/**
 * One vector per item, or a refusal.
 *
 * The whole batch is refused if any line comes back without a vector or with the
 * wrong width: the caller's next action is to try the batch again, and a partial
 * write would leave rows that look untouched (their `embedding` is still NULL)
 * while having quietly spent model requests on them.
 */
async function embedAll(
  deps: HandlerDeps,
  request: Request,
  items: EmbedItem[],
): Promise<number[][]> {
  const texts = items.map((item) => item.text);
  const vectors = await deps.embed(request, texts);

  if (vectors.length !== items.length) {
    throw new FunctionError(
      'provider_unavailable',
      `The embedding model answered with ${vectors.length} vectors for ${items.length} catalogue rows. Nothing was written; run the batch again.`,
    );
  }

  return vectors;
}

/** The batch size the caller asked for, clamped to what one invocation may do. */
export function readLimit(body: unknown): number {
  const record =
    typeof body === 'object' && body !== null
      ? (body as Record<string, unknown>)
      : {};
  const raw = record.limit;

  if (raw === undefined || raw === null) {
    return DEFAULT_BATCH;
  }
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 1) {
    throw new FunctionError(
      'invalid_request',
      'Send a `limit` of at least 1, or send no body at all.',
    );
  }

  return Math.min(Math.floor(raw), MAX_BATCH);
}

/** The request body, or an empty object when there is none. */
async function readJsonBody(request: Request): Promise<unknown> {
  const text = await request.text();
  if (text.trim().length === 0) {
    // A bare POST is "one default batch", which is what the Makefile target and
    // a curl one-liner both send.
    return {};
  }

  try {
    return JSON.parse(text);
  } catch {
    throw new FunctionError(
      'invalid_request',
      'Send the batch size as a JSON body, e.g. {"limit": 20}.',
    );
  }
}
