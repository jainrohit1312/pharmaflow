/**
 * The bill reader's request path.
 *
 * Every effect this function has — reading the caller's tenant, downloading the
 * bill, calling the model — arrives through `HandlerDeps` rather than being
 * reached for directly, so the whole path can be exercised by a test with
 * stubs, on a machine with no Docker and no API key (`handler_test.ts`). What
 * is left untested here is the wiring in `deps.ts` and the three lines in
 * `index.ts`, and those are covered by a real invocation of the deployed
 * function.
 *
 * The order of the checks is the security-relevant part, and it is deliberate:
 * the tenant is derived from the caller's own identity *before* the bill is
 * looked for, and the path's tenant segment is compared with it *before* the
 * object is downloaded. So a bill outside the caller's pharmacy is refused as
 * "not yours" rather than surfacing as a storage miss — which is both the
 * honest message and the one that does not tell a stranger whether a path
 * exists.
 */

import { encodeBase64 } from '../_shared/base64.ts';
import { FunctionError, isFunctionError } from '../_shared/errors.ts';
import { failJson, okJson, preflight } from '../_shared/response.ts';
import {
  buildGenerateContentBody,
  extractPayloadText,
  finishReasonOf,
  generateContentUrl,
  mimeForPath,
  normalizeInvoice,
  parsePayloadJson,
} from './gemini.ts';

/**
 * The largest bill this function will send to the model.
 *
 * Mirrors the bucket's own cap (10 MB, migration 00022) because the bytes are
 * base64-encoded before they travel, which inflates them by a third — and a
 * request the model's API refuses for size is a slow, confusing failure. The
 * bucket remains the authority; this is a second gate with a clearer message.
 */
export const MAX_BILL_BYTES = 10 * 1024 * 1024;

/** A bill path, once it is known to be well formed. */
export interface BillPath {
  /** The object's path inside the bucket: `<pharmacy_id>/<year>/<file>`. */
  path: string;
  /** The tenant the path claims to belong to. Verified against the caller. */
  pharmacyId: string;
}

/** A downloaded bill. */
export interface DownloadedBill {
  bytes: Uint8Array;
  /** The object's content type, or the path's extension when storage is quiet. */
  mimeType: string;
}

/** One call to the model. */
export interface GeminiCall {
  /** The `generateContent` endpoint, with the API key kept out of the URL. */
  url: string;
  /** The `generateContent` request body to POST. */
  request: unknown;
}

/** Everything the handler needs from the outside world. */
export interface HandlerDeps {
  /** The vision model to ask. */
  model: string;
  /** The pharmacy the caller belongs to. */
  getPharmacyId(request: Request): Promise<string>;
  /** The bill's bytes, read with the caller's own credentials. */
  downloadBill(request: Request, path: string): Promise<DownloadedBill>;
  /** The model's reply, as parsed JSON. */
  callGemini(call: GeminiCall): Promise<unknown>;
}

/**
 * Checks the request body's `path`.
 *
 * The shape asserted here is the one D-028 stores: a tenant uuid, a year, and a
 * file whose extension is one the bucket accepts. An unsupported extension is
 * refused now, with a message about the file, rather than after a round trip to
 * storage that fails for a reason the user cannot see.
 */
export function validateBillPath(raw: unknown): BillPath {
  if (typeof raw !== 'string' || raw.trim().length === 0) {
    throw new FunctionError(
      'invalid_request',
      'Send the path of the bill that was uploaded.',
    );
  }

  const path = raw.trim().replace(/^\/+/, '');
  const segments = path.split('/');

  if (segments.length < 3) {
    throw new FunctionError(
      'invalid_request',
      'A bill path is <pharmacy>/<year>/<file>.',
    );
  }

  const pharmacyId = segments[0];
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      pharmacyId,
    )
  ) {
    throw new FunctionError(
      'invalid_request',
      'A bill path starts with the pharmacy it belongs to.',
    );
  }

  if (mimeForPath(path) === null) {
    throw new FunctionError(
      'invalid_request',
      'That file type cannot be read. Upload a JPEG, PNG, WebP or PDF bill.',
    );
  }

  return { path, pharmacyId };
}

/** The handler `index.ts` serves, with [deps] supplying the real world. */
export function createHandler(
  deps: HandlerDeps,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') {
      return preflight();
    }

    try {
      if (request.method !== 'POST') {
        throw new FunctionError(
          'invalid_request',
          'This endpoint accepts POST.',
        );
      }

      const body = await readJsonBody(request);
      const bill = validateBillPath((body as Record<string, unknown>).path);

      const pharmacyId = await deps.getPharmacyId(request);
      if (bill.pharmacyId !== pharmacyId) {
        throw new FunctionError(
          'forbidden',
          'That bill belongs to another pharmacy.',
        );
      }

      const downloaded = await deps.downloadBill(request, bill.path);
      if (downloaded.bytes.byteLength === 0) {
        throw new FunctionError(
          'not_found',
          'That bill is empty or could not be read.',
        );
      }
      if (downloaded.bytes.byteLength > MAX_BILL_BYTES) {
        throw new FunctionError(
          'too_large',
          'That bill is larger than 10 MB. Photograph it at a smaller size.',
        );
      }

      const reply = await deps.callGemini({
        url: generateContentUrl(deps.model),
        request: buildGenerateContentBody({
          model: deps.model,
          mimeType: mimeForPath(bill.path) ?? downloaded.mimeType,
          base64: encodeBase64(downloaded.bytes),
        }),
      });

      const payload = extractPayloadText(reply);
      const finishReason = finishReasonOf(reply);
      const invoice = normalizeInvoice(parsePayloadJson(payload), deps.model);

      const warnings = [...invoice.meta.warnings];
      if (finishReason !== null && finishReason !== 'STOP') {
        warnings.push(
          `The reader stopped early (${finishReason}), so the bill may have more lines than were read.`,
        );
      }

      return okJson({
        document: invoice.document,
        lines: invoice.lines,
        meta: {
          model: invoice.meta.model,
          warnings,
          image_path: bill.path,
          finish_reason: finishReason,
        },
      });
    } catch (error) {
      if (isFunctionError(error)) {
        console.error(
          `ocr-purchase-bill refused: ${error.code} - ${error.message}`,
        );
        return failJson(error);
      }

      // An unexpected throw is a bug in this function, not a situation the
      // caller can act on: the logs get the detail, the caller gets a sentence.
      console.error('ocr-purchase-bill failed unexpectedly', error);
      return failJson(error);
    }
  };
}

/** The request body, or a `invalid_request` failure. */
async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new FunctionError(
      'invalid_request',
      'Send the bill path as a JSON body.',
    );
  }
}
