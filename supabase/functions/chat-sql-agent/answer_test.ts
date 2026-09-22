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
import { effectiveParams, LIST_MAX_LIMIT, renderAnswer, UNSUPPORTED } from './answer.ts';
import { ANSWER_LANGUAGES } from './schema.ts';
import type {
  AnswerLanguage,
  ChatParams,
  ClassificationChoice,
  SummarySubject,
} from './schema.ts';

/** The parameters a test does not care about. */
function params(overrides: Partial<ChatParams> = {}): ChatParams {
  return {
    fromDate: null,
    toDate: null,
    days: null,
    limit: null,
    metric: null,
    subject: null,
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

/**
 * One `report_summary` envelope with every section in it, as migration 00021 answers.
 *
 * `sub_total + tax_total = grand_total`, because that is the relation the sentence
 * states out loud and a fixture that broke it would let a wrong reading pass.
 */
const FULL_SUMMARY = {
  from: '2026-09-01',
  to: '2026-09-19',
  sales: {
    count: 12,
    sub_total: 39000,
    tax_total: 6230,
    grand_total: 45230,
    collected: 40000,
    outstanding: 5230,
  },
  purchases: { count: 3, tax_total: 1800, grand_total: 21800 },
  returns: { sale_count: 2, sale_total: 1500, purchase_count: 1, purchase_total: 700 },
  expenses: { count: 4, total: 12000 },
  stock: { products: 314, units: 61360, value_at_cost: 604704.48, value_at_mrp: 812000 },
  expiring: { expired_value_at_mrp: 900, critical_value_at_mrp: 1200, warning_value_at_mrp: 3400 },
};

Deno.test('the subject the question named is the section the sentence leads with', () => {
  // One envelope, five questions, five different sentences - which is the whole of
  // "every summary sounds the same".
  const sentences = new Map<SummarySubject, string>([
    [
      'sales',
      'Between 2026-09-01 and 2026-09-19: 12 sales for **₹45230.00** - '
        + '**₹39000.00** of it before tax and **₹6230.00** tax. '
        + '₹40000.00 collected and **₹5230.00** still due.',
    ],
    [
      'purchases',
      'Between 2026-09-01 and 2026-09-19: 3 purchases were received for **₹21800.00**, '
        + 'of which **₹1800.00** is tax.',
    ],
    [
      'returns',
      'Between 2026-09-01 and 2026-09-19: **₹1500.00** of sales came back over 2 sale returns, '
        + 'and **₹700.00** went back to suppliers over 1 purchase return.',
    ],
    [
      'expenses',
      'Between 2026-09-01 and 2026-09-19: 4 expenses were recorded, totalling **₹12000.00**.',
    ],
    [
      'stock',
      'Stock on hand now is worth **₹604704.48** at cost: 61360 units across 314 products, '
        + 'and **₹812000.00** at MRP.',
    ],
  ]);

  for (const [subject, expected] of sentences) {
    const rendered = renderAnswer('report_summary', FULL_SUMMARY, params({ subject }));
    assertEquals(rendered.understood, true, `${subject} should have rendered`);
    assertEquals(rendered.text, expected, `${subject} read the wrong section`);
  }
});

Deno.test('the tax split and the returns are read, not left in the envelope', () => {
  // Every figure above comes from a section no sentence had ever opened before the
  // subject existed: `sales.sub_total`, `sales.tax_total`, `returns`, `expenses`.
  const sales = renderAnswer('report_summary', FULL_SUMMARY, params({ subject: 'sales' }));
  const returns = renderAnswer('report_summary', FULL_SUMMARY, params({ subject: 'returns' }));

  assertStringIncludes(sales.text, '₹39000.00');
  assertStringIncludes(sales.text, '₹6230.00');
  assertStringIncludes(returns.text, '₹1500.00');
  assertStringIncludes(returns.text, '₹700.00');
});

Deno.test('a stock question is told the stock is NOW, and is given no period at all', () => {
  // The period belongs to the sections that happened in it. `product_stock` is live, so
  // prefixing it with a date range would say the shelf is where it was in September.
  const rendered = renderAnswer('report_summary', FULL_SUMMARY, params({ subject: 'stock' }));

  assertStringIncludes(rendered.text, 'now');
  assertEquals(rendered.text.includes('2026-09-01'), false);
  assertEquals(rendered.text.includes('Between'), false);
});

Deno.test('naming no subject reads exactly as the broad question always did', () => {
  const nothing = renderAnswer('report_summary', FULL_SUMMARY, params());
  const everything = renderAnswer(
    'report_summary',
    FULL_SUMMARY,
    params({ subject: 'everything' }),
  );

  assertEquals(nothing.text, everything.text);
  assertStringIncludes(nothing.text, '12 sales for **₹45230.00**');
});

Deno.test('a period with nothing in it is a sentence, not a row of zeroes', () => {
  const empty = {
    from: '2026-09-01',
    to: '2026-09-19',
    sales: {
      count: 0,
      sub_total: 0,
      tax_total: 0,
      grand_total: 0,
      collected: 0,
      outstanding: 0,
    },
    purchases: { count: 0, tax_total: 0, grand_total: 0 },
    returns: { sale_count: 0, sale_total: 0, purchase_count: 0, purchase_total: 0 },
    expenses: { count: 0, total: 0 },
    stock: { products: 314, units: 61360, value_at_cost: 604704.48, value_at_mrp: 812000 },
  };

  assertEquals(
    renderAnswer('report_summary', empty, params({ subject: 'sales' })).text,
    'Between 2026-09-01 and 2026-09-19: Nothing was billed.',
  );
  assertEquals(
    renderAnswer('report_summary', empty, params({ subject: 'purchases' })).text,
    'Between 2026-09-01 and 2026-09-19: No purchases were received.',
  );
  assertEquals(
    renderAnswer('report_summary', empty, params({ subject: 'returns' })).text,
    'Between 2026-09-01 and 2026-09-19: Nothing came back - no sale returns and no purchase returns.',
  );
  assertEquals(
    renderAnswer('report_summary', empty, params({ subject: 'expenses' })).text,
    'Between 2026-09-01 and 2026-09-19: No expenses were recorded.',
  );
});

Deno.test('a section the envelope does not carry is unreadable, never half a sentence', () => {
  const noPurchases = { from: '2026-09-01', to: '2026-09-19', sales: FULL_SUMMARY.sales };

  const rendered = renderAnswer(
    'report_summary',
    noPurchases,
    params({ subject: 'purchases' }),
  );

  assertEquals(rendered.understood, false);
  assertEquals(rendered.text.includes('₹'), false);
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

Deno.test('a list that came back full is described as a page, not as the whole answer', () => {
  // The defect this closes: `rows.length` is what the report *returned*, and reporting it as
  // the number that are low claimed a total the report never established. A page that came
  // back exactly at its cap says "at least"; one that came back short is the whole answer.
  const rows = [
    { name: 'Dolo 650', shortfall: 40, total_qty: 10, min_stock_level: 50 },
    { name: 'Crocin', shortfall: 5, total_qty: 5, min_stock_level: 10 },
  ];

  assertStringIncludes(
    renderAnswer('low_stock_products', rows, params({ limit: 2 })).text,
    'At least 2 products are below their reorder level.',
  );
  assertEquals(
    renderAnswer('low_stock_products', rows, params({ limit: 3 })).text.startsWith(
      '2 products are',
    ),
    true,
    'a page that came back short is the whole answer',
  );
  assertEquals(
    renderAnswer('low_stock_products', rows, params()).text.startsWith('2 products are'),
    true,
    'with no cap named there is nothing to compare against, so no total is claimed',
  );
});

Deno.test('the two counting list sentences treat a full page the same way', () => {
  const batches = [
    { product_name: 'Amoxy 500', batch_no: 'A-9', days_left: 6, qty: 12, expiry_date: '2026-09-28' },
  ];
  const quiet = [
    { name: 'Old Syrup', total_qty: 24, stock_value_at_cost: 4800, last_sold_on: null },
  ];

  assertStringIncludes(
    renderAnswer('expiring_batches', batches, params({ days: 30, limit: 1 })).text,
    'At least 1 batch expires within 30 days.',
  );
  assertStringIncludes(
    renderAnswer('dead_stock', { meta: { quiet_days: 90 }, rows: quiet }, params({ limit: 1 })).text,
    'At least 1 product has stock that has not sold in 90 days.',
  );
  // And the sentence that counts nothing is unchanged by a full page: "the top seller is
  // Dolo 650" is as true of a page as of the whole list.
  assertStringIncludes(
    renderAnswer('top_products', {
      meta: { window_from: '2026-08-21', window_to: '2026-09-19', metric_used: 'units' },
      rows: [
        { rank: 1, name: 'Dolo 650', units_sold: 120, revenue: 6000 },
        { rank: 2, name: 'Crocin', units_sold: 80, revenue: 1600 },
      ],
    }, params({ limit: 2 })).text,
    'Next is Crocin with 80 units.',
  );
});

Deno.test('a horizon the reports cannot use becomes the default, so the sentence is true', () => {
  // 5000 days is outside both expiry reports' range (1..3650). Forwarded, the report would
  // clamp it to 3650 while the sentence said 5000 - the defect `effectiveParams` removes by
  // replacing a value the report could not have used rather than passing it on.
  assertEquals(effectiveParams('expiring_batches', params({ days: 5000 })).days, 90);
  assertEquals(effectiveParams('expiring_batches', params({ days: 0 })).days, 90);
  assertEquals(effectiveParams('expiring_batches', params({ days: -3 })).days, 90);
  assertEquals(effectiveParams('expiring_batches', params({ days: 30 })).days, 30);
  assertEquals(effectiveParams('expiring_batches', params({ days: 3650 })).days, 3650);
  assertEquals(effectiveParams('dead_stock', params({ days: 5000 })).days, 90);
  assertEquals(effectiveParams('dead_stock', params({ days: 30 })).days, 30);
});

Deno.test('a cap the reports cannot use becomes the default, and one they can is kept', () => {
  assertEquals(effectiveParams('low_stock_products', params()).limit, 50);
  assertEquals(effectiveParams('low_stock_products', params({ limit: 5000 })).limit, 50);
  assertEquals(effectiveParams('low_stock_products', params({ limit: 0 })).limit, 50);
  assertEquals(effectiveParams('low_stock_products', params({ limit: 5 })).limit, 5);
  assertEquals(effectiveParams('expiring_batches', params()).limit, 50);
  assertEquals(effectiveParams('dead_stock', params()).limit, 50);
  assertEquals(effectiveParams('top_products', params()).limit, 20);
  // The largest cap this function will ever ask for is inside every list report's own
  // maximum, which is what makes "the page came back full, so say at least" sound.
  assertEquals(effectiveParams('low_stock_products', params({ limit: LIST_MAX_LIMIT })).limit, LIST_MAX_LIMIT);
  assertEquals(effectiveParams('low_stock_products', params({ limit: LIST_MAX_LIMIT + 1 })).limit, 50);
});

Deno.test('a summary is left exactly as the model declared it', () => {
  const declared = params({ fromDate: '2026-09-01', toDate: '2026-09-19', subject: 'sales' });
  assertEquals(effectiveParams('report_summary', declared), declared);
});

Deno.test('an unreadable array is reported rather than rendered as empty', () => {
  const rendered = renderAnswer('low_stock_products', { rows: [] }, params());

  assertEquals(rendered.understood, false);
});

Deno.test('a question no report answers gets the fixed refusal', () => {
  const rendered = renderAnswer('unsupported', null, params());

  assertEquals(rendered.text, UNSUPPORTED.en);
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
  // Over every language, because the marker is the SERVER's syntax in each of them: a
  // Hinglish sentence with an unclosed marker would show a reader a stray `**` exactly as an
  // English one would.
  for (const language of ANSWER_LANGUAGES) {
    for (const [rpc, data, p] of FINDING_SENTENCES) {
      const rendered = renderAnswer(rpc, data, p, language);
      const markers = markerCount(rendered.text);

      assertEquals(rendered.understood, true, `${rpc}/${language} should have rendered`);
      assertEquals(
        markers > 0,
        true,
        `${rpc}/${language} should point at something: ${rendered.text}`,
      );
      assertEquals(
        markers % 2,
        0,
        `${rpc}/${language} left a marker unclosed, which the client would show as a stray **: ${rendered.text}`,
      );
    }
  }
});

Deno.test('an emphasis always brackets something: no marker brackets nothing', () => {
  for (const language of ANSWER_LANGUAGES) {
    for (const [rpc, data, p] of FINDING_SENTENCES) {
      const { text } = renderAnswer(rpc, data, p, language);

      assertEquals(text.includes('****'), false, `${rpc}/${language} brackets nothing: ${text}`);
      assertEquals(text.startsWith('** '), false, `${rpc}/${language} marks whitespace: ${text}`);
      assertEquals(text.endsWith(' **'), false, `${rpc}/${language} marks whitespace: ${text}`);
    }
  }
});

Deno.test('a sentence with nothing to point at carries no marker at all', () => {
  // In either language: a marker that appears everywhere points at nothing, so the four
  // "nothing is low / expiring / sold / quiet" sentences and the fixed refusal are plain
  // prose - which is also what lets the client render them exactly as it did before markers
  // existed.
  for (const language of ANSWER_LANGUAGES) {
    for (const [rpc, data, p] of NOTHING_SENTENCES) {
      const rendered = renderAnswer(rpc, data, p, language);

      assertEquals(rendered.understood, true, `${rpc}/${language} should have rendered`);
      assertEquals(
        markerCount(rendered.text),
        0,
        `${rpc}/${language} has nothing to point at, so it should carry no marker: ${rendered.text}`,
      );
    }
  }
});

Deno.test('every sentence a report can write can be said in Hinglish', () => {
  // One envelope per shape, and the Hinglish sentence it must produce. This is the test that
  // keeps the language feature from being a half-translation: a report whose Hinglish key was
  // forgotten fails to COMPILE (the sentence tables are keyed by the language union), and one
  // whose Hinglish was written but never checked fails here.
  const cases: Array<[ClassificationChoice, unknown, ChatParams, string]> = [
    [
      'report_summary',
      FULL_SUMMARY,
      params({ subject: 'sales' }),
      '2026-09-01 se 2026-09-19 tak: 12 bill bane - total **₹45230.00**, '
        + 'jisme **₹39000.00** tax se pehle aur **₹6230.00** tax hai. '
        + '**₹40000.00** mil gaye, **₹5230.00** abhi baaki hai.',
    ],
    [
      'report_summary',
      FULL_SUMMARY,
      params({ subject: 'stock' }),
      'Abhi stock ki value cost par **₹604704.48** hai: 61360 unit, 314 product - '
        + 'aur MRP par **₹812000.00**.',
    ],
    [
      'low_stock_products',
      [{ name: 'Dolo 650', shortfall: 40, total_qty: 10, min_stock_level: 50 }],
      params(),
      '1 product apne reorder level se neeche hai. Sabse badi kami **Dolo 650** mein hai: '
        + '**40 unit kam** (stock 10, level 50).',
    ],
    [
      'expiring_batches',
      [{ product_name: 'Amoxy 500', batch_no: 'A-9', days_left: -6, qty: 12, expiry_date: '2026-09-13' }],
      params({ days: 30 }),
      '1 batch 30 din mein expire ho rahe hain. Sabse pehle **Amoxy 500** batch A-9 - '
        + '**6 din pehle expire ho gaya** (2026-09-13) - shelf par 12 unit.',
    ],
    [
      'top_products',
      {
        meta: { window_from: '2026-08-21', window_to: '2026-09-19', metric_used: 'units' },
        rows: [
          { rank: 1, name: 'Dolo 650', units_sold: 120, revenue: 6000 },
          { rank: 2, name: 'Crocin', units_sold: 80, revenue: 1600 },
        ],
      },
      params(),
      'Units ke hisaab se, 2026-08-21 se 2026-09-19 ke beech sabse zyada bikne wala '
        + '**Dolo 650** hai: **120 unit**, **₹6000.00** ka. Uske baad Crocin, 80 unit.',
    ],
    [
      'dead_stock',
      {
        meta: { quiet_days: 90 },
        rows: [{ name: 'Old Syrup', total_qty: 24, stock_value_at_cost: 4800, last_sold_on: null }],
      },
      params(),
      '1 product ka maal 90 din se nahi bika. Sabse zyada paisa **Old Syrup** mein atka hai: '
        + '24 unit, cost par **₹4800.00** - kabhi nahi bika.',
    ],
  ];

  for (const [rpc, data, p, expected] of cases) {
    const rendered = renderAnswer(rpc, data, p, 'hinglish');

    assertEquals(rendered.understood, true, `${rpc} should have rendered in Hinglish`);
    assertEquals(rendered.text, expected, `${rpc}'s Hinglish sentence is not the one written`);
  }
});

Deno.test('the Hinglish sentences that have no finding are Hinglish too', () => {
  const empty = renderAnswer('low_stock_products', [], params(), 'hinglish');
  const refusal = renderAnswer('unsupported', null, params(), 'hinglish');
  const unreadable = renderAnswer('low_stock_products', { rows: [] }, params(), 'hinglish');

  assertEquals(empty.text, 'Koi bhi product apne reorder level se neeche nahi hai.');
  assertEquals(refusal.text, UNSUPPORTED.hinglish);
  assertStringIncludes(unreadable.text, 'samajh nahi sakta');
  assertEquals(unreadable.understood, false);
});

Deno.test('an English answer is exactly what it was before this file could speak Hinglish', () => {
  // The default language, and the one every caller sent before this existed. Asking for it
  // explicitly and not asking at all must be the same string, for every shape.
  for (const [rpc, data, p] of [...FINDING_SENTENCES, ...NOTHING_SENTENCES]) {
    assertEquals(
      renderAnswer(rpc, data, p, 'en').text,
      renderAnswer(rpc, data, p).text,
      `${rpc}'s English sentence must not depend on whether the language was named`,
    );
  }
});
