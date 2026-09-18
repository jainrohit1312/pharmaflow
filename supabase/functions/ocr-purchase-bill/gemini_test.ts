/**
 * Tests for the model-facing half of the bill reader.
 *
 * Everything here runs on a laptop: no Docker, no API key, no network. The
 * subject is the one place this function handles data it did not produce — the
 * model's reply — so the cases are the ones a real invoice will produce:
 * numbers written as strings, a quantity the schema stores as an integer but a
 * bill that prints as a fraction, and the Indian day-first date that a default
 * parser silently reads as a different day of the month.
 *
 * Run: `deno test supabase/functions/ocr-purchase-bill/gemini_test.ts`
 */

import { assertEquals, assertStringIncludes } from 'jsr:@std/assert';
import { FunctionError } from '../_shared/errors.ts';
import {
  buildGenerateContentBody,
  extractPayloadText,
  generateContentUrl,
  mimeForPath,
  normalizeInvoice,
  parsePayloadJson,
} from './gemini.ts';

/** The failure code [fn] threw, for asserting *why* something was refused. */
async function codeOf(fn: () => unknown): Promise<string> {
  try {
    await fn();
  } catch (error) {
    return error instanceof FunctionError ? error.code : `not-a-FunctionError:${error}`;
  }
  return 'did-not-throw';
}

Deno.test('mimeForPath accepts the four bill types the bucket allows', () => {
  assertEquals(mimeForPath('p/2026/bill.jpg'), 'image/jpeg');
  assertEquals(mimeForPath('p/2026/bill.JPEG'), 'image/jpeg');
  assertEquals(mimeForPath('p/2026/bill.png'), 'image/png');
  assertEquals(mimeForPath('p/2026/bill.webp'), 'image/webp');
  assertEquals(mimeForPath('p/2026/bill.pdf'), 'application/pdf');
  assertEquals(mimeForPath('p/2026/bill.heic'), null);
  assertEquals(mimeForPath('p/2026/bill'), null);
});

Deno.test('the request asks for JSON, at temperature zero, with the image inline', () => {
  const body = buildGenerateContentBody({
    model: 'gemini-2.5-flash',
    mimeType: 'image/jpeg',
    base64: 'AAAA',
  }) as Record<string, any>;

  assertEquals(body.generationConfig.temperature, 0);
  assertEquals(body.generationConfig.responseMimeType, 'application/json');
  assertEquals(body.generationConfig.responseSchema.type, 'OBJECT');

  const parts = body.contents[0].parts;
  assertEquals(parts[1].inlineData.mimeType, 'image/jpeg');
  assertEquals(parts[1].inlineData.data, 'AAAA');
  assertStringIncludes(body.systemInstruction.parts[0].text, 'Never invent');
});

Deno.test('the endpoint keeps the key out of the URL', () => {
  assertEquals(
    generateContentUrl('gemini-2.5-flash'),
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',
  );
});

Deno.test('extractPayloadText reads the JSON out of a reply', () => {
  const reply = {
    candidates: [{ content: { parts: [{ text: '{"lines":[]}' }] } }],
  };
  assertEquals(extractPayloadText(reply), '{"lines":[]}');
});

Deno.test('extractPayloadText joins a reply split across parts', () => {
  const reply = {
    candidates: [{ content: { parts: [{ text: '{"a":' }, { text: '1}' }] } }],
  };
  assertEquals(extractPayloadText(reply), '{"a":1}');
});

Deno.test('extractPayloadText unwraps a markdown fence', () => {
  const reply = {
    candidates: [{ content: { parts: [{ text: '```json\n{"lines":[]}\n```' }] } }],
  };
  assertEquals(extractPayloadText(reply), '{"lines":[]}');
});

Deno.test('a refused image is reported as such, not as an empty bill', async () => {
  const code = await codeOf(() =>
    extractPayloadText({ promptFeedback: { blockReason: 'SAFETY' } })
  );
  assertEquals(code, 'provider_unavailable');
});

Deno.test('a reply with no content says why the model stopped', async () => {
  const code = await codeOf(() =>
    extractPayloadText({ candidates: [{ finishReason: 'MAX_TOKENS' }] })
  );
  assertEquals(code, 'provider_unavailable');
});

Deno.test('prose instead of JSON is refused rather than half-parsed', async () => {
  const code = await codeOf(() => parsePayloadJson('I could not read this bill.'));
  assertEquals(code, 'provider_unavailable');
});

Deno.test('a full reply maps onto the envelope with nothing to warn about', () => {
  const bill = normalizeInvoice(
    {
      document: {
        supplier_name: 'Arihant Distributors',
        gstin: '27ABCDE1234F1Z5',
        invoice_no: 'INV-2026-0042',
        invoice_date: '2026-09-18',
        sub_total: 1000,
        tax_total: 120,
        grand_total: 1120,
      },
      lines: [
        {
          raw_name: 'Dolo 650 Tab 15s',
          qty: 10,
          free_qty: 1,
          rate: 100,
          mrp: 150,
          gst_percent: 12,
          batch_no: 'D650-A21',
          expiry_date: '2027-06-30',
          hsn_code: '3004',
          confidence: 0.92,
        },
      ],
    },
    'gemini-2.5-flash',
  );

  assertEquals(bill.document.invoice_no, 'INV-2026-0042');
  assertEquals(bill.document.invoice_date, '2026-09-18');
  assertEquals(bill.document.grand_total, 1120);
  assertEquals(bill.lines.length, 1);
  assertEquals(bill.lines[0].raw_name, 'Dolo 650 Tab 15s');
  assertEquals(bill.lines[0].free_qty, 1);
  assertEquals(bill.lines[0].expiry_date, '2027-06-30');
  assertEquals(bill.lines[0].confidence, 0.92);
  assertEquals(bill.meta.model, 'gemini-2.5-flash');
  assertEquals(bill.meta.warnings, []);
});

Deno.test('money written as text is read as a number', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1', grand_total: '₹1,120.00' },
      lines: [{ raw_name: 'Amoxy 500', qty: '10', rate: '1,25.50', mrp: 'Rs. 200' }],
    },
    'm',
  );

  assertEquals(bill.document.grand_total, 1120);
  assertEquals(bill.lines[0].qty, 10);
  assertEquals(bill.lines[0].rate, 125.5);
  assertEquals(bill.lines[0].mrp, 200);
});

Deno.test('an Indian thousands separator is not read as a decimal point', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1', grand_total: '10,50,000' },
      lines: [{ raw_name: 'Dolo 650', rate: '1,25' }],
    },
    'm',
  );

  assertEquals(bill.document.grand_total, 1050000);
  assertEquals(bill.lines[0].rate, 1.25);
});

Deno.test('a fractional quantity is rounded, and the user is told', () => {
  const bill = normalizeInvoice(
    { document: { invoice_no: 'INV-1' }, lines: [{ raw_name: 'Syrup', qty: 2.5 }] },
    'm',
  );

  assertEquals(bill.lines[0].qty, 3);
  assertEquals(bill.meta.warnings.some((w) => w.includes('rounded')), true);
});

Deno.test('a day-first date is read as day-first and says so', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1', invoice_date: '18/09/2026' },
      lines: [{ raw_name: 'Dolo 650', expiry_date: '30/06/2027' }],
    },
    'm',
  );

  assertEquals(bill.document.invoice_date, '2026-09-18');
  assertEquals(bill.lines[0].expiry_date, '2027-06-30');
  assertEquals(bill.meta.warnings.some((w) => w.includes('day first')), true);
});

Deno.test('a year-first date needs no warning, being unambiguous', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1', invoice_date: '2026/09/18' },
      lines: [{ raw_name: 'Dolo 650', expiry_date: '2027.06.30' }],
    },
    'm',
  );

  assertEquals(bill.document.invoice_date, '2026-09-18');
  assertEquals(bill.lines[0].expiry_date, '2027-06-30');
  assertEquals(bill.meta.warnings, []);
});

Deno.test('an unreadable date becomes null with a warning, never a guess', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1' },
      lines: [{ raw_name: 'Dolo 650', expiry_date: 'some time next year' }],
    },
    'm',
  );

  assertEquals(bill.lines[0].expiry_date, null);
  assertEquals(bill.meta.warnings.some((w) => w.includes('Could not read')), true);
});

Deno.test('a line the model invented out of nothing is dropped', () => {
  const bill = normalizeInvoice(
    {
      document: { invoice_no: 'INV-1' },
      lines: [
        { raw_name: 'Dolo 650', qty: 10 },
        { raw_name: null, qty: null, rate: null, mrp: null, batch_no: null },
      ],
    },
    'm',
  );

  assertEquals(bill.lines.length, 1);
});

Deno.test('a reply with no lines says so instead of showing an empty table', () => {
  const bill = normalizeInvoice({ document: { invoice_no: 'INV-1' } }, 'm');

  assertEquals(bill.lines, []);
  assertEquals(bill.meta.warnings.some((w) => w.includes('No line items')), true);
});

Deno.test('a missing invoice number is warned about, not defaulted', () => {
  const bill = normalizeInvoice({ document: {}, lines: [] }, 'm');

  assertEquals(bill.document.invoice_no, null);
  assertEquals(bill.meta.warnings.some((w) => w.includes('invoice number')), true);
});

Deno.test('a flat reply is read rather than thrown away', () => {
  const bill = normalizeInvoice(
    { invoice_no: 'INV-9', supplier_name: 'Arihant', lines: [{ raw_name: 'Dolo', qty: 1 }] },
    'm',
  );

  assertEquals(bill.document.invoice_no, 'INV-9');
  assertEquals(bill.document.supplier_name, 'Arihant');
  assertEquals(bill.lines.length, 1);
});

Deno.test('a confidence sent as a percentage is scaled, and said', () => {
  const bill = normalizeInvoice(
    { document: { invoice_no: 'INV-1' }, lines: [{ raw_name: 'Dolo', confidence: 92 }] },
    'm',
  );

  assertEquals(bill.lines[0].confidence, 0.92);
  assertEquals(bill.meta.warnings.some((w) => w.includes('percentage')), true);
});

Deno.test('nonsense where the lines should be does not crash the reader', () => {
  const bill = normalizeInvoice(
    { document: { invoice_no: 'INV-1' }, lines: 'see attached' },
    'm',
  );

  assertEquals(bill.lines, []);
  assertEquals(bill.meta.warnings.some((w) => w.includes('No line items')), true);
});

Deno.test('an entirely empty reply reads as an empty bill, not as a failure', () => {
  const bill = normalizeInvoice(null, 'm');

  assertEquals(bill.lines, []);
  assertEquals(bill.document.invoice_no, null);
  assertEquals(bill.meta.warnings.length > 0, true);
});
