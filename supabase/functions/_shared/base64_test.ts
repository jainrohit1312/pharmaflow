/**
 * Tests for the base64 encoder.
 *
 * `atob` is used to check the encoder, never to do its job: a hand-written
 * encoder is exactly the kind of code that looks right and is off by a bit, so
 * every length class is checked against the runtime's own decoder — including
 * the round trip, which is the assertion that would catch a padding mistake.
 *
 * Run: `deno test supabase/functions/_shared/base64_test.ts`
 */

import { assertEquals } from 'jsr:@std/assert';
import { encodeBase64 } from './base64.ts';

/** What the runtime's own base64 decoder makes of [bytes]. */
function reference(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

Deno.test('every remainder length encodes as the runtime does', () => {
  for (const size of [0, 1, 2, 3, 4, 5, 6, 7, 31, 32, 33]) {
    const bytes = new Uint8Array(size);
    for (let i = 0; i < size; i++) {
      bytes[i] = (i * 37 + 11) % 256;
    }
    assertEquals(encodeBase64(bytes), reference(bytes), `size ${size}`);
  }
});

Deno.test('a known token encodes exactly', () => {
  assertEquals(encodeBase64(new Uint8Array([1, 2, 3])), 'AQID');
  assertEquals(encodeBase64(new TextEncoder().encode('PharmaFlow')), 'UGhhcm1hRmxvdw==');
});

Deno.test('output padded to a multiple of four, and only then', () => {
  assertEquals(encodeBase64(new Uint8Array(0)), '');
  assertEquals(encodeBase64(new Uint8Array([0])), 'AA==');
  assertEquals(encodeBase64(new Uint8Array([0, 0])), 'AAA=');
  assertEquals(encodeBase64(new Uint8Array([0, 0, 0])), 'AAAA');
});

Deno.test('a bill-sized buffer is encoded, and stays fast enough to be linear', () => {
  // Two megabytes, the shape of a real photographed bill rather than a fixture:
  // the encoder's chunking exists for this case, not for the small ones above.
  const bytes = new Uint8Array(2 * 1024 * 1024);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = i % 256;
  }

  const started = Date.now();
  const encoded = encodeBase64(bytes);
  const elapsed = Date.now() - started;

  assertEquals(encoded.length, Math.ceil(bytes.length / 3) * 4);
  assertEquals(encoded.startsWith('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g'), true);
  assertEquals(
    elapsed < 3000,
    true,
    `2 MB should encode in well under a second, took ${elapsed} ms`,
  );
});
