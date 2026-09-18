/**
 * Base64, encoded here rather than asked of the runtime.
 *
 * `Uint8Array#toBase64` is a TC39 proposal rather than part of the language
 * core, so whether it exists depends on which JavaScript engine a deployment
 * happens to run — and an Edge Function's runtime is not ours to pin. A missing
 * method there is not a type error, a lint or a failing test locally: it is a
 * `TypeError` inside a request, months after the code was written and far from
 * the line that caused it. Twelve lines of arithmetic that work in every engine
 * are cheaper than that, and Chunk D's function (which attaches a PDF to a
 * message) wants the same helper.
 */

const ALPHABET =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** How much output to build before joining a chunk. Keeps this linear. */
const CHUNK = 8192;

/**
 * [bytes] as a base64 string.
 *
 * Standard alphabet, `=` padding, no line breaks — what an API expecting base64
 * in JSON wants.
 */
export function encodeBase64(bytes: Uint8Array): string {
  const chunks: string[] = [];
  let out = '';

  for (let i = 0; i < bytes.length; i += 3) {
    const first = bytes[i];
    const hasSecond = i + 1 < bytes.length;
    const hasThird = i + 2 < bytes.length;
    const second = hasSecond ? bytes[i + 1] : 0;
    const third = hasThird ? bytes[i + 2] : 0;

    out += ALPHABET[first >> 2];
    out += ALPHABET[((first & 0x03) << 4) | (second >> 4)];
    out += hasSecond ? ALPHABET[((second & 0x0f) << 2) | (third >> 6)] : '=';
    out += hasThird ? ALPHABET[third & 0x3f] : '=';

    if (out.length >= CHUNK) {
      chunks.push(out);
      out = '';
    }
  }

  chunks.push(out);
  return chunks.join('');
}
