/**
 * Tests for the two dispatch providers, with a stub `fetch`.
 *
 * There is no WhatsApp account and no SendGrid key in this project (D-046), so
 * these are the only way any of this code runs at all. They assert the two things
 * a real credential would not change - the request that goes out, and the sentence
 * that comes back - and one thing that matters more than either: the token travels
 * in an `Authorization` header and never in a URL, which is where a provider's own
 * request log would otherwise keep it (the shape `_shared/gemini.ts` established).
 *
 * Run: `deno test supabase/functions/send-notification/providers_test.ts`
 */

import { assertEquals, assertStrictEquals, assertStringIncludes } from 'jsr:@std/assert';
import {
  postSendGrid,
  postWhatsApp,
  sendgridMail,
  whatsappMessage,
  type DispatchFetch,
} from './providers.ts';

/** A provider's answer, as JSON. */
function respond(
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}

/** A fetch that answers [reply] and records what it was asked to send. */
function stubFetch(reply: () => Response | Promise<Response>): {
  fetch: DispatchFetch;
  sent: { url: string; init: RequestInit }[];
} {
  const sent: { url: string; init: RequestInit }[] = [];
  const fetchImpl: DispatchFetch = (url, init) => {
    sent.push({ url, init });
    return Promise.resolve(reply());
  };
  return { fetch: fetchImpl, sent };
}

/** The headers a stub fetch was given, as a plain record. */
function headersOf(init: RequestInit): Record<string, string> {
  return (init.headers ?? {}) as Record<string, string>;
}

Deno.test('a WhatsApp message names the sender in the URL and the text in the body', () => {
  const request = whatsappMessage({
    version: 'v22.0',
    phoneNumberId: '1234567890',
    to: '+910000000000',
    body: 'Your order is ready.',
  });

  assertEquals(request.url, 'https://graph.facebook.com/v22.0/1234567890/messages');
  assertEquals(request.body, {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to: '+910000000000',
    type: 'text',
    text: { body: 'Your order is ready.' },
  });
});

Deno.test('an email names the sender in the body, and an absent subject is empty rather than null', () => {
  const request = sendgridMail({
    from: 'pharmacy@example.test',
    to: 'customer@example.test',
    subject: null,
    body: 'Your order is ready.',
  });

  assertEquals(request.url, 'https://api.sendgrid.com/v3/mail/send');
  assertEquals(request.body, {
    personalizations: [{ to: [{ email: 'customer@example.test' }] }],
    from: { email: 'pharmacy@example.test' },
    subject: '',
    content: [{ type: 'text/plain', value: 'Your order is ready.' }],
  });
});

Deno.test('the WhatsApp token travels in a header and never in the URL', async () => {
  const { fetch, sent } = stubFetch(() =>
    respond(200, { messages: [{ id: 'wamid.1' }] })
  );

  await postWhatsApp(
    whatsappMessage({
      version: 'v22.0',
      phoneNumberId: '1234567890',
      to: '+910000000000',
      body: 'hi',
    }),
    'SECRET-TOKEN',
    fetch,
  );

  assertEquals(sent.length, 1);
  assertEquals(headersOf(sent[0].init).authorization, 'Bearer SECRET-TOKEN');
  assertEquals(sent[0].url.includes('SECRET-TOKEN'), false);
  assertEquals(sent[0].init.method, 'POST');
  // The body is the request's own, serialised - not a string of the object.
  assertEquals(JSON.parse(String(sent[0].init.body)).text.body, 'hi');
});

Deno.test('an accepted WhatsApp message reports the id the API gave it', async () => {
  const { fetch } = stubFetch(() => respond(200, { messages: [{ id: 'wamid.1' }] }));
  const reply = await postWhatsApp(
    whatsappMessage({ version: 'v22.0', phoneNumberId: '1', to: '+91', body: 'hi' }),
    'token',
    fetch,
  );

  assertEquals(reply.ok, true);
  assertEquals(reply.status, 200);
  assertEquals(reply.messageId, 'wamid.1');
});

Deno.test('a 200 with no message id is still an acceptance', async () => {
  const { fetch } = stubFetch(() => respond(200, { messaging_product: 'whatsapp' }));
  const reply = await postWhatsApp(
    whatsappMessage({ version: 'v22.0', phoneNumberId: '1', to: '+91', body: 'hi' }),
    'token',
    fetch,
  );

  assertEquals(reply.ok, true);
  assertStrictEquals(reply.messageId, null);
});

Deno.test('WhatsApp\'s own refusal sentence reaches the caller', async () => {
  const { fetch } = stubFetch(() =>
    respond(400, {
      error: { message: 'The number is not on WhatsApp', code: 131026 },
    })
  );
  const reply = await postWhatsApp(
    whatsappMessage({ version: 'v22.0', phoneNumberId: '1', to: '+91', body: 'hi' }),
    'token',
    fetch,
  );

  assertEquals(reply.ok, false);
  assertEquals(reply.status, 400);
  assertStrictEquals(reply.messageId, null);
  assertStringIncludes(reply.message, 'not on WhatsApp');
  assertStringIncludes(reply.message, '400');
});

Deno.test('SendGrid\'s own refusal sentence reaches the caller', async () => {
  const { fetch } = stubFetch(() =>
    respond(401, {
      errors: [{ message: 'The from address does not match a verified Sender Identity', field: 'from' }],
    })
  );
  const reply = await postSendGrid(
    sendgridMail({ from: 'a@b.test', to: 'c@d.test', subject: 's', body: 'b' }),
    'key',
    fetch,
  );

  assertEquals(reply.ok, false);
  assertEquals(reply.status, 401);
  assertStringIncludes(reply.message, 'verified Sender Identity');
});

Deno.test('a rate limit is one sentence, because it means the same thing on both', async () => {
  const { fetch } = stubFetch(() => respond(429, {}));
  const reply = await postWhatsApp(
    whatsappMessage({ version: 'v22.0', phoneNumberId: '1', to: '+91', body: 'hi' }),
    'token',
    fetch,
  );

  assertEquals(reply.ok, false);
  assertStringIncludes(reply.message, 'rate-limiting');
  assertStringIncludes(reply.message, 'Try again');
});

Deno.test('a refusal with nothing readable in it is still a sentence', async () => {
  const { fetch } = stubFetch(
    () => new Response('<html>gateway</html>', { status: 502 }),
  );
  const reply = await postSendGrid(
    sendgridMail({ from: 'a@b.test', to: 'c@d.test', subject: 's', body: 'b' }),
    'key',
    fetch,
  );

  assertEquals(reply.ok, false);
  assertEquals(reply.status, 502);
  assertEquals(reply.message, 'SendGrid refused the message (502).');
});

Deno.test('a provider that cannot be reached is a result, not an exception', async () => {
  const { fetch } = stubFetch(() => {
    throw new TypeError('fetch failed');
  });
  const reply = await postWhatsApp(
    whatsappMessage({ version: 'v22.0', phoneNumberId: '1', to: '+91', body: 'hi' }),
    'token',
    fetch,
  );

  assertEquals(reply.ok, false);
  assertEquals(reply.status, 0);
  assertStrictEquals(reply.messageId, null);
  assertStringIncludes(reply.message, 'could not be reached');
  assertStringIncludes(reply.message, 'fetch failed');
});

Deno.test('an accepted email takes its id from the header SendGrid puts it in', async () => {
  const { fetch } = stubFetch(() =>
    new Response(null, { status: 202, headers: { 'x-message-id': 'sg-1' } })
  );
  const reply = await postSendGrid(
    sendgridMail({ from: 'a@b.test', to: 'c@d.test', subject: 's', body: 'b' }),
    'key',
    fetch,
  );

  assertEquals(reply.ok, true);
  assertEquals(reply.status, 202);
  assertEquals(reply.messageId, 'sg-1');
});

Deno.test('the SendGrid key travels in a header and never in the URL', async () => {
  const { fetch, sent } = stubFetch(() => new Response(null, { status: 202 }));

  await postSendGrid(
    sendgridMail({ from: 'a@b.test', to: 'c@d.test', subject: 's', body: 'b' }),
    'SECRET-KEY',
    fetch,
  );

  assertEquals(headersOf(sent[0].init).authorization, 'Bearer SECRET-KEY');
  assertEquals(headersOf(sent[0].init)['content-type'], 'application/json');
  assertEquals(sent[0].url.includes('SECRET-KEY'), false);
});
