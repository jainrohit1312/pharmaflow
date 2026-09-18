/**
 * The Gemini Vision side of the bill reader: what we ask for, and what we do
 * with what comes back.
 *
 * The model's reply is **untrusted input**, not a contract. It is a different
 * system, and what it returns can be a number where a string was expected, a
 * date in the format Indian invoices actually print (DD/MM/YYYY, which
 * `DateTime.tryParse` refuses), a fractional quantity in a field the database
 * stores as an integer, or nothing at all. Everything in this file exists to
 * turn that into the one shape the app's verify screen expects, and to say
 * plainly — in `meta.warnings` — where it had to guess or gave up. A parse that
 * quietly invents a batch number is worse than one that says it could not read
 * it, because the screen shows the second one to a human.
 *
 * The reply is also the *only* place trust is asked for: every field is
 * nullable, and null means "the screen must ask", never "zero".
 */

import { FunctionError } from '../_shared/errors.ts';

/**
 * The vision model, unless a deployment overrides it.
 *
 * Recorded as a decision because a model change changes what every bill parses
 * as: switching model is a deliberate act (`GEMINI_VISION_MODEL`), not
 * something that should happen by editing a string in a function.
 *
 * This name is not guesswork. The first deployed invocation answered
 * `404 ... "models/gemini-2.5-flash is no longer available to new users.
 * Please update your code to use models/gemini-3.6-flash"` — the API naming its
 * own successor — which is how this default was chosen, and the same call is
 * what verifies any future change.
 */
export const DEFAULT_VISION_MODEL = 'gemini-3.6-flash';

/** Where the Generative Language API lives. */
export const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta';

/** The mime types the bucket accepts (migration 00022, D-028). */
const MIME_BY_EXTENSION: Record<string, string> = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'pdf': 'application/pdf',
};

/** One line the model read from the bill. Every field can be missing. */
export interface OcrBillLine {
  raw_name: string | null;
  qty: number | null;
  free_qty: number | null;
  rate: number | null;
  mrp: number | null;
  gst_percent: number | null;
  batch_no: string | null;
  expiry_date: string | null;
  hsn_code: string | null;
  confidence: number | null;
}

/** What the model read about the document itself. */
export interface OcrBillDocument {
  supplier_name: string | null;
  gstin: string | null;
  invoice_no: string | null;
  invoice_date: string | null;
  sub_total: number | null;
  tax_total: number | null;
  grand_total: number | null;
}

/** The envelope the app decodes. Mirrors `OcrPurchaseBill.fromJson` in Dart. */
export interface OcrBill {
  document: OcrBillDocument;
  lines: OcrBillLine[];
  meta: {
    model: string;
    warnings: string[];
  };
}

/**
 * The mime type for a stored bill's path, or `null` for an extension the bucket
 * does not accept.
 */
export function mimeForPath(path: string): string | null {
  const extension = path.slice(path.lastIndexOf('.') + 1).toLowerCase();
  return MIME_BY_EXTENSION[extension] ?? null;
}

/** The instruction block, sent as `systemInstruction`. */
const SYSTEM_INSTRUCTION = `You read one supplier invoice from an Indian pharmacy
and return its contents as JSON.

- Return only the JSON object you are asked for. No commentary, no markdown.
- Read the printed numbers exactly. Do not recompute, round or "correct" them.
- If a value is not present or not legible, use null. Never invent a line, a
  batch number or a date to fill a gap.
- Dates are ISO 8601 (YYYY-MM-DD). Indian invoices often print DD/MM/YYYY;
  convert carefully, and use null if the day and month cannot be told apart.
- "qty" is the billed quantity. "free_qty" is a scheme/free quantity if the bill
  shows one, otherwise null.
- "rate" is the per-unit purchase rate before tax. "mrp" is the printed MRP.
- "gst_percent" is the line's tax RATE (e.g. 5, 12, 18), never a tax amount.
- "batch_no" and "expiry_date" are per line, when the bill prints them.
- "confidence" is your own 0..1 estimate that the line was read correctly. Use a
  low value rather than a null when you are unsure.
- Read every printed row of the line-item table. A bill with three rows has three
  lines; do not summarise them into the totals or stop after the first row.`;

/** How much the model may write, thinking included. */
const MAX_OUTPUT_TOKENS = 8192;

/** The JSON shape the model is asked for, spelled out in the prompt as well as
 * in the response schema: the schema constrains the format, and the example
 * tells the model what a good answer looks like. */
const SHAPE_EXAMPLE = `{
  "document": {
    "supplier_name": "Arihant Distributors",
    "gstin": "27ABCDE1234F1Z5",
    "invoice_no": "INV-2026-0042",
    "invoice_date": "2026-09-18",
    "sub_total": 1000.00,
    "tax_total": 120.00,
    "grand_total": 1120.00
  },
  "lines": [
    {
      "raw_name": "Dolo 650 Tab 15s",
      "qty": 10,
      "free_qty": 1,
      "rate": 100.00,
      "mrp": 150.00,
      "gst_percent": 12,
      "batch_no": "D650-A21",
      "expiry_date": "2027-06-30",
      "hsn_code": "3004",
      "confidence": 0.92
    }
  ]
}`;

/** The response schema, in the dialect the Generative Language API expects. */
const RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    document: {
      type: 'OBJECT',
      properties: {
        supplier_name: { type: 'STRING', nullable: true },
        gstin: { type: 'STRING', nullable: true },
        invoice_no: { type: 'STRING', nullable: true },
        invoice_date: { type: 'STRING', nullable: true },
        sub_total: { type: 'NUMBER', nullable: true },
        tax_total: { type: 'NUMBER', nullable: true },
        grand_total: { type: 'NUMBER', nullable: true },
      },
    },
    lines: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          raw_name: { type: 'STRING', nullable: true },
          qty: { type: 'NUMBER', nullable: true },
          free_qty: { type: 'NUMBER', nullable: true },
          rate: { type: 'NUMBER', nullable: true },
          mrp: { type: 'NUMBER', nullable: true },
          gst_percent: { type: 'NUMBER', nullable: true },
          batch_no: { type: 'STRING', nullable: true },
          expiry_date: { type: 'STRING', nullable: true },
          hsn_code: { type: 'STRING', nullable: true },
          confidence: { type: 'NUMBER', nullable: true },
        },
      },
    },
  },
  required: ['document', 'lines'],
} as const;

/** What the request builder needs to know about the bill. */
export interface GeminiBillInput {
  /** The model to ask. */
  model: string;
  /** The bill's mime type. */
  mimeType: string;
  /** The bill's bytes, already base64-encoded. */
  base64: string;
}

/** The URL a bill is sent to, with the API key kept out of it. */
export function generateContentUrl(model: string): string {
  return `${GEMINI_API_BASE}/models/${model}:generateContent`;
}

/**
 * The request body for one bill.
 *
 * `temperature: 0` because this is a transcription, not a composition: the same
 * bill should read the same way twice. The key travels in the `x-goog-api-key`
 * header rather than the query string, so it stays out of URLs and therefore out
 * of the API's own request logs.
 */
export function buildGenerateContentBody(input: GeminiBillInput): unknown {
  return {
    systemInstruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
    contents: [
      {
        role: 'user',
        parts: [
          { text: `Read this bill and answer with:\n${SHAPE_EXAMPLE}` },
          { inlineData: { mimeType: input.mimeType, data: input.base64 } },
        ],
      },
    ],
    generationConfig: {
      temperature: 0,
      // Thinking is on for this model family and shares this budget with the
      // answer, so a small cap truncates a long bill's JSON half-way. A bill
      // with forty lines is still only a few kilobytes of JSON.
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      responseMimeType: 'application/json',
      responseSchema: RESPONSE_SCHEMA,
    },
  };
}

/**
 * The JSON text out of a `generateContent` response.
 *
 * Three things can go wrong before there is any JSON at all, and each gets its
 * own message: the safety filter refusing the image, the model returning no
 * content, and the model returning prose instead of the object it was asked
 * for. The third is stripped of a markdown fence first, because a fenced reply
 * is a formatting slip rather than a failure to read the bill.
 */
export function extractPayloadText(apiResponse: unknown): string {
  const body = asRecord(apiResponse);

  const feedback = asRecord(body.promptFeedback);
  const blocked = asText(feedback.blockReason);
  if (blocked !== null) {
    throw new FunctionError(
      'provider_unavailable',
      `The model refused to read that bill (${blocked}).`,
    );
  }

  const candidates = Array.isArray(body.candidates) ? body.candidates : [];
  const first = asRecord(candidates[0]);
  const content = asRecord(first.content);
  const parts = Array.isArray(content.parts) ? content.parts : [];

  const text = parts
    .map((part) => asText(asRecord(part).text) ?? '')
    .join('')
    .trim();

  if (text.length === 0) {
    const reason = asText(first.finishReason) ?? 'no content';
    throw new FunctionError(
      'provider_unavailable',
      `The model returned nothing for that bill (${reason}).`,
    );
  }

  return stripCodeFence(text);
}

/** The parsed JSON object out of the model's reply text. */
export function parsePayloadJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new FunctionError(
      'provider_unavailable',
      'The model did not answer with JSON for that bill.',
    );
  }
}

/**
 * Why the model stopped, as the API reported it.
 *
 * This is the difference between "the bill has no line items" and "the answer
 * was cut off before the line items got there" — one is a fact about the bill,
 * the other is a retry — so it travels with the envelope rather than staying in
 * a log the app cannot read.
 */
export function finishReasonOf(apiResponse: unknown): string | null {
  const candidates = asRecord(apiResponse).candidates;
  if (!Array.isArray(candidates) || candidates.length === 0) {
    return null;
  }
  return asText(asRecord(candidates[0]).finishReason);
}

/**
 * The reply, whatever shape it arrived in, as the app's envelope.
 *
 * Nothing here throws on odd content: a bill the model half-read is still worth
 * showing, with the gaps marked, because the verify screen exists precisely to
 * have a human fill them.
 */
export function normalizeInvoice(raw: unknown, model: string): OcrBill {
  const warnings: string[] = [];
  const root = asRecord(raw);

  // The schema asks for `document`; a flat reply is tolerated rather than
  // thrown away, since the fields are the same either way.
  const document = asRecord(root.document ?? root);
  const rawLines = Array.isArray(root.lines)
    ? root.lines
    : Array.isArray(root.line_items)
      ? root.line_items
      : [];

  const invoiceNo = asText(document.invoice_no);
  if (invoiceNo === null) {
    warnings.push('No invoice number was read from the bill.');
  }

  const lines: OcrBillLine[] = [];
  rawLines.forEach((entry, index) => {
    const line = normalizeLine(asRecord(entry), index + 1, warnings);
    if (line !== null) {
      lines.push(line);
    }
  });

  if (rawLines.length === 0) {
    warnings.push('No line items were read from the bill.');
  }

  return {
    document: {
      supplier_name: asText(document.supplier_name),
      gstin: asText(document.gstin),
      invoice_no: invoiceNo,
      invoice_date: asIsoDate(document.invoice_date, 'the bill date', warnings),
      sub_total: asAmount(document.sub_total),
      tax_total: asAmount(document.tax_total),
      grand_total: asAmount(document.grand_total),
    },
    lines,
    meta: { model, warnings },
  };
}

/**
 * One line, or `null` for a row that carries nothing.
 *
 * A row with no name and no numbers is noise the model invented while looking
 * at a table's border, and keeping it would put a blank line in front of the
 * user to delete.
 */
function normalizeLine(
  raw: Record<string, unknown>,
  position: number,
  warnings: string[],
): OcrBillLine | null {
  const line: OcrBillLine = {
    raw_name: asText(raw.raw_name ?? raw.name ?? raw.description),
    qty: asQuantity(raw.qty ?? raw.quantity, position, warnings),
    free_qty: asQuantity(raw.free_qty ?? raw.free, position, warnings),
    rate: asAmount(raw.rate ?? raw.purchase_rate),
    mrp: asAmount(raw.mrp),
    gst_percent: asAmount(raw.gst_percent ?? raw.gst ?? raw.tax_percent),
    batch_no: asText(raw.batch_no ?? raw.batch),
    expiry_date: asIsoDate(
      raw.expiry_date ?? raw.expiry,
      `line ${position}'s expiry`,
      warnings,
    ),
    hsn_code: asText(raw.hsn_code ?? raw.hsn),
    confidence: asConfidence(raw.confidence, position, warnings),
  };

  const hasSomething =
    line.raw_name !== null ||
    line.qty !== null ||
    line.rate !== null ||
    line.mrp !== null ||
    line.batch_no !== null;

  return hasSomething ? line : null;
}

/** A trimmed string, or `null` for anything empty or non-textual. */
function asText(value: unknown): string | null {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length === 0 ? null : trimmed;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }
  return null;
}

/**
 * A number, however the model wrote it.
 *
 * Numbers arrive as text often enough to matter: `"1,120.00"`, `"₹1120"`,
 * `"Rs. 200"` and `"12%"` are all normal in a reply that has been looking at an
 * Indian invoice. The first number-shaped token is taken and its separators
 * interpreted, which is the part worth being careful about: a comma is a
 * thousands separator in `1,25,000` and a decimal point in `1,25`.
 */
function asNumber(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value !== 'string') {
    return null;
  }

  const token = /-?\d[\d.,]*/.exec(value)?.[0];
  if (token === undefined) {
    return null;
  }

  const parsed = Number.parseFloat(interpretSeparators(token));
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * A number-shaped token with its separators resolved.
 *
 * Both separators present means the comma groups thousands (`1,25,000.50`). A
 * lone comma is a decimal point unless exactly three digits follow it, which is
 * the grouping Indian invoices use (`10,50,000`). A lone dot is always decimal.
 */
function interpretSeparators(token: string): string {
  if (!token.includes(',')) {
    return token;
  }
  if (token.includes('.')) {
    return token.replace(/,/g, '');
  }

  const afterLastComma = token.slice(token.lastIndexOf(',') + 1);
  return afterLastComma.length === 3
    ? token.replace(/,/g, '')
    : token.replace(/,/g, '.');
}

/** A money or percentage figure. */
function asAmount(value: unknown): number | null {
  return asNumber(value);
}

/**
 * A quantity as the integer the database stores.
 *
 * A bill can print a fractional quantity (a 2.5 ml bottle), and the schema's
 * `qty` is an integer, so the line is rounded rather than dropped — and the
 * user is told, because a rounded quantity is a number they should check.
 */
function asQuantity(
  value: unknown,
  position: number,
  warnings: string[],
): number | null {
  const parsed = asNumber(value);
  if (parsed === null) {
    return null;
  }
  const rounded = Math.round(parsed);
  if (Math.abs(parsed - rounded) > 1e-9) {
    warnings.push(
      `Line ${position}: quantity ${parsed} was rounded to ${rounded}.`,
    );
  }
  return rounded;
}

/**
 * A date as `YYYY-MM-DD`.
 *
 * Indian invoices print `DD/MM/YYYY`, which the app's `DateTime.tryParse`
 * refuses and which a US-defaulting parser would silently read as the wrong day
 * of the month. Day-first is therefore assumed and *said out loud* in the
 * warnings, so the user knows which convention was applied to their bill.
 */
function asIsoDate(
  value: unknown,
  label: string,
  warnings: string[],
): string | null {
  const raw = asText(value);
  if (raw === null) {
    return null;
  }

  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(raw);
  if (iso) {
    return `${iso[1]}-${iso[2].padStart(2, '0')}-${iso[3].padStart(2, '0')}`;
  }

  const yearFirst = /^(\d{4})[/.](\d{1,2})[/.](\d{1,2})$/.exec(raw);
  if (yearFirst) {
    return `${yearFirst[1]}-${yearFirst[2].padStart(2, '0')}-${yearFirst[3].padStart(2, '0')}`;
  }

  const dayFirst = /^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$/.exec(raw);
  if (dayFirst) {
    const day = dayFirst[1].padStart(2, '0');
    const month = dayFirst[2].padStart(2, '0');
    const year = dayFirst[3].length === 2 ? `20${dayFirst[3]}` : dayFirst[3];
    warnings.push(
      `Read ${label} as ${day}/${month}/${year} (day first, the Indian convention).`,
    );
    return `${year}-${month}-${day}`;
  }

  warnings.push(`Could not read ${label} ("${raw}").`);
  return null;
}

/** The model's own confidence, clamped to 0..1. */
function asConfidence(
  value: unknown,
  position: number,
  warnings: string[],
): number | null {
  const parsed = asNumber(value);
  if (parsed === null) {
    return null;
  }
  if (parsed > 1) {
    warnings.push(`Line ${position}: confidence ${parsed} was read as a percentage.`);
    return Math.min(1, parsed / 100);
  }
  return Math.max(0, parsed);
}

/** A markdown code fence, removed if the model wrapped its JSON in one. */
function stripCodeFence(text: string): string {
  const fenced = /^```(?:json)?\s*([\s\S]*?)\s*```$/.exec(text);
  return fenced ? fenced[1] : text;
}

/** [value] as an object, or an empty one. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
