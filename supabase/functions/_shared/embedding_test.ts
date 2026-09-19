/**
 * Tests for the embedding convention and the request/reply shapes.
 *
 * The two things worth pinning here are the ones that fail silently in
 * production: the dimension (a model asked for nothing returns 3072, and a
 * 3072-element array fits no `vector(768)` column) and the query text (which must
 * keep its word boundaries, unlike `normalize_product_name()`).
 *
 * Run: `deno test supabase/functions/_shared/embedding_test.ts`
 */

import { assert, assertEquals, assertStrictEquals, assertThrows } from 'jsr:@std/assert';
import {
  batchEmbedContentsUrl,
  buildBatchEmbedContentsBody,
  CATALOGUE_TASK_TYPE,
  DEFAULT_EMBEDDING_MODEL,
  EMBEDDING_DIMENSIONS,
  parseEmbeddings,
  QUERY_TASK_TYPE,
  queryEmbeddingText,
} from './embedding.ts';

/** A vector of the width the column stores. */
function vectorOf(width: number, value = 0.5): number[] {
  return Array.from({ length: width }, () => value);
}

Deno.test('the query text keeps the words the supplier printed', () => {
  // Not normalize_product_name(): that would return 'dolo650tab15s', and an
  // embedding of one unbroken token has lost the word boundaries the model reads.
  assertEquals(queryEmbeddingText('Dolo650Tab15s'), 'Dolo650Tab15s');
  assertEquals(queryEmbeddingText('Dolo 650 Tab 15s'), 'Dolo 650 Tab 15s');
  assertEquals(queryEmbeddingText('Amoxy-Clav   625 / 10s'), 'Amoxy-Clav 625 / 10s');
});

Deno.test('text with nothing in it is no text', () => {
  assertStrictEquals(queryEmbeddingText(''), null);
  assertStrictEquals(queryEmbeddingText('   \n\t '), null);
  assertStrictEquals(queryEmbeddingText(null), null);
  assertStrictEquals(queryEmbeddingText(undefined), null);
});

Deno.test('the batch URL is the model the backfill will use too', () => {
  assertEquals(
    batchEmbedContentsUrl(DEFAULT_EMBEDDING_MODEL),
    `https://generativelanguage.googleapis.com/v1beta/models/${DEFAULT_EMBEDDING_MODEL}:batchEmbedContents`,
  );
});

Deno.test('a batch request pins the dimension and the task type per entry', () => {
  const body = buildBatchEmbedContentsBody({
    model: DEFAULT_EMBEDDING_MODEL,
    texts: ['Dolo 650', 'Amoxyclav 625'],
    taskType: QUERY_TASK_TYPE,
  }) as { requests: Record<string, any>[] };

  assertEquals(body.requests.length, 2);
  for (const request of body.requests) {
    assertEquals(request['model'], `models/${DEFAULT_EMBEDDING_MODEL}`);
    assertEquals(request['taskType'], QUERY_TASK_TYPE);
    assertEquals(request['outputDimensionality'], EMBEDDING_DIMENSIONS);
  }
  assertEquals(body.requests[0]['content']['parts'][0]['text'], 'Dolo 650');
  assertEquals(body.requests[1]['content']['parts'][0]['text'], 'Amoxyclav 625');
});

Deno.test('the two sides use different task types, as the API intends', () => {
  assertEquals(CATALOGUE_TASK_TYPE, 'RETRIEVAL_DOCUMENT');
  assertEquals(QUERY_TASK_TYPE, 'RETRIEVAL_QUERY');
});

Deno.test('a batch reply is read back in the order it was asked for', () => {
  const vectors = parseEmbeddings(
    {
      embeddings: [
        { values: vectorOf(EMBEDDING_DIMENSIONS, 1) },
        { values: vectorOf(EMBEDDING_DIMENSIONS, 2) },
      ],
    },
    2,
  );

  assertEquals(vectors.length, 2);
  assertEquals(vectors[0]?.[0], 1);
  assertEquals(vectors[1]?.[0], 2);
});

Deno.test('an entry the model did not answer for is null, not a wrong vector', () => {
  const vectors = parseEmbeddings({ embeddings: [{ values: vectorOf(768) }] }, 2);

  assertEquals(vectors.length, 2);
  assert(vectors[0] !== null);
  assertStrictEquals(vectors[1], null);
});

Deno.test('a reply with no vectors at all is a provider failure', () => {
  assertThrows(
    () => parseEmbeddings({}, 1),
    Error,
    'did not answer with any vectors',
  );
  assertThrows(
    () => parseEmbeddings({ embeddings: 'nope' }, 1),
    Error,
    'did not answer with any vectors',
  );
});

Deno.test('the wrong width is refused rather than stored', () => {
  // 3072 is what the model returns when the dimension is not asked for, and it
  // does not fit products.embedding - so this must fail loudly.
  const error = assertThrows(
    () => parseEmbeddings({ embeddings: [{ values: vectorOf(3072) }] }, 1),
    Error,
    '3072 dimensions',
  );
  assertEquals((error as { code?: string }).code, 'provider_unavailable');
});

Deno.test('values that are not numbers are refused', () => {
  assertThrows(
    () => parseEmbeddings({ embeddings: [{ values: ['a', 'b'] }] }, 1),
    Error,
    'not a list of numbers',
  );
});
