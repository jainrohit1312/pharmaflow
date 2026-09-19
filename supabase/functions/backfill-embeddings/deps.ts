/**
 * The real world behind the backfill handler's seams: the caller's credentials,
 * the two RPCs, and the embedding model.
 *
 * Nothing here makes a decision - every rule lives in `handler.ts`,
 * `_shared/embedding.ts` and migration 00025, where it can be tested. This is the
 * wiring, and its job is to be small enough to read in one sitting.
 *
 * The one thing worth reading twice is `embed`: it is deliberately **stricter**
 * than the matcher's. `match-product` treats a missing vector as "that line has no
 * vector leg" and carries on, because a suggestion is an enhancement; the backfill
 * treats it as a refusal, because a half-written batch would look untouched
 * (`NULL` is the marker) while having spent model requests on rows it did not
 * finish.
 */

import { env, requirePharmacyId, userClient } from '../_shared/client.ts';
import {
  batchEmbedContentsUrl,
  buildBatchEmbedContentsBody,
  CATALOGUE_TASK_TYPE,
  DEFAULT_EMBEDDING_MODEL,
  EMBEDDING_DIMENSIONS,
  parseEmbeddings,
} from '../_shared/embedding.ts';
import { FunctionError } from '../_shared/errors.ts';
import { postGemini } from '../_shared/gemini.ts';
import type { HandlerDeps } from './handler.ts';

/** The embedding model to ask. A deployment can move it without a redeploy. */
const model =
  Deno.env.get('GEMINI_EMBEDDING_MODEL')?.trim() || DEFAULT_EMBEDDING_MODEL;

/** One row of the read RPC's `items`. */
interface RawItem {
  product_id?: unknown;
  text?: unknown;
}

export const defaultDeps: HandlerDeps = {
  model,

  /**
   * The caller's pharmacy, read as the caller.
   *
   * Neither RPC takes the value - both derive the same tenant from the same
   * identity - but asking for it first means an account with no pharmacy is
   * refused as such instead of being told there is nothing to embed.
   */
  getPharmacyId: (request) => requirePharmacyId(userClient(request)),

  /**
   * The next batch of the work list.
   *
   * The text comes back from the database (D-037) and is embedded verbatim: this
   * file never composes a catalogue string, because a second convention is a
   * matcher that ranks at random.
   */
  read: async (request, limit) => {
    const { data, error } = await userClient(request).rpc('products_to_embed', {
      p_limit: limit,
    });

    if (error) {
      throw new FunctionError(
        'internal',
        `Could not read the catalogue backfill list: ${error.message}`,
      );
    }

    const record = asRecord(data);
    const rawItems = Array.isArray(record.items) ? record.items : [];

    const items = rawItems
      .map((entry) => asRecord(entry))
      .map((entry) => ({
        productId: typeof entry.product_id === 'string' ? entry.product_id : '',
        text: typeof entry.text === 'string' ? entry.text : '',
      }))
      // A row with no product id or no text is not embeddable, and the database
      // already excludes those - this is the second net, because sending an empty
      // string to the model would produce a vector for nothing.
      .filter((item) => item.productId.length > 0 && item.text.length > 0);

    return {
      items,
      remaining: asCount(record.remaining),
      unembeddable: asCount(record.unembeddable),
    };
  },

  /**
   * One `batchEmbedContents` request for the whole batch.
   *
   * The key is read per request rather than at module load, so a missing secret
   * is a sentence the operator can read rather than a function that fails to
   * start.
   */
  embed: async (request, texts) => {
    const apiKey = env('GEMINI_API_KEY');

    const reply = await postGemini(
      {
        url: batchEmbedContentsUrl(model),
        request: buildBatchEmbedContentsBody({
          model,
          texts,
          // The catalogue side: what a product *is*. The matcher asks the other
          // way round (`RETRIEVAL_QUERY`) for an invoice line (D-037).
          taskType: CATALOGUE_TASK_TYPE,
        }),
      },
      apiKey,
    );

    const vectors = parseEmbeddings(reply, texts.length);

    // Stricter than the matcher's, on purpose: a batch with a hole in it is
    // refused whole, because the rows that did get a vector would be written
    // alongside rows that still look untouched.
    return vectors.map((vector, index) => {
      if (vector === null || vector.length !== EMBEDDING_DIMENSIONS) {
        throw new FunctionError(
          'provider_unavailable',
          `The embedding model did not answer for catalogue row ${index + 1} of ${texts.length}. Nothing was written; run the batch again.`,
        );
      }
      return vector;
    });
  },

  /**
   * The write, as the caller (D-004).
   *
   * `p_items` carries a product id and 768 numbers per row; the pharmacy does not
   * travel, and the RPC scopes every update to `get_my_pharmacy_id()` - so this
   * call cannot set a vector on another tenant's catalogue even if this file were
   * wrong.
   */
  write: async (request, items) => {
    const { data, error } = await userClient(request).rpc(
      'set_product_embeddings',
      {
        p_items: items.map((item) => ({
          product_id: item.productId,
          embedding: item.embedding,
        })),
      },
    );

    if (error) {
      throw new FunctionError(
        'internal',
        `The catalogue embeddings could not be written: ${error.message}`,
      );
    }

    const record = asRecord(data);

    return {
      written: asCount(record.written),
      remaining: asCount(record.remaining),
      unembeddable: asCount(record.unembeddable),
      skipped: Array.isArray(record.skipped) ? record.skipped : [],
    };
  },
};

/** [value] as an object, or an empty one. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** [value] as a whole number, or 0. */
function asCount(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.trunc(value)
    : 0;
}
