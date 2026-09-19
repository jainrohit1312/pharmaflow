/**
 * The embedding half of the smart match: what text to send, what to ask for,
 * and what the reply is allowed to contain.
 *
 * Two callers share this, and they must not drift:
 *
 *   - `match-product` embeds an *invoice text* (his task type `RETRIEVAL_QUERY`)
 *     to give the match RPC its vector leg;
 *   - the backfill embeds *catalogue text* (`RETRIEVAL_DOCUMENT`) built by the
 *     database's own `product_embedding_text()`.
 *
 * The dimension is the schema's hard constant (768, migration 00022 / D-027), so
 * it is asked for explicitly rather than left to the model's default: the model
 * emits 3072 unless told otherwise, and a 3072-element array does not fit a
 * `vector(768)` column. Two conventions producing incomparable vectors is the
 * failure D-027 warns about, and its symptom is a matcher that ranks at random,
 * so this file is deliberately the only place either side is expressed.
 *
 * Nothing here makes a request or decides a policy: `_shared/gemini.ts` posts,
 * and the callers decide when a failure is worth reporting.
 */

import { FunctionError } from './errors.ts';

/**
 * The embedding model, unless a deployment overrides it.
 *
 * The same rule as the vision model (D-030): a model name is not guesswork and
 * not permanent, so it is a constant with a secret override, and a change is
 * verified by one live call rather than by reading documentation.
 */
export const DEFAULT_EMBEDDING_MODEL = 'gemini-embedding-001';

/** The width of `products.embedding` (migration 00022, D-027). */
export const EMBEDDING_DIMENSIONS = 768;

/** The catalogue side: what a product *is*. */
export const CATALOGUE_TASK_TYPE = 'RETRIEVAL_DOCUMENT';

/** The query side: what a supplier's invoice line *says*. */
export const QUERY_TASK_TYPE = 'RETRIEVAL_QUERY';

/** Where the Generative Language API lives. */
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta';

/**
 * The invoice text to embed.
 *
 * Deliberately NOT `normalize_product_name()`: that function exists to make two
 * spellings *identical* for an exact alias comparison, and it does it by deleting
 * everything that is not a letter or a digit - turning `Dolo650Tab15s` into one
 * unbroken token. An embedding built from that has lost the word boundaries the
 * model reads, which is the opposite of what this leg is for. The query keeps the
 * supplier's own words, with runs of whitespace collapsed so the text is stable.
 *
 * Returns `null` for text with nothing in it, which the caller reads as "no
 * embedding for this line" rather than as an empty string to embed.
 */
export function queryEmbeddingText(raw: string | null | undefined): string | null {
  if (typeof raw !== 'string') {
    return null;
  }
  const collapsed = raw.replace(/\s+/g, ' ').trim();
  return collapsed.length === 0 ? null : collapsed;
}

/** The URL a batch of texts is embedded by, with the API key kept out of it. */
export function batchEmbedContentsUrl(model: string): string {
  return `${GEMINI_API_BASE}/models/${model}:batchEmbedContents`;
}

/** What the request builder needs to know. */
export interface BatchEmbedInput {
  /** The model to ask. */
  model: string;
  /** The texts to embed, in the order the caller wants them back. */
  texts: string[];
  /** `RETRIEVAL_DOCUMENT` for catalogue text, `RETRIEVAL_QUERY` for a bill. */
  taskType: string;
}

/**
 * The request body for one batch.
 *
 * One request for a whole bill rather than one per line, because the key is on a
 * free tier (N-2): a twenty-line bill costs one request here and twenty through
 * `embedContent`. Every entry carries the full `models/<name>` because that is
 * what `batchEmbedContents` requires, and the dimension is pinned for the reason
 * in this file's header.
 */
export function buildBatchEmbedContentsBody(input: BatchEmbedInput): unknown {
  return {
    requests: input.texts.map((text) => ({
      model: `models/${input.model}`,
      content: { parts: [{ text }] },
      taskType: input.taskType,
      outputDimensionality: EMBEDDING_DIMENSIONS,
    })),
  };
}

/**
 * The vectors out of a `batchEmbedContents` reply, one per text asked for.
 *
 * A reply that is missing an entry, or carrying an entry of the wrong width, is a
 * `provider_unavailable` failure rather than a quietly dropped vector: a wrong
 * width means the dimension request was ignored, and every vector in the batch is
 * then incomparable with the catalogue. Failing loudly is what turns that from a
 * matcher that returns nonsense into a sentence somebody can read - and the
 * caller degrades to the alias and trigram legs, which do not depend on vectors
 * at all.
 */
export function parseEmbeddings(
  apiResponse: unknown,
  expected: number,
): (number[] | null)[] {
  const embeddings = asRecord(apiResponse).embeddings;
  if (!Array.isArray(embeddings)) {
    throw new FunctionError(
      'provider_unavailable',
      'The embedding model did not answer with any vectors.',
    );
  }

  const vectors: (number[] | null)[] = [];
  for (let index = 0; index < expected; index++) {
    const entry = asRecord(embeddings[index]);
    const values = entry.values;

    if (values === undefined || values === null) {
      vectors.push(null);
      continue;
    }
    if (!Array.isArray(values) || !values.every((v) => typeof v === 'number')) {
      throw new FunctionError(
        'provider_unavailable',
        `Embedding ${index + 1} of ${expected} came back in a shape that is not a list of numbers.`,
      );
    }
    if (values.length !== EMBEDDING_DIMENSIONS) {
      throw new FunctionError(
        'provider_unavailable',
        `Embedding ${index + 1} came back with ${values.length} dimensions where the catalogue stores ${EMBEDDING_DIMENSIONS}. Nothing could be compared with it.`,
      );
    }
    vectors.push(values as number[]);
  }

  return vectors;
}

/** [value] as an object, or an empty one. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
