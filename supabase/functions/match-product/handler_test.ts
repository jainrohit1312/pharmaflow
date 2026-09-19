/**
 * Tests for the match handler, with every dependency stubbed.
 *
 * Three properties are the point, and each one has assertions here that exist for
 * nothing else:
 *
 *   - **the tenant never travels.** The request carries no pharmacy, the RPC
 *     receives none, and the caller's identity is consulted first - so a request
 *     cannot ask for another catalogue (D-004/D-026);
 *   - **an embedding failure is not a bill failure.** The match still runs, with
 *     no vectors, and says so in `meta.warnings` (N-2, D-032);
 *   - **the answer lines up with the bill.** A blank line keeps its position, and
 *     the supplier travels only when it is a uuid.
 *
 * Run: `deno test supabase/functions/match-product/handler_test.ts`
 */

import { assertEquals, assertStrictEquals, assertStringIncludes } from 'jsr:@std/assert';
import { FunctionError } from '../_shared/errors.ts';
import {
  createHandler,
  MAX_MATCH_LINES,
  MATCH_LIMIT,
  type HandlerDeps,
  type MatchQuery,
  validateLines,
} from './handler.ts';

const PHARMACY = '11111111-1111-1111-1111-111111111111';
const SUPPLIER = '33333333-3333-3333-3333-333333333333';

/** A stand-in vector. The handler does not care how wide it is; `parseEmbeddings` does. */
const VECTOR = [0.1, 0.2, 0.3];

const MATCHES = [
  {
    raw_name: 'Dolo650Tab15s',
    candidates: [
      { product_id: 'p1', name: 'Dolo 650', reason: 'trigram', score: 0.4545 },
    ],
  },
];

/** What a stubbed handler was asked to do. */
interface Calls {
  pharmacyChecks: number;
  embedTexts: string[][];
  matchQueries: MatchQuery[][];
}

/** Deps with only the behaviour a test cares about replaced. */
function stubDeps(overrides: Partial<HandlerDeps> = {}): {
  deps: HandlerDeps;
  calls: Calls;
} {
  const calls: Calls = { pharmacyChecks: 0, embedTexts: [], matchQueries: [] };

  const deps: HandlerDeps = {
    model: 'gemini-embedding-001',
    getPharmacyId: () => {
      calls.pharmacyChecks += 1;
      return Promise.resolve(PHARMACY);
    },
    embed: (_request, texts) => {
      calls.embedTexts.push(texts);
      return Promise.resolve(texts.map(() => VECTOR));
    },
    match: (_request, queries) => {
      calls.matchQueries.push(queries);
      return Promise.resolve(MATCHES);
    },
    ...overrides,
  };

  return { deps, calls };
}

/** A POST whose body is [body]. */
function post(body: unknown): Request {
  return new Request('https://example.test/match-product', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/** The parsed body of a response, for asserting on the envelope. */
async function bodyOf(response: Response): Promise<Record<string, any>> {
  return await response.json() as Record<string, any>;
}

Deno.test('a preflight is answered so a browser can call this at all', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/match-product', { method: 'OPTIONS' }),
  );

  assertEquals(response.status, 204);
  assertEquals(response.headers.get('access-control-allow-origin'), '*');
});

Deno.test('only POST is served', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/match-product', { method: 'GET' }),
  );

  assertEquals(response.status, 400);
  assertEquals((await bodyOf(response)).error.code, 'invalid_request');
});

Deno.test('a body that is not JSON is refused with a sentence about the body', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/match-product', {
      method: 'POST',
      body: 'the lines, please',
    }),
  );

  assertStringIncludes((await bodyOf(response)).error.message, 'JSON');
});

Deno.test('a request with no lines is refused before anything else happens', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({}));

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'lines of the bill');
  assertEquals(calls.pharmacyChecks, 0);
  assertEquals(calls.embedTexts, []);
});

Deno.test('the line that is wrong is named in the refusal', () => {
  try {
    validateLines(['Dolo 650', 42]);
    throw new Error('expected a failure');
  } catch (error) {
    assertStringIncludes((error as Error).message, 'Line 2');
  }
});

Deno.test('a line may be a bare string or an object', () => {
  const lines = validateLines(['Dolo 650', { raw_name: 'Amoxyclav 625' }, { raw_name: 7 }]);

  assertEquals(lines.length, 3);
  assertEquals(lines[0], { rawName: 'Dolo 650', supplierId: null });
  assertEquals(lines[1], { rawName: 'Amoxyclav 625', supplierId: null });
  // A line the reader could not read is kept, so the answer stays lined up.
  assertStrictEquals(lines[2].rawName, null);
});

Deno.test('a supplier id that is not a uuid does not travel', () => {
  const lines = validateLines([
    { raw_name: 'Dolo 650', supplier_id: SUPPLIER },
    { raw_name: 'Dolo 650', supplier_id: 'not-a-uuid' },
    { raw_name: 'Dolo 650', supplier_id: { nested: true } },
  ]);

  assertEquals(lines[0].supplierId, SUPPLIER);
  assertStrictEquals(lines[1].supplierId, null);
  assertStrictEquals(lines[2].supplierId, null);
});

Deno.test('a bill is matched with one embedding call and one RPC call', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post({
      lines: [
        { raw_name: 'Dolo650Tab15s', supplier_id: SUPPLIER },
        { raw_name: 'Amoxyclav 625' },
      ],
    }),
  );

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.matches, MATCHES);
  assertEquals(body.meta.vector_used, true);
  assertEquals(body.meta.embedded, 2);
  assertEquals(body.meta.line_count, 2);
  assertEquals(body.meta.warnings, []);

  // One batch for the whole bill, in the bill's order - the free tier allows five
  // requests a minute and the reader shares the key (N-2).
  assertEquals(calls.embedTexts, [['Dolo650Tab15s', 'Amoxyclav 625']]);
  assertEquals(calls.matchQueries.length, 1);

  const queries = calls.matchQueries[0];
  assertEquals(queries.length, 2);
  assertEquals(queries[0], {
    raw_name: 'Dolo650Tab15s',
    supplier_id: SUPPLIER,
    query_embedding: VECTOR,
  });
  assertEquals(queries[1].supplier_id, null);
  assertEquals(queries[1].raw_name, 'Amoxyclav 625');
});

Deno.test('the caller never sends a pharmacy, and the RPC is never asked for one', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post({ lines: ['Dolo 650'], pharmacy_id: '22222222-2222-2222-2222-222222222222' }),
  );

  assertEquals(response.status, 200);
  assertEquals(calls.pharmacyChecks, 1);
  const payload = JSON.stringify(calls.matchQueries[0]);
  assertEquals(payload.includes('22222222'), false);
  assertEquals(payload.includes('pharmacy'), false);
  assertEquals(payload.includes(PHARMACY), false);
});

Deno.test('an unlinked account is refused rather than answered with nothing', async () => {
  const { deps, calls } = stubDeps({
    getPharmacyId: () =>
      Promise.reject(new FunctionError('unauthorized', 'This account is not linked to a pharmacy yet.')),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650'] }));

  assertEquals(response.status, 401);
  assertEquals((await bodyOf(response)).error.code, 'unauthorized');
  assertEquals(calls.embedTexts, []);
  assertEquals(calls.matchQueries, []);
});

Deno.test('a blank line keeps its place and spends no embedding slot', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post({ lines: ['Dolo 650', '   ', { raw_name: null }] }),
  );

  const body = await bodyOf(response);
  assertEquals(body.meta.line_count, 3);
  assertEquals(body.meta.embedded, 1);
  // One text embedded out of three lines, and the vector lands on the right one.
  assertEquals(calls.embedTexts, [['Dolo 650']]);
  const queries = calls.matchQueries[0];
  assertEquals(queries.length, 3);
  assertStrictEquals(queries[1].query_embedding, null);
  assertStrictEquals(queries[2].query_embedding, null);
  assertStrictEquals(queries[1].raw_name, '   ');
});

Deno.test('a bill with nothing readable in it does not call the model at all', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({ lines: ['', '  '] }));

  assertEquals(response.status, 200);
  assertEquals(calls.embedTexts, []);
  // It still asks the catalogue, so a line the reader mangled but the aliases know
  // is still answered.
  assertEquals(calls.matchQueries.length, 1);
  assertEquals((await bodyOf(response)).meta.vector_used, false);
});

Deno.test('a busy embedding model costs the vectors, not the match', async () => {
  const { deps, calls } = stubDeps({
    embed: () =>
      Promise.reject(
        new FunctionError('provider_unavailable', 'The reader is busy right now. Try again in a moment.'),
      ),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo650Tab15s'] }));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.matches, MATCHES);
  assertEquals(body.meta.vector_used, false);
  assertEquals(body.meta.embedded, 0);
  assertEquals(body.meta.warnings.length, 1);
  assertStringIncludes(body.meta.warnings[0], 'matched by name and alias only');
  assertStringIncludes(body.meta.warnings[0], 'busy');

  // The RPC was still asked - with no vector, which the SQL reads as "no vector
  // leg" rather than as a malformed query.
  const queries = calls.matchQueries[0];
  assertStrictEquals(queries[0].query_embedding, null);
  assertEquals(queries[0].raw_name, 'Dolo650Tab15s');
});

Deno.test('a missing key is reported as a warning rather than a failed bill', async () => {
  const { deps } = stubDeps({
    embed: () =>
      Promise.reject(
        new FunctionError('not_configured', 'This function is missing its GEMINI_API_KEY secret.'),
      ),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650'] }));

  assertEquals(response.status, 200);
  const warnings = (await bodyOf(response)).meta.warnings as string[];
  assertStringIncludes(warnings[0], 'GEMINI_API_KEY');
});

Deno.test('fewer vectors than texts leaves the rest without one, and says so', async () => {
  const { deps, calls } = stubDeps({
    embed: (_request, texts) => Promise.resolve([VECTOR, ...texts.slice(1).map(() => null)]),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650', 'Amoxyclav 625'] }));

  const body = await bodyOf(response);
  assertEquals(body.meta.embedded, 1);
  assertEquals(body.meta.vector_used, true);
  assertStringIncludes(body.meta.warnings[0], 'not embedded');
  assertStrictEquals(calls.matchQueries[0][1].query_embedding, null);
});

Deno.test('a bill past the line limit is truncated, not refused', async () => {
  const lines = Array.from({ length: MAX_MATCH_LINES + 3 }, (_v, i) => `Line ${i + 1}`);
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({ lines }));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.meta.line_count, MAX_MATCH_LINES);
  assertEquals(calls.matchQueries[0].length, MAX_MATCH_LINES);
  assertStringIncludes(body.meta.warnings[0], `first ${MAX_MATCH_LINES} lines`);
});

Deno.test('an answer in an unexpected shape is an empty list with a warning', async () => {
  const { deps } = stubDeps({ match: () => Promise.resolve({ not: 'an array' }) });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650'] }));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.matches, []);
  assertStringIncludes(body.meta.warnings[0], 'does not understand');
});

Deno.test('a catalogue failure is reported as a failure, with the function vocabulary', async () => {
  const { deps } = stubDeps({
    match: () => Promise.reject(new FunctionError('internal', 'The catalogue match failed: nope')),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650'] }));

  assertEquals(response.status, 500);
  const body = await bodyOf(response);
  assertEquals(body.error.code, 'internal');
  assertStringIncludes(body.error.message, 'catalogue match failed');
});

Deno.test('an unexpected throw is an internal failure, not a leak', async () => {
  const { deps } = stubDeps({
    match: () => Promise.reject(new TypeError('cannot read properties of undefined')),
  });
  const response = await createHandler(deps)(post({ lines: ['Dolo 650'] }));

  assertEquals(response.status, 500);
  const body = await bodyOf(response);
  assertEquals(body.error.code, 'internal');
  assertStringIncludes(body.error.message, 'went wrong');
});

Deno.test('the limit asked of the RPC is the constant the app was told about', () => {
  assertEquals(MATCH_LIMIT, 5);
});
