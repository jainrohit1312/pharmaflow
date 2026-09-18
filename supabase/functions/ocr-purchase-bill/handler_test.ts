/**
 * Tests for the bill reader's request path, with every dependency stubbed.
 *
 * The point of these is not that the plumbing is spelled the way it is, but
 * that the *order* holds: the caller's tenant comes from the caller's identity
 * and is compared with the path before anything is read, and the size is
 * checked before the model is paid for. Two assertions exist only for that —
 * a foreign path leaves `downloads` empty, and an oversized bill leaves
 * `gemini` empty.
 *
 * Run: `deno test supabase/functions/ocr-purchase-bill/handler_test.ts`
 */

import { assertEquals, assertStringIncludes } from 'jsr:@std/assert';
import { FunctionError } from '../_shared/errors.ts';
import {
  createHandler,
  MAX_BILL_BYTES,
  type GeminiCall,
  type HandlerDeps,
} from './handler.ts';

const PHARMACY = '11111111-1111-1111-1111-111111111111';
const OTHER_PHARMACY = '22222222-2222-2222-2222-222222222222';
const BILL_PATH = `${PHARMACY}/2026/bill-1.jpg`;

const MODEL_REPLY = {
  candidates: [
    {
      content: {
        parts: [
          {
            text: JSON.stringify({
              document: { supplier_name: 'Arihant', invoice_no: 'INV-1' },
              lines: [{ raw_name: 'Dolo 650', qty: 10, rate: 100 }],
            }),
          },
        ],
      },
    },
  ],
};

/** What a stubbed handler was asked to do. */
interface Calls {
  downloads: string[];
  gemini: GeminiCall[];
}

/** Deps with only the behaviour a test cares about replaced. */
function stubDeps(overrides: Partial<HandlerDeps> = {}): {
  deps: HandlerDeps;
  calls: Calls;
} {
  const calls: Calls = { downloads: [], gemini: [] };

  const deps: HandlerDeps = {
    model: 'gemini-2.5-flash',
    getPharmacyId: () => Promise.resolve(PHARMACY),
    downloadBill: (_request, path) => {
      calls.downloads.push(path);
      return Promise.resolve({ bytes: new Uint8Array([1, 2, 3]), mimeType: 'image/jpeg' });
    },
    callGemini: (call) => {
      calls.gemini.push(call);
      return Promise.resolve(MODEL_REPLY);
    },
    ...overrides,
  };

  return { deps, calls };
}

/** A POST whose body is [body]. */
function post(body: unknown): Request {
  return new Request('https://example.test/ocr-purchase-bill', {
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
    new Request('https://example.test/ocr-purchase-bill', { method: 'OPTIONS' }),
  );

  assertEquals(response.status, 204);
  assertEquals(response.headers.get('access-control-allow-origin'), '*');
});

Deno.test('a refusal still carries the CORS headers', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(post({ path: 42 }));

  assertEquals(response.status, 400);
  assertEquals(response.headers.get('access-control-allow-origin'), '*');
});

Deno.test('only POST is served', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/ocr-purchase-bill', { method: 'GET' }),
  );

  assertEquals(response.status, 400);
  assertEquals((await bodyOf(response)).error.code, 'invalid_request');
});

Deno.test('a body that is not JSON is refused with a sentence about the body', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/ocr-purchase-bill', {
      method: 'POST',
      body: 'a bill, please',
    }),
  );

  const body = await bodyOf(response);
  assertEquals(body.error.code, 'invalid_request');
  assertStringIncludes(body.error.message, 'JSON');
});

Deno.test('a missing path is refused before anything is read', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({}));

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'path of the bill');
  assertEquals(calls.downloads, []);
});

Deno.test('a path without a tenant and a file is refused', async () => {
  const { deps } = stubDeps();
  const handler = createHandler(deps);

  assertEquals((await handler(post({ path: 'bill.jpg' }))).status, 400);
  assertEquals((await handler(post({ path: `${PHARMACY}/bill.jpg` }))).status, 400);
});

Deno.test('a path that does not start with a pharmacy uuid is refused', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({ path: 'arihant/2026/bill.jpg' }));

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'pharmacy it belongs to');
  assertEquals(calls.downloads, []);
});

Deno.test('a file type the reader cannot open is refused by name', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({ path: `${PHARMACY}/2026/bill.heic` }));

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'JPEG');
  assertEquals(calls.downloads, []);
});

Deno.test("another pharmacy's bill is refused, and not looked for", async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post({ path: `${OTHER_PHARMACY}/2026/bill.jpg` }),
  );

  assertEquals(response.status, 403);
  assertEquals((await bodyOf(response)).error.code, 'forbidden');
  assertEquals(calls.downloads, [], 'a foreign path must not reach storage');
  assertEquals(calls.gemini, [], 'a foreign path must not reach the model');
});

Deno.test('an account with no pharmacy is refused as unauthorized', async () => {
  const { deps } = stubDeps({
    getPharmacyId: () => {
      throw new FunctionError('unauthorized', 'This account is not linked to a pharmacy yet.');
    },
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 401);
  assertEquals((await bodyOf(response)).error.code, 'unauthorized');
});

Deno.test('a good bill comes back as the document, its lines and the model', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 200);

  const body = await bodyOf(response);
  assertEquals(body.document.invoice_no, 'INV-1');
  assertEquals(body.document.supplier_name, 'Arihant');
  assertEquals(body.lines.length, 1);
  assertEquals(body.lines[0].raw_name, 'Dolo 650');
  assertEquals(body.lines[0].qty, 10);
  assertEquals(body.lines[0].rate, 100);
  assertEquals(body.lines[0].batch_no, null, 'a field the model did not read stays null');
  assertEquals(body.meta.model, 'gemini-2.5-flash');
  assertEquals(body.meta.image_path, BILL_PATH);
  assertEquals(body.meta.warnings, []);

  assertEquals(calls.downloads, [BILL_PATH]);
  assertEquals(calls.gemini.length, 1);
  assertEquals(
    calls.gemini[0].url.includes('/models/gemini-2.5-flash:generateContent'),
    true,
  );

  const request = calls.gemini[0].request as Record<string, any>;
  assertEquals(request.contents[0].parts[1].inlineData.mimeType, 'image/jpeg');
  assertEquals(request.contents[0].parts[1].inlineData.data, 'AQID');
});

Deno.test('an answer cut off before the lines says so, rather than looking empty', async () => {
  const { deps } = stubDeps({
    callGemini: () =>
      Promise.resolve({
        candidates: [
          {
            finishReason: 'MAX_TOKENS',
            content: {
              parts: [
                {
                  text: JSON.stringify({
                    document: { invoice_no: 'INV-1' },
                    lines: [],
                  }),
                },
              ],
            },
          },
        ],
      }),
  });

  const body = await bodyOf(await createHandler(deps)(post({ path: BILL_PATH })));
  assertEquals(body.meta.finish_reason, 'MAX_TOKENS');
  assertEquals(
    body.meta.warnings.some((w: string) => w.includes('stopped early')),
    true,
  );
});

Deno.test('a bill that cannot be read is a not-found, whatever the reason', async () => {
  const { deps } = stubDeps({
    downloadBill: () => {
      throw new FunctionError('not_found', 'That bill could not be read.');
    },
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 404);
  assertEquals((await bodyOf(response)).error.code, 'not_found');
});

Deno.test('an empty object is a not-found rather than an empty bill', async () => {
  const { deps, calls } = stubDeps({
    downloadBill: () => Promise.resolve({ bytes: new Uint8Array(), mimeType: 'image/jpeg' }),
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 404);
  assertEquals(calls.gemini, []);
});

Deno.test('a bill too large to send is refused before the model is paid for', async () => {
  const { deps, calls } = stubDeps({
    downloadBill: () =>
      Promise.resolve({ bytes: new Uint8Array(MAX_BILL_BYTES + 1), mimeType: 'image/jpeg' }),
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 413);
  assertEquals((await bodyOf(response)).error.code, 'too_large');
  assertEquals(calls.gemini, [], 'an oversized bill must not reach the model');
});

Deno.test("the provider's refusal reaches the caller with its own words", async () => {
  const { deps } = stubDeps({
    callGemini: () => {
      throw new FunctionError('provider_unavailable', 'The bill reader is busy right now.');
    },
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 502);
  assertEquals((await bodyOf(response)).error.message, 'The bill reader is busy right now.');
});

Deno.test('a reply that is not JSON is a provider fault, not an empty bill', async () => {
  const { deps } = stubDeps({
    callGemini: () =>
      Promise.resolve({ candidates: [{ content: { parts: [{ text: 'Here is what I see:' }] } }] }),
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 502);
  assertEquals((await bodyOf(response)).error.code, 'provider_unavailable');
});

Deno.test('an unexpected failure is logged, and only described generically', async () => {
  const { deps } = stubDeps({
    downloadBill: () => {
      throw new TypeError('cannot read properties of undefined');
    },
  });
  const response = await createHandler(deps)(post({ path: BILL_PATH }));

  assertEquals(response.status, 500);
  const message = (await bodyOf(response)).error.message as string;
  assertEquals(message.includes('cannot read properties'), false);
  assertStringIncludes(message, 'went wrong');
});
