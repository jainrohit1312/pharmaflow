/**
 * Every sentence the chatbot can say, and the only place a figure is written.
 *
 * D-053 is the rule this file implements: **the model never produces a numeral.**
 * The model picks a report and fills its parameters (see `schema.ts`); the report
 * returns a `jsonb` envelope; and the sentence below is a template in code, filled
 * from that envelope. There is no code path in which model output is rendered to
 * the user - so there is no path in which a number nobody computed can appear.
 *
 * That is why this is a `switch` over a closed set rather than a prompt: adding a
 * capability means adding a report and a case, not coaching a model. The
 * rendering is also where the envelope's own semantics are used - `top_products`
 * and `dead_stock` carry a `meta` block (D-053), so their sentences report the
 * window that was actually queried rather than one this file guessed.
 *
 * `understood` is false when a report answered in a shape this file does not
 * recognise. That is a warning rather than an error: the query ran and the caller
 * may still want the raw envelope, and saying "I could not read the answer" is
 * better than rendering `undefined`.
 */

import type { ChatParams, ClassificationChoice } from './schema.ts';

/** A rendered answer, and whether the envelope was readable. */
export interface RenderedAnswer {
  text: string;
  understood: boolean;
}

/**
 * The horizon `expiring_batches` uses when the caller (or the model) gives none.
 *
 * It mirrors that function's own default (migration 00027). It is stated here
 * because the function passes it explicitly, so the sentence describes the query
 * that actually ran - and because `expiring_batches` returns a bare array with no
 * `meta` to read the horizon back from.
 */
export const EXPIRING_DEFAULT_DAYS = 90;

/** The horizon `dead_stock` uses when none is given. Mirrors migration 00029. */
export const DEAD_STOCK_DEFAULT_DAYS = 90;

/** The fixed sentence for a question none of the reports answers. */
export const UNSUPPORTED_ANSWER =
  'I cannot answer that. I can answer questions about sales and purchases, stock levels, expiring batches, what sells best, and what has stopped selling.';

/** The report [rpc] returned; [text] is what the caller reads. */
export function renderAnswer(
  rpc: ClassificationChoice,
  data: unknown,
  params: ChatParams,
): RenderedAnswer {
  switch (rpc) {
    case 'report_summary':
      return renderSummary(data);
    case 'low_stock_products':
      return renderLowStock(data);
    case 'expiring_batches':
      return renderExpiring(data, params.days ?? EXPIRING_DEFAULT_DAYS);
    case 'top_products':
      return renderTopProducts(data);
    case 'dead_stock':
      return renderDeadStock(data, params.days ?? DEAD_STOCK_DEFAULT_DAYS);
    case 'unsupported':
      return { text: UNSUPPORTED_ANSWER, understood: true };
  }
}

/** A refusal to render an envelope in an unexpected shape. */
const UNREADABLE: RenderedAnswer = {
  text: 'That report ran, but its answer came back in a shape this app does not understand.',
  understood: false,
};

function renderSummary(data: unknown): RenderedAnswer {
  const envelope = asRecord(data);
  const sales = asRecord(envelope.sales);
  const purchases = asRecord(envelope.purchases);
  const stock = asRecord(envelope.stock);

  const count = integer(sales.count);
  const grandTotal = money(sales.grand_total);
  const collected = money(sales.collected);
  const outstanding = money(sales.outstanding);
  const purchaseCount = integer(purchases.count);
  const stockValue = money(stock.value_at_cost);
  const from = asString(envelope.from);
  const to = asString(envelope.to);

  if (
    count === null || grandTotal === null || collected === null ||
    outstanding === null || purchaseCount === null || stockValue === null
  ) {
    return UNREADABLE;
  }

  const window = from !== null && to !== null ? `Between ${from} and ${to}: ` : '';

  return {
    text:
      `${window}${count} ${plural(count, 'sale', 'sales')} for ${grandTotal}, ` +
      `${collected} collected and ${outstanding} still due. ` +
      `${purchaseCount} ${plural(purchaseCount, 'purchase was', 'purchases were')} received. ` +
      `Stock on hand is worth ${stockValue} at cost.`,
    understood: true,
  };
}

function renderLowStock(data: unknown): RenderedAnswer {
  const rows = asArray(data);
  if (rows === null) {
    return UNREADABLE;
  }
  if (rows.length === 0) {
    return { text: 'Nothing is at or below its reorder level.', understood: true };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const shortfall = integer(first.shortfall);
  const totalQty = integer(first.total_qty);
  const level = integer(first.min_stock_level);

  if (name === null || shortfall === null || totalQty === null || level === null) {
    return UNREADABLE;
  }

  return {
    text:
      `${rows.length} ${plural(rows.length, 'product is', 'products are')} at or below the reorder level. ` +
      `The biggest gap is ${name}: ${shortfall} ${plural(shortfall, 'unit', 'units')} short ` +
      `(${totalQty} in stock against a level of ${level}).`,
    understood: true,
  };
}

function renderExpiring(data: unknown, days: number): RenderedAnswer {
  const rows = asArray(data);
  if (rows === null) {
    return UNREADABLE;
  }
  if (rows.length === 0) {
    return {
      text: `No batches expire within ${days} days.`,
      understood: true,
    };
  }

  const first = asRecord(rows[0]);
  const product = asString(first.product_name);
  const batchNo = asString(first.batch_no);
  const daysLeft = integer(first.days_left);
  const qty = integer(first.qty);
  const expiryDate = asString(first.expiry_date);

  if (product === null || daysLeft === null || qty === null) {
    return UNREADABLE;
  }

  const when = daysLeft < 0
    ? `already expired ${Math.abs(daysLeft)} ${plural(Math.abs(daysLeft), 'day', 'days')} ago`
    : `${daysLeft} ${plural(daysLeft, 'day', 'days')} left`;

  return {
    text:
      `${rows.length} ${plural(rows.length, 'batch expires', 'batches expire')} within ${days} days. ` +
      `The soonest is ${product}${batchNo !== null ? ` batch ${batchNo}` : ''}, ${when}` +
      `${expiryDate !== null ? ` (${expiryDate})` : ''} - ${qty} ${plural(qty, 'unit', 'units')} on the shelf.`,
    understood: true,
  };
}

function renderTopProducts(data: unknown): RenderedAnswer {
  const envelope = asRecord(data);
  const rows = asArray(envelope.rows);
  const meta = asRecord(envelope.meta);

  if (rows === null) {
    return UNREADABLE;
  }

  const from = asString(meta.window_from);
  const to = asString(meta.window_to);
  const window = from !== null && to !== null ? `between ${from} and ${to}` : 'in that window';

  if (rows.length === 0) {
    return { text: `Nothing sold ${window}.`, understood: true };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const units = integer(first.units_sold);
  const revenue = money(first.revenue);

  if (name === null || units === null || revenue === null) {
    return UNREADABLE;
  }

  const by = meta.metric_used === 'revenue' ? 'revenue' : 'units sold';
  let text =
    `By ${by}, ${window} the top seller is ${name}: ${units} ${plural(units, 'unit', 'units')} for ${revenue}.`;

  if (rows.length > 1) {
    const second = asRecord(rows[1]);
    const secondName = asString(second.name);
    const secondUnits = integer(second.units_sold);
    if (secondName !== null && secondUnits !== null) {
      text += ` Next is ${secondName} with ${secondUnits} ${plural(secondUnits, 'unit', 'units')}.`;
    }
  }

  return { text, understood: true };
}

function renderDeadStock(data: unknown, days: number): RenderedAnswer {
  const envelope = asRecord(data);
  const rows = asArray(envelope.rows);
  const meta = asRecord(envelope.meta);

  if (rows === null) {
    return UNREADABLE;
  }

  const quietDays = integer(meta.quiet_days) ?? days;

  if (rows.length === 0) {
    return {
      text: `Nothing has gone quiet in the last ${quietDays} days.`,
      understood: true,
    };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const qty = integer(first.total_qty);
  const value = money(first.stock_value_at_cost);
  const lastSold = asString(first.last_sold_on);

  if (name === null || qty === null || value === null) {
    return UNREADABLE;
  }

  return {
    text:
      `${rows.length} ${plural(rows.length, 'product has', 'products have')} stock that has not sold in ${quietDays} days. ` +
      `The most cash tied up is ${name}: ${qty} ${plural(qty, 'unit', 'units')} worth ${value} at cost, ` +
      `${lastSold === null ? 'never sold' : `last sold ${lastSold}`}.`,
    understood: true,
  };
}

/** An integer, or `null`. A numeric string counts; a fraction is not one. */
function integer(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) {
    return Number.parseInt(value.trim(), 10);
  }
  return null;
}

/** `₹` and two decimals, or `null` when the value is not a number. */
function money(value: unknown): string | null {
  const amount = typeof value === 'number'
    ? value
    : typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))
    ? Number(value)
    : null;
  return amount === null ? null : `₹${amount.toFixed(2)}`;
}

/** A non-empty string, or `null`. */
function asString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

/** An array, or `null` - never a silently empty one. */
function asArray(value: unknown): unknown[] | null {
  return Array.isArray(value) ? value : null;
}

/** A JSON object, or an empty one. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** `one` or `many`, chosen by [count]. */
function plural(count: number, one: string, many: string): string {
  return count === 1 ? one : many;
}
