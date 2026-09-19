/**
 * Tests for the backfill's request path, with every effect stubbed.
 *
 * The rules this file is the evidence for:
 *
 *   - **one invocation embeds one batch**, and the batch it embeds is the one the
 *     database offered - the catalogue text is never recomposed here (D-037);
 *   - **all or nothing**: a model failure, a short answer or a hole in the batch
 *     writes *nothing*, because a half-written batch is invisible afterwards
 *     (`NULL` is the marker, D-027);
 *   - **nothing to do costs no model request** - the loop's stop condition must
 *     not spend a call to discover it has nothing to do;
 *   - the tenant comes from the caller's identity and never from the body.
 */

import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { FunctionError } from '../_shared/errors.ts';
import {
  createHandler,
  DEFAULT_BATCH,
  type EmbedBatch,
  type EmbedWrite,
  MAX_BATCH,
  readLimit,
  type HandlerDeps,
} from './handler.ts';

/** The text of the request a handler test makes. */
const REQUEST = () =>
  new Request('https://example.test/backfill-embeddings', {
    method: 'POST',
    body: JSON.stringify({}),
  });

/** One 768-number vector, so the fake answers with a shape the write can use. */
const VECTOR = Array.from({ length: 768 }, (_, index) => (index === 0 ? 1 : 0));

/** What a handler test can watch happen. */
interface Recorded {
  reads: number[];
  embedded: string[][];
  writes: { productId: string; embedding: number[] }[][];
  pharmacyAsked: number;
}

/** A full set of stubs, with [overrides] replacing any of them. */
function stubDeps(overrides: Partial<HandlerDeps> = {}): {
  deps: HandlerDeps;
  seen: Recorded;
} {
  const seen: Recorded = {
    reads: [],
    embedded: [],
    writes: [],
    pharmacyAsked: 0,
  };

  const batch: EmbedBatch = {
    items: [
      { productId: 'p-1', text: 'Dolo 650 Paracetamol 15s' },
      { productId: 'p-2', text: 'Cetirizine 10mg Cetirizine 10s' },
    ],
    remaining: 2,
    unembeddable: 0,
  };

  const written: EmbedWrite = {
    written: 2,
    remaining: 0,
    unembeddable: 0,
    skipped: [],
  };

  const deps: HandlerDeps = {
    model: 'gemini-embedding-001',
    getPharmacyId: async () => {
      seen.pharmacyAsked++;
      return 'ph-1';
    },
    read: async (_request, limit) => {
      seen.reads.push(limit);
      return batch;
    },
    embed: async (_request, texts) => {
      seen.embedded.push(texts);
      return texts.map(() => VECTOR);
    },
    write: async (_request, items) => {
      seen.writes.push(items);
      return written;
    },
    ...overrides,
  };

  return { deps, seen };
}

/** The parsed body of [response]. */
async function body(response: Response): Promise<Record<string, unknown>> {
  return JSON.parse(await response.text()) as Record<string, unknown>;
}

Deno.test('embeds one batch and reports what is left', async () => {
  const { deps, seen } = stubDeps();
  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 200);
  assertEquals(await body(response), {
    embedded: 2,
    remaining: 0,
    unembeddable: 0,
    skipped: [],
    model: 'gemini-embedding-001',
  });

  assertEquals(seen.reads, [DEFAULT_BATCH]);
  assertEquals(seen.pharmacyAsked, 1);
  assertEquals(seen.writes.length, 1);

  // The catalogue text travels verbatim: whatever the database said a product is,
  // is what the model is asked about (D-037).
  assertEquals(seen.embedded, [
    ['Dolo 650 Paracetamol 15s', 'Cetirizine 10mg Cetirizine 10s'],
  ]);

  // And the same text is paired with the same product on the way back.
  assertEquals(
    seen.writes[0].map((item) => item.productId),
    ['p-1', 'p-2'],
  );
  assertEquals(seen.writes[0][0].embedding.length, 768);
});

Deno.test('a model failure writes nothing and says the batch is worth repeating', async () => {
  const { deps, seen } = stubDeps({
    embed: async () => {
      // The free-tier key's busy answer, as Chunk B1 measured it (D-032).
      throw new Error('the model is currently experiencing high demand');
    },
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 500, 'an unexpected throw is a bug, not a refusal');
  // Crucially: nothing was written. The rows are still in the work list, which is
  // exactly where they should be.
  assertEquals(seen.writes.length, 0);
});

Deno.test('a provider refusal is reported as retryable, and writes nothing', async () => {
  const { deps, seen } = stubDeps({
    embed: async () => {
      throw new FunctionError('provider_unavailable', 'The model is busy.');
    },
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 502);
  const parsed = await body(response);
  assertEquals((parsed.error as Record<string, unknown>).code, 'provider_unavailable');
  assertEquals(seen.writes.length, 0);
});

Deno.test('a short answer is refused rather than written half-way', async () => {
  // Two rows asked for, one vector back. Writing that batch would leave p-2
  // looking untouched while having spent a model request on it.
  const { deps, seen } = stubDeps({
    embed: async () => [VECTOR],
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 502);
  const parsed = await body(response);
  assertEquals((parsed.error as Record<string, unknown>).code, 'provider_unavailable');
  assertEquals(seen.writes.length, 0);
});

Deno.test('nothing to do is an answer, and costs no model request', async () => {
  const { deps, seen } = stubDeps({
    read: async () => ({ items: [], remaining: 0, unembeddable: 3 }),
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 200);
  assertEquals(await body(response), {
    embedded: 0,
    remaining: 0,
    unembeddable: 3,
    skipped: [],
    model: 'gemini-embedding-001',
  });
  assertEquals(
    seen.embedded.length,
    0,
    'the loop learns it is finished without spending a call',
  );
  assertEquals(seen.writes.length, 0);
});

Deno.test('a row the database refused to write is reported back', async () => {
  // The write RPC skips what it cannot use; the operator looping on `remaining`
  // has to be able to see that a batch came up short and why.
  const { deps } = stubDeps({
    write: async () => ({
      written: 1,
      remaining: 1,
      unembeddable: 0,
      skipped: [{ product_id: 'p-2', reason: 'that product is not in this catalogue' }],
    }),
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 200);
  const parsed = await body(response);
  assertEquals(parsed.embedded, 1);
  assertEquals(parsed.remaining, 1);
  assertEquals((parsed.skipped as unknown[]).length, 1);
});

Deno.test('the batch size the caller asks for is used, up to the guard', async () => {
  const { deps, seen } = stubDeps();

  await createHandler(deps)(
    new Request('https://example.test/', {
      method: 'POST',
      body: JSON.stringify({ limit: 5 }),
    }),
  );
  await createHandler(deps)(
    new Request('https://example.test/', {
      method: 'POST',
      body: JSON.stringify({ limit: 5000 }),
    }),
  );

  assertEquals(seen.reads, [5, MAX_BATCH]);
});

Deno.test('a body the handler cannot read is refused, not guessed at', async () => {
  const { deps, seen } = stubDeps();

  const bad = await createHandler(deps)(
    new Request('https://example.test/', { method: 'POST', body: 'not json' }),
  );
  assertEquals(bad.status, 400);
  assertEquals(
    ((await body(bad)).error as Record<string, unknown>).code,
    'invalid_request',
  );

  const zero = await createHandler(deps)(
    new Request('https://example.test/', {
      method: 'POST',
      body: JSON.stringify({ limit: 0 }),
    }),
  );
  assertEquals(zero.status, 400);

  // A bare POST is one default batch: the Makefile target and a curl one-liner
  // both send no body at all.
  const bare = await createHandler(deps)(
    new Request('https://example.test/', { method: 'POST' }),
  );
  assertEquals(bare.status, 200);

  assertEquals(seen.reads, [DEFAULT_BATCH]);
});

Deno.test('a caller with no pharmacy is refused before any work is done', async () => {
  const { deps, seen } = stubDeps({
    getPharmacyId: async () => {
      throw new FunctionError(
        'unauthorized',
        'This account is not linked to a pharmacy yet.',
      );
    },
  });

  const response = await createHandler(deps)(REQUEST());

  assertEquals(response.status, 401);
  assertEquals(
    ((await body(response)).error as Record<string, unknown>).message,
    'This account is not linked to a pharmacy yet.',
  );
  assertEquals(seen.reads.length, 0);
});

Deno.test('GET is refused and OPTIONS is a preflight', async () => {
  const { deps } = stubDeps();
  const handler = createHandler(deps);

  const get = await handler(new Request('https://example.test/', { method: 'GET' }));
  assertEquals(get.status, 400);

  const options = await handler(
    new Request('https://example.test/', { method: 'OPTIONS' }),
  );
  assertEquals(options.status, 204);
  assertEquals(
    options.headers.get('access-control-allow-origin'),
    '*',
  );
});

Deno.test('readLimit clamps and refuses the same way the handler does', async () => {
  assertEquals(readLimit(null), DEFAULT_BATCH);
  assertEquals(readLimit({}), DEFAULT_BATCH);
  assertEquals(readLimit({ limit: 1 }), 1);
  assertEquals(readLimit({ limit: 20.7 }), 20);
  assertEquals(readLimit({ limit: MAX_BATCH * 10 }), MAX_BATCH);

  for (const body of [0, -1, 'twenty', Number.NaN]) {
    await assertRejects(
      async () => readLimit({ limit: body }),
      Error,
      'at least 1',
    );
  }
});
