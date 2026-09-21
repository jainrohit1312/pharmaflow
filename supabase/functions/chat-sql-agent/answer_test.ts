/**
 * Tests for the templated answers (D-053).
 *
 * The property this file exists for: **every figure in a sentence came out of the
 * report's envelope.** There is no argument here that carries a number, so a
 * sentence cannot contain one the database did not compute - and an envelope in a
 * shape the template does not recognise renders "I could not read the answer"
 * rather than `undefined`.
 *
 * The second property, added with the emphasis marker, is that the marker is
 * **decoration on the sentence and never part of it**: every marker is closed, no
 * marker brackets nothing, and a sentence with no finding carries none at all. The
 * client drops the markers to get the words back (`answer_emphasis.dart`), so a
 * sentence that left one dangling would show a reader a stray `**`.
 *
 * Run: `deno test supabase/functions/chat-sql-agent/answer_test.ts`
 */

import { assertEquals, assertStringIncludes } from 'jsr:@std/assert';
import { renderAnswer, UNSUPPORTED_ANSWER } from './answer.ts';
import type { ChatParams, ClassificationChoice } from './schema.ts';

/** The parameters a test does not care about. */
function params(overrides: Partial<ChatParams> = {}): ChatParams {
  return {
    fromDate: null,
    toDate: null,
    days: null,
    limit: null,
    metric: null,
    ...overrides,
  };
}

/** The number of markers in [text]. Two per emphasis, so an emphasis is balanced. */
function markerCount(text: string): number {
  return (text.match(/\*\*/g) ?? []).length;
}

/**
 * One *finding* sentence per report: an envelope with something in it, which is
 * when a sentence has a figure worth pointing at.
 */
const FINDING_SENTENCES: Array<[ClassificationChoice, unknown, ChatParams]> = [
  [
    'report_summary',
    {
      from: '2026-09-01',
      to: '2026-09-19',
      sales: { count: 12, grand_total: 45230, collected: 40000, outstanding: 5230 },
      purchases: { count: 3 },
      stock: { value_at_cost: 250000.5 },
    },
    params(),
  ],
  [
    'low_stock_products',
    [{ name: 'Dolo 650', shortfall: 40, total_qty: 10, min_stock_level: 50 }],
    params(),
  ],
  [
    'expiring_batches',
    [{ product_name: 'Amoxy 500', batch_no: 'A-9', days_left: 6, qty: 12, expiry_date: '2026-09-28' }],
    params({ days: 30 }),
  ],
  [
    'top_products',
    {
      meta: { window_from: '2026-08-21', window_to: '2026-09-19', metric_used: 'units' },
      rows: [{ rank: 1, name: 'Dolo 650', units_sold: 120, revenue: 6000 }],
    },
    params(),
  ],
  [
    'dead_stock',
    {
      meta: { quiet_days: 90 },
      rows: [{ name: 'Old Syrup', total_qty: 24, stock_value_at_cost: 4800, last_sold_on: null }],
    },
    params(),
  ],
];

/**
 * One *empty* sentence per report, plus the two fixed ones: nothing was found, so
 * there is nothing to point at.
 */
const NOTHING_SENTENCES: Array<[ClassificationChoice, unknown, ChatParams]> = [
  ['low_stock_products', [], params()],
  ['expiring_batches', [], params({ days: 90 })],
  ['top_products', { meta: { window_from: '2026-09-01', window_to: '2026-09-19' }, rows: [] }, params()],
  ['dead_stock', { meta: { quiet_days: 30 }, rows: [] }, params()],
  ['unsupported', null, params()],
];

Deno.test('a summary says the numbers the report returned, and its own window', () => {
  const rendered = renderAnswer('report_summary', {
    from: '2026-09-01',
    to: '2026-09-19',
    sales: {
      count: 12,
      grand_total: 45230,
      collected: 40000,
      outstanding: 5230,
    },
    purchases: { count: 3 },
    stock: { value_at_cost: 250000.5 },
  }, params());

  assertEquals(rendered.understood, true);
  assertEquals(
    rendered.text,
    'Between 2026-09-01 and 2026-09-19: 12 sales for **₹45230.00**, ₹40000.00 collected and **₹5230.00** still due. '
      + '3 purchases were received. Stock on hand is worth **₹250000.50** at cost.',
  );
});

Deno.test('an envelope missing the figures is not rendered as if it had them', () => {
  const rendered = renderAnswer('report_summary', { sales: { count: 12 } }, params());

  assertEquals(rendered.understood, false);
  assertStringIncludes(rendered.text, 'does not understand');
});

Deno.test('nothing low on stock is a sentence, not an empty list', () => {
  const rendered = renderAnswer('low_stock_products', [], params());

  assertEquals(rendered.understood, true);
  assertEquals(rendered.text, 'Nothing is below its reorder level.');
});

Deno.test('the low-stock sentence leads with the biggest gap the report ranked first', () => {
  const rendered = renderAnswer('low_stock_products', [
    { name: 'Dolo 650', shortfall: 40, total_qty: 10, min_stock_level: 50 },
    { name: 'Crocin', shortfall: 5, total_qty: 5, min_stock_level: 10 },
  ], params());

  assertEquals(
    rendered.text,
    '2 products are below their reorder level. '
      + 'The biggest gap is **Dolo 650**: **40 units short** (10 in stock against a level of 50).',
  );
});

Deno.test('one product low reads in the singular', () => {
  const rendered = renderAnswer('low_stock_products', [
    { name: 'Dolo 650', shortfall: 1, total_qty: 9, min_stock_level: 10 },
  ], params());

  assertStringIncludes(rendered.text, '1 product is below its reorder level.');
  assertStringIncludes(rendered.text, '**1 unit short**');
});

Deno.test('the low-stock wording matches the rule the report applies', () => {
  // `low_stock_products` filters `total_qty < min_stock_level` (migration 00027),
  // deliberately strict: a product *at* its level is where the pharmacy meant to
  // act, and it is *not* on the list. Saying "at or below" claimed a row the
  // report does not return - the sentence and the query have to agree.
  const empty = renderAnswer('low_stock_products', [], params());
  const finding = renderAnswer('low_stock_products', [
    { name: 'Dolo 650', shortfall: 40, total_qty: 10, min_stock_level: 50 },
  ], params());

  for (const rendered of [empty, finding]) {
    assertEquals(
      rendered.text.includes('at or below'),
      false,
      `"at or below" is not the rule: ${rendered.text}`,
    );
    assertStringIncludes(rendered.text, 'below');
  }
});

Deno.test('an already-expired batch reads as expired, not as a negative countdown', () => {
  const rendered = renderAnswer('expiring_batches', [
    {
      product_name: 'Amoxy 500',
      batch_no: 'A-9',
      days_left: -6,
      qty: 12,
      expiry_date: '2026-09-13',
    },
  ], params({ days: 30 }));

  assertStringIncludes(rendered.text, 'The soonest is **Amoxy 500** batch A-9');
  assertStringIncludes(rendered.text, '**already expired 6 days ago**');
  assertStringIncludes(rendered.text, '12 units on the shelf');
});

Deno.test('an unexpired batch points at the time it has left', () => {
  const rendered = renderAnswer('expiring_batches', [
    {
      product_name: 'Amoxy 500',
      batch_no: 'A-9',
      days_left: 6,
      qty: 12,
      expiry_date: '2026-09-28',
    },
  ], params({ days: 30 }));

  assertStringIncludes(rendered.text, '**6 days left**');
});

Deno.test('the expiry sentence states the horizon the query actually used', () => {
  const rendered = renderAnswer('expiring_batches', [], params({ days: 7 }));

  assertEquals(rendered.text, 'No batches expire within 7 days.');
});

Deno.test('the top-seller sentence takes its window and metric from the report meta', () => {
  const rendered = renderAnswer('top_products', {
    meta: {
      window_from: '2026-08-21',
      window_to: '2026-09-19',
      metric_used: 'units',
      returns_not_netted: true,
      limit: 20,
    },
    rows: [
      { rank: 1, name: 'Dolo 650', units_sold: 120, revenue: 6000 },
      { rank: 2, name: 'Crocin', units_sold: 80, revenue: 1600 },
    ],
  }, params());

  assertEquals(
    rendered.text,
    'By units sold, between 2026-08-21 and 2026-09-19 the top seller is **Dolo 650**: '
      + '**120 units** for **₹6000.00**. Next is Crocin with 80 units.',
  );
});

Deno.test('ranking by revenue says so, because the report said so', () => {
  const rendered = renderAnswer('top_products', {
    meta: { window_from: '2026-09-01', window_to: '2026-09-19', metric_used: 'revenue' },
    rows: [{ rank: 1, name: 'Zincovit', units_sold: 3, revenue: 900 }],
  }, params());

  assertStringIncludes(rendered.text, 'By revenue,');
});

Deno.test('nothing sold in the window is a sentence', () => {
  const rendered = renderAnswer('top_products', {
    meta: { window_from: '2026-09-01', window_to: '2026-09-19' },
    rows: [],
  }, params());

  assertEquals(rendered.text, 'Nothing sold between 2026-09-01 and 2026-09-19.');
});

Deno.test('dead stock that never sold says so, which is the strongest case of the answer', () => {
  const rendered = renderAnswer('dead_stock', {
    meta: { as_of: '2026-09-19', quiet_days: 90, limit: 50 },
    rows: [
      {
        name: 'Old Syrup',
        total_qty: 24,
        stock_value_at_cost: 4800,
        last_sold_on: null,
      },
    ],
  }, params());

  assertEquals(rendered.understood, true);
  assertStringIncludes(rendered.text, 'The most cash tied up is **Old Syrup**');
  assertStringIncludes(rendered.text, '24 units worth **₹4800.00** at cost, never sold');
});

Deno.test('the dead-stock horizon comes from the report meta, not from the caller', () => {
  const rendered = renderAnswer('dead_stock', {
    meta: { quiet_days: 30 },
    rows: [],
  }, params({ days: 90 }));

  assertEquals(rendered.text, 'Nothing has gone quiet in the last 30 days.');
});

Deno.test('an unreadable array is reported rather than rendered as empty', () => {
  const rendered = renderAnswer('low_stock_products', { rows: [] }, params());

  assertEquals(rendered.understood, false);
});

Deno.test('a question no report answers gets the fixed refusal', () => {
  const rendered = renderAnswer('unsupported', null, params());

  assertEquals(rendered.text, UNSUPPORTED_ANSWER);
  assertEquals(rendered.understood, true);
});

Deno.test('a figure the report did not send is never invented', () => {
  const rendered = renderAnswer('dead_stock', {
    meta: { quiet_days: 90 },
    rows: [{ name: 'Old Syrup', total_qty: 24 }],
  }, params());

  assertEquals(rendered.understood, false);
  assertEquals(rendered.text.includes('₹'), false);
});

Deno.test('a sentence points at its finding, and every marker it writes is closed', () => {
  for (const [rpc, data, p] of FINDING_SENTENCES) {
    const rendered = renderAnswer(rpc, data, p);
    const markers = markerCount(rendered.text);

    assertEquals(rendered.understood, true, `${rpc} should have rendered`);
    assertEquals(markers > 0, true, `${rpc} should point at something: ${rendered.text}`);
    assertEquals(
      markers % 2,
      0,
      `${rpc} left a marker unclosed, which the client would show as a stray **: ${rendered.text}`,
    );
  }
});

Deno.test('an emphasis always brackets something: no marker brackets nothing', () => {
  for (const [rpc, data, p] of FINDING_SENTENCES) {
    const { text } = renderAnswer(rpc, data, p);

    assertEquals(text.includes('****'), false, `${rpc} brackets nothing: ${text}`);
    assertEquals(text.startsWith('** '), false, `${rpc} marks whitespace: ${text}`);
    assertEquals(text.endsWith(' **'), false, `${rpc} marks whitespace: ${text}`);
  }
});

Deno.test('a sentence with nothing to point at carries no marker at all', () => {
  // A marker that appears everywhere points at nothing, so the four "nothing is
  // low / expiring / sold / quiet" sentences and the fixed refusal are plain prose
  // - which is also what lets the client render them exactly as it did before
  // markers existed.
  for (const [rpc, data, p] of NOTHING_SENTENCES) {
    const rendered = renderAnswer(rpc, data, p);

    assertEquals(rendered.understood, true, `${rpc} should have rendered`);
    assertEquals(
      markerCount(rendered.text),
      0,
      `${rpc} has nothing to point at, so it should carry no marker: ${rendered.text}`,
    );
  }
});
