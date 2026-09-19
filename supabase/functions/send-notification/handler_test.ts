/**
 * Tests for the dispatch handler, with every dependency stubbed.
 *
 * Nothing here touches a network, a database or a secret, which is the only way
 * this function can be tested at all: there is no WhatsApp account and no SendGrid
 * key in this project (D-046). What the stubs let the tests prove is the part the
 * credential would not change anyway - the request contract, the order of the
 * three steps, and what each outcome settles to:
 *
 *   - **queue -> call -> settle, every time.** Nothing is attempted before it is
 *     recorded, and nothing is left `queued` without a settle;
 *   - **a missing secret is `skipped`, not a failure**, naming the secret, with the
 *     log row still written - the one shape an unconfigured deploy will meet;
 *   - **the tenant never travels.** No pharmacy rides in the request or in the
 *     payload the queue RPC receives (D-004/D-026).
 *
 * Run: `deno test supabase/functions/send-notification/handler_test.ts`
 */

import { assertEquals, assertStrictEquals, assertStringIncludes } from 'jsr:@std/assert';
import { FunctionError } from '../_shared/errors.ts';
import {
  DISPATCH_CHANNELS,
  createHandler,
  PROVIDERS,
  queuePayload,
  RECIPIENT_TYPES,
  validateDispatch,
  type DispatchPayload,
  type HandlerDeps,
  type QueueResult,
  type SettleOutcome,
} from './handler.ts';
import type { DispatchReply } from './providers.ts';

const PHARMACY = '11111111-1111-1111-1111-111111111111';
const USER = '22222222-2222-2222-2222-222222222222';
const CUSTOMER = '33333333-3333-3333-3333-333333333333';

const QUEUED: QueueResult = { logId: 'log-1', notificationId: 'notif-1' };
const ACCEPTED: DispatchReply = {
  ok: true,
  status: 200,
  messageId: 'wamid.1',
  message: 'WhatsApp accepted the message.',
};
const REFUSED: DispatchReply = {
  ok: false,
  status: 400,
  messageId: null,
  message: 'WhatsApp refused the message (400): the number is not on WhatsApp',
};

/** What a stubbed handler was asked to do, in the order it was asked. */
interface Calls {
  pharmacyChecks: number;
  queuePayloads: Record<string, unknown>[];
  whatsapp: { to: string; body: string }[];
  emails: { to: string; subject: string | null; body: string }[];
  settles: { logId: string; outcome: SettleOutcome }[];
  events: string[];
}

/** Deps with only the behaviour a test cares about replaced. */
function stubDeps(overrides: Partial<HandlerDeps> = {}): {
  deps: HandlerDeps;
  calls: Calls;
} {
  const calls: Calls = {
    pharmacyChecks: 0,
    queuePayloads: [],
    whatsapp: [],
    emails: [],
    settles: [],
    events: [],
  };

  const deps: HandlerDeps = {
    getPharmacyId: () => {
      calls.pharmacyChecks += 1;
      return Promise.resolve(PHARMACY);
    },
    queue: (_request, payload) => {
      calls.events.push('queue');
      calls.queuePayloads.push(payload);
      return Promise.resolve(QUEUED);
    },
    whatsapp: (_request, to, body) => {
      calls.events.push('call');
      calls.whatsapp.push({ to, body });
      return Promise.resolve(ACCEPTED);
    },
    email: (_request, to, subject, body) => {
      calls.events.push('call');
      calls.emails.push({ to, subject, body });
      return Promise.resolve(ACCEPTED);
    },
    settle: (_request, logId, outcome) => {
      calls.events.push('settle');
      calls.settles.push({ logId, outcome });
      return Promise.resolve();
    },
    ...overrides,
  };

  return { deps, calls };
}

/** A POST whose body is [body]. */
function post(body: unknown): Request {
  return new Request('https://example.test/send-notification', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/** The parsed body of a response, for asserting on the envelope. */
async function bodyOf(response: Response): Promise<Record<string, any>> {
  return await response.json() as Record<string, any>;
}

/** A request that should succeed, overridden field by field. */
function send(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    channel: 'whatsapp',
    to: '+910000000000',
    body: 'Your order is ready.',
    recipient_type: 'customer',
    ...overrides,
  };
}

Deno.test('a preflight is answered so a browser can call this at all', async () => {
  const { deps } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/send-notification', { method: 'OPTIONS' }),
  );

  assertEquals(response.status, 204);
  assertEquals(response.headers.get('access-control-allow-origin'), '*');
});

Deno.test('only POST is served, and a GET writes nothing', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/send-notification', { method: 'GET' }),
  );

  assertEquals(response.status, 400);
  assertEquals((await bodyOf(response)).error.code, 'invalid_request');
  assertEquals(calls.events, []);
});

Deno.test('a body that is not JSON is refused before anything is written', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    new Request('https://example.test/send-notification', {
      method: 'POST',
      body: 'please send this',
    }),
  );

  assertStringIncludes((await bodyOf(response)).error.message, 'JSON');
  assertEquals(calls.events, []);
  assertEquals(calls.pharmacyChecks, 0);
});

Deno.test('a channel that is not whatsapp or email is refused, and nothing is queued', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post(send({ channel: 'sms' })));

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'whatsapp or email');
  assertEquals(calls.events, []);
});

Deno.test('push is not a channel here, because Phase 5 has no push (D-029)', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post(send({ channel: 'push' })));

  assertEquals(response.status, 400);
  assertEquals(calls.events, []);
});

Deno.test('a recipient_type outside the enum is refused', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post(send({ recipient_type: 'colleague' })),
  );

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'recipient_type');
  assertEquals(calls.events, []);
});

Deno.test('a missing destination names the channel it was missing for', async () => {
  const { deps } = stubDeps();
  const email = await createHandler(deps)(post(send({ channel: 'email', to: null })));

  assertEquals(email.status, 400);
  assertStringIncludes((await bodyOf(email)).error.message, 'an email address');

  const whatsapp = await createHandler(deps)(post(send({ to: '   ' })));
  assertStringIncludes((await bodyOf(whatsapp)).error.message, 'a phone number');
});

Deno.test('an empty or whitespace-only body is refused', async () => {
  const { deps, calls } = stubDeps();

  for (const body of ['', '   ', '\n\t']) {
    const response = await createHandler(deps)(post(send({ body })));
    assertEquals(response.status, 400);
    assertStringIncludes((await bodyOf(response)).error.message, 'body');
  }

  assertEquals(calls.events, []);
});

Deno.test('a message past Meta\'s text limit is refused as too large', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post(send({ body: 'x'.repeat(4097) })));

  assertEquals(response.status, 413);
  assertEquals((await bodyOf(response)).error.code, 'too_large');
  assertEquals(calls.events, []);
});

Deno.test('a notify_user_id that is not a uuid is refused rather than dropped', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post(send({ notify_user_id: 'the owner' })),
  );

  assertEquals(response.status, 400);
  assertStringIncludes((await bodyOf(response)).error.message, 'notify_user_id');
  assertEquals(calls.events, []);
});

Deno.test('the body is kept verbatim: an edge newline is part of the message', async () => {
  const { deps, calls } = stubDeps();
  await createHandler(deps)(post(send({ body: 'line one\nline two\n' })));

  assertStrictEquals(calls.whatsapp[0].body, 'line one\nline two\n');
});

Deno.test('a whatsapp message is queued, called and settled, in that order', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 200);
  assertEquals(calls.events, ['queue', 'call', 'settle']);
  assertEquals(calls.queuePayloads.length, 1);
  assertEquals(calls.whatsapp, [{ to: '+910000000000', body: 'Your order is ready.' }]);
  assertEquals(calls.emails, []);

  const body = await bodyOf(response);
  assertEquals(body.log_id, 'log-1');
  assertEquals(body.notification_id, 'notif-1');
  assertEquals(body.status, 'sent');
  assertEquals(body.provider, 'whatsapp_cloud');
  assertEquals(body.error, null);

  assertEquals(calls.settles.length, 1);
  assertEquals(calls.settles[0].logId, 'log-1');
  assertEquals(calls.settles[0].outcome, {
    status: 'sent',
    provider: 'whatsapp_cloud',
    providerMessageId: 'wamid.1',
    error: null,
  });
});

Deno.test('an email carries the subject and reaches SendGrid instead', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post(
      send({
        channel: 'email',
        to: 'customer@example.test',
        subject: '  Your bill  ',
        notify_user_id: USER,
        type: 'bill',
        title: 'Bill from My Pharmacy',
      }),
    ),
  );

  assertEquals(response.status, 200);
  assertEquals(calls.whatsapp, []);
  assertEquals(calls.emails, [
    {
      to: 'customer@example.test',
      subject: 'Your bill',
      body: 'Your order is ready.',
    },
  ]);
  assertEquals((await bodyOf(response)).provider, 'sendgrid');

  // The in-app row's own fields travel to the RPC, and the request's `to` arrives
  // as the function's `destination`.
  const payload = calls.queuePayloads[0];
  assertEquals(payload.channel, 'email');
  assertEquals(payload.destination, 'customer@example.test');
  assertEquals(payload.notify_user_id, USER);
  assertEquals(payload.type, 'bill');
  assertEquals(payload.title, 'Bill from My Pharmacy');
  assertEquals(payload.body, 'Your order is ready.');
});

Deno.test('the tenant never travels: not in the payload, and not from the request', async () => {
  const { deps, calls } = stubDeps();
  const response = await createHandler(deps)(
    post(send({ pharmacy_id: '44444444-4444-4444-4444-444444444444' })),
  );

  assertEquals(response.status, 200);
  assertEquals(calls.pharmacyChecks, 1);

  const payload = JSON.stringify(calls.queuePayloads[0]);
  assertEquals(payload.includes('pharmacy'), false);
  assertEquals(payload.includes('44444444'), false);
  assertEquals(payload.includes(PHARMACY), false);
});

Deno.test('an unlinked account is refused before anything is written', async () => {
  const { deps, calls } = stubDeps({
    getPharmacyId: () =>
      Promise.reject(
        new FunctionError('unauthorized', 'This account is not linked to a pharmacy yet.'),
      ),
  });
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 401);
  assertEquals((await bodyOf(response)).error.code, 'unauthorized');
  assertEquals(calls.events, []);
});

Deno.test('a provider that refuses is settled as failed, in the provider\'s own words', async () => {
  const { deps, calls } = stubDeps({
    whatsapp: () => Promise.resolve(REFUSED),
  });
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.status, 'failed');
  assertEquals(body.provider, 'whatsapp_cloud');
  assertStringIncludes(body.error, 'not on WhatsApp');
  assertEquals(calls.settles[0].outcome.status, 'failed');
  assertEquals(calls.settles[0].outcome.providerMessageId, null);
});

Deno.test('a provider that cannot be reached is settled as failed, with the reason', async () => {
  const { deps, calls } = stubDeps({
    whatsapp: () =>
      Promise.resolve({
        ok: false,
        status: 0,
        messageId: null,
        message: 'The provider could not be reached (connection refused).',
      }),
  });
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.status, 'failed');
  assertStringIncludes(body.error, 'could not be reached');
  assertEquals(calls.settles.length, 1);
});

Deno.test('a missing secret is skipped, names the secret, and still leaves a log row', async () => {
  const { deps, calls } = stubDeps({
    whatsapp: () => {
      calls.events.push('call');
      return Promise.reject(
        new FunctionError(
          'not_configured',
          'This function is missing its WHATSAPP_TOKEN secret.',
        ),
      );
    },
  });
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.status, 'skipped');
  // Nothing was reached, so nobody is recorded as having handled it.
  assertEquals(body.provider, null);
  assertStringIncludes(body.error, 'WHATSAPP_TOKEN');
  assertEquals(body.log_id, 'log-1');

  // The row was written *before* the secret was read: that is the whole point.
  assertEquals(calls.events, ['queue', 'call', 'settle']);
  assertEquals(calls.queuePayloads.length, 1);
  assertEquals(calls.settles[0].outcome, {
    status: 'skipped',
    provider: null,
    providerMessageId: null,
    error: 'This function is missing its WHATSAPP_TOKEN secret.',
  });
});

Deno.test('an unexpected throw inside the provider path is a failure, not a skip', async () => {
  const { deps, calls } = stubDeps({
    email: () => Promise.reject(new TypeError('cannot read properties of undefined')),
  });
  const response = await createHandler(deps)(post(send({ channel: 'email' })));

  assertEquals(response.status, 200);
  const body = await bodyOf(response);
  assertEquals(body.status, 'failed');
  assertEquals(body.provider, 'sendgrid');
  assertStringIncludes(body.error, 'could not be reached');
  assertEquals(calls.settles.length, 1);
});

Deno.test('a refusal from the queue RPC reaches the caller with its own sentence', async () => {
  const { deps, calls } = stubDeps({
    queue: () =>
      Promise.reject(
        new FunctionError(
          'invalid_request',
          'That user is not in this pharmacy, so the notification would not reach them.',
        ),
      ),
  });
  const response = await createHandler(deps)(
    post(send({ notify_user_id: USER })),
  );

  assertEquals(response.status, 400);
  const body = await bodyOf(response);
  assertEquals(body.error.code, 'invalid_request');
  assertStringIncludes(body.error.message, 'not in this pharmacy');
  // Nothing was attempted, and there is nothing to settle.
  assertEquals(calls.whatsapp, []);
  assertEquals(calls.settles, []);
});

Deno.test('a settle that fails is a 500, and the attempt stays queued behind it', async () => {
  const { deps, calls } = stubDeps({
    settle: () => {
      calls.events.push('settle');
      return Promise.reject(
        new FunctionError(
          'internal',
          'The message was attempted but its outcome could not be recorded: nope',
        ),
      );
    },
  });
  const response = await createHandler(deps)(post(send()));

  assertEquals(response.status, 500);
  const body = await bodyOf(response);
  assertEquals(body.error.code, 'internal');
  assertStringIncludes(body.error.message, 'could not be recorded');
  // The provider *was* called: the caller genuinely does not know whether it went,
  // which is why this is the one non-200 answer that follows a queued attempt.
  assertEquals(calls.events, ['queue', 'call', 'settle']);
});

Deno.test('a request with no notify_user_id is settled with a null notification', async () => {
  const { deps } = stubDeps({
    queue: () => Promise.resolve({ logId: 'log-2', notificationId: null }),
  });
  const response = await createHandler(deps)(post(send()));

  const body = await bodyOf(response);
  assertStrictEquals(body.notification_id, null);
  assertEquals(body.log_id, 'log-2');
});

Deno.test('one request makes exactly one attempt', async () => {
  const { deps, calls } = stubDeps();
  await createHandler(deps)(post(send()));

  assertEquals(calls.queuePayloads.length, 1);
  assertEquals(calls.settles.length, 1);
  assertEquals(calls.whatsapp.length + calls.emails.length, 1);
});

Deno.test('the validator is the contract: a well-formed request round-trips', () => {
  const payload: DispatchPayload = validateDispatch({
    channel: 'whatsapp',
    to: '+910000000000',
    body: 'Your order is ready.',
    recipient_type: 'customer',
    recipient_id: CUSTOMER,
  });

  assertEquals(payload.channel, 'whatsapp');
  assertEquals(payload.recipientId, CUSTOMER);
  assertStrictEquals(payload.subject, null);
  assertStrictEquals(payload.notifyUserId, null);
  assertStrictEquals(payload.type, null);
  assertStrictEquals(payload.title, null);

  const raw = queuePayload(payload);
  assertEquals(raw.destination, '+910000000000');
  assertEquals(raw.recipient_id, CUSTOMER);
  assertEquals(Object.keys(raw).sort(), [
    'body',
    'channel',
    'destination',
    'notify_user_id',
    'recipient_id',
    'recipient_type',
    'subject',
    'title',
    'type',
  ]);
});

Deno.test('the closed sets and the provider names are the ones the log will record', () => {
  assertEquals(DISPATCH_CHANNELS, ['whatsapp', 'email']);
  assertEquals(RECIPIENT_TYPES, ['customer', 'supplier', 'user', 'other']);
  assertEquals(PROVIDERS, { whatsapp: 'whatsapp_cloud', email: 'sendgrid' });
});
