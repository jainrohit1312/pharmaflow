/**
 * Tests for the one way a function talks to the Generative Language API.
 *
 * The interesting behaviour is all in the failure path: the free tier answers
 * `503 UNAVAILABLE` under a burst rather than `429` (D-032), and the message the
 * user reads has to be the same for both, while a 400 - which means *this*
 * function sent something the API would not accept - keeps the provider's own
 * words so the mistake is findable.
 *
 * `fetch` is injected, so none of this touches the network.
 *
 * Run: `deno test supabase/functions/_shared/gemini_test.ts`
 */

import { assertEquals, assertStringIncludes } from 'jsr:@std/assert';
import { postGemini, providerMessage } from './gemini.ts';

/** A fetch that records what it was asked for and answers with [response]. */
function stubFetch(response: Response): {
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  calls: { url: string; init: RequestInit }[];
} {
  const calls: { url: string; init: RequestInit }[] = [];
  return {
    calls,
    fetch: (url, init) => {
      calls.push({ url, init });
      return Promise.resolve(response);
    },
  };
}

const CALL = {
  url: 'https://generativelanguage.googleapis.com/v1beta/models/x:batchEmbedContents',
  request: { requests: [{ content: { parts: [{ text: 'Dolo 650' }] } }] },
};

Deno.test('a call carries the key in a header and the body as JSON', async () => {
  const { fetch, calls } = stubFetch(
    new Response(JSON.stringify({ embeddings: [{ values: [1] }] }), { status: 200 }),
  );

  const parsed = await postGemini(CALL, 'secret-key', fetch);

  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, CALL.url);
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers['x-goog-api-key'], 'secret-key');
  // Never in the URL: the API's own logs would keep it for ever.
  assertEquals(calls[0].url.includes('secret-key'), false);
  assertEquals(headers['content-type'], 'application/json');
  assertEquals(JSON.parse(calls[0].init.body as string), CALL.request);
  assertEquals(parsed, { embeddings: [{ values: [1] }] });
});

Deno.test('a busy reader is one sentence whoever refused', async () => {
  for (const status of [429, 503]) {
    const { fetch } = stubFetch(new Response('{"error":{"message":"high demand"}}', { status }));
    try {
      await postGemini(CALL, 'k', fetch);
      throw new Error('expected a failure');
    } catch (error) {
      const failure = error as { code?: string; message: string; detail?: unknown };
      assertEquals(failure.code, 'provider_unavailable');
      assertEquals(failure.message, 'The reader is busy right now. Try again in a moment.');
      assertEquals(failure.detail, { status });
    }
  }
});

Deno.test('a request the API would not accept keeps the provider words', async () => {
  const { fetch } = stubFetch(
    new Response(
      JSON.stringify({ error: { message: 'Unknown name "responseJsonSchema"' } }),
      { status: 400 },
    ),
  );

  try {
    await postGemini(CALL, 'k', fetch);
    throw new Error('expected a failure');
  } catch (error) {
    const failure = error as { message: string };
    assertStringIncludes(failure.message, '400');
    assertStringIncludes(failure.message, 'responseJsonSchema');
  }
});

Deno.test('a body that is not JSON is not mistaken for success', async () => {
  const { fetch } = stubFetch(new Response('<html>gateway</html>', { status: 502 }));

  try {
    await postGemini(CALL, 'k', fetch);
    throw new Error('expected a failure');
  } catch (error) {
    assertEquals((error as { code?: string }).code, 'provider_unavailable');
  }
});

Deno.test('a 200 with an empty body is null rather than a parse crash', async () => {
  const { fetch } = stubFetch(new Response('', { status: 200 }));

  assertEquals(await postGemini(CALL, 'k', fetch), null);
});

Deno.test('the fallback message names the status when the provider said nothing', () => {
  assertEquals(providerMessage(500, null), 'The reader could not process that request (500).');
  assertStringIncludes(providerMessage(502, { error: { message: 'bad gateway' } }), 'bad gateway');
});
