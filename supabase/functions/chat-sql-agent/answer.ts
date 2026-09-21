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
 *
 * The emphasis marker
 * -------------------
 * A sentence marks the part worth pointing at with `**...**`: the figure an owner
 * would circle, the product or batch that figure belongs to, and any exception
 * ("already expired 6 days ago"). The alternative - a paragraph of uniform text -
 * is what this feature was reported for: the important number is in there, and
 * nobody can find it.
 *
 * **The marker is written here, and only here.** It is presentation syntax, but it
 * is the *server's* presentation syntax: the words and the figures are still this
 * file's, and the client's only job (see `answer_emphasis.dart`) is to turn a
 * marker into a bold run. Nothing on the client decides *what* is worth pointing
 * at, which is what keeps D-053 true while the answer becomes readable.
 *
 * A sentence with nothing to point at carries **no** marker: the four "nothing is
 * low / expiring / sold / quiet" answers, `UNSUPPORTED_ANSWER` and `UNREADABLE` are
 * plain prose on purpose, so a marker always means *there is a finding here*. That
 * is asserted, both ways, in `answer_test.ts`.
 *
 * The marker travels with the sentence, so the conversation history the classifier
 * is handed carries it too. That is deliberate rather than overlooked: the history
 * is context, the model returns only a choice and its parameters, and stripping the
 * marker for one reader while rendering it for another would be a second copy of
 * the sentence waiting to drift. It is also why the two money figures in a summary
 * are the *only* ones marked there - a marker that appears everywhere points at
 * nothing.
 */

import {
  DEFAULT_SUMMARY_SUBJECT,
  type ChatParams,
  type ClassificationChoice,
  type SummarySubject,
} from './schema.ts';

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
      return renderSummary(data, params.subject ?? DEFAULT_SUMMARY_SUBJECT);
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

/**
 * The summary sentence the question actually asked for.
 *
 * `report_summary` answers with five sections in one round trip (migration 00021) and
 * this file used to read four figures out of `sales`, and one out of `stock`, whatever
 * the question was about - which is what "every summary sounds the same" was. So the
 * sentence is chosen by [subject]: the part of the envelope the model said the question
 * named, and each of them states its own section's figures and nothing else.
 *
 * Two rules hold across all six:
 *
 *   - **The period belongs only where there is one.** Sales, purchases, returns and
 *     expenses happened *in* it. `stock` is what is on the shelf **now**, so it takes no
 *     period at all - prefixing it with a date range would say the shelf is where it was
 *     in September, which is the same error as reading today's stock inside a historical
 *     report.
 *   - **A section this file cannot read is [UNREADABLE]**, never a sentence with holes in
 *     it.
 *
 * `everything` is the broad question and the default, and it reads exactly as this
 * sentence always did - so a classifier that names no subject changes nothing.
 */
function renderSummary(data: unknown, subject: SummarySubject): RenderedAnswer {
  const envelope = asRecord(data);
  const from = asString(envelope.from);
  const to = asString(envelope.to);
  const window = from !== null && to !== null ? `Between ${from} and ${to}: ` : '';

  switch (subject) {
    case 'sales':
      return renderSalesSection(envelope, window);
    case 'purchases':
      return renderPurchasesSection(envelope, window);
    case 'returns':
      return renderReturnsSection(envelope, window);
    case 'expenses':
      return renderExpensesSection(envelope, window);
    case 'stock':
      return renderStockSection(envelope);
    case 'everything':
      return renderEverything(envelope, window);
  }
}

/**
 * The money on the counter, and what of it is not the pharmacy's.
 *
 * `sub_total` and `tax_total` have been in this envelope since `00021` and no sentence
 * had ever read them, which is a good part of why every summary looked alike: the same
 * four figures answered every question about the period.
 */
function renderSalesSection(
  envelope: Record<string, unknown>,
  window: string,
): RenderedAnswer {
  const sales = asRecord(envelope.sales);
  const count = integer(sales.count);
  const grandTotal = money(sales.grand_total);
  const subTotal = money(sales.sub_total);
  const taxTotal = money(sales.tax_total);
  const collected = money(sales.collected);
  const outstanding = money(sales.outstanding);

  if (
    count === null || grandTotal === null || subTotal === null ||
    taxTotal === null || collected === null || outstanding === null
  ) {
    return UNREADABLE;
  }

  if (count === 0) {
    return { text: `${window}Nothing was billed.`, understood: true };
  }

  return {
    text:
      `${window}${count} ${plural(count, 'sale', 'sales')} for **${grandTotal}** - ` +
      `**${subTotal}** of it before tax and **${taxTotal}** tax. ` +
      `${collected} collected and **${outstanding}** still due.`,
    understood: true,
  };
}

/** What was bought in, and how much of the bill was tax. */
function renderPurchasesSection(
  envelope: Record<string, unknown>,
  window: string,
): RenderedAnswer {
  const purchases = asRecord(envelope.purchases);
  const count = integer(purchases.count);
  const grandTotal = money(purchases.grand_total);
  const taxTotal = money(purchases.tax_total);

  if (count === null || grandTotal === null || taxTotal === null) {
    return UNREADABLE;
  }

  if (count === 0) {
    return { text: `${window}No purchases were received.`, understood: true };
  }

  return {
    text:
      `${window}${count} ${plural(count, 'purchase was', 'purchases were')} received ` +
      `for **${grandTotal}**, of which **${taxTotal}** is tax.`,
    understood: true,
  };
}

/**
 * What came back, both ways.
 *
 * A return is a credit note whichever direction it went (D-046's own reading of the
 * envelope), so the two are stated together and neither is netted off the sales above:
 * a customer return and a supplier return are not the same subtraction, and the report
 * keeps them apart for the same reason.
 */
function renderReturnsSection(
  envelope: Record<string, unknown>,
  window: string,
): RenderedAnswer {
  const returns = asRecord(envelope.returns);
  const saleCount = integer(returns.sale_count);
  const saleTotal = money(returns.sale_total);
  const purchaseCount = integer(returns.purchase_count);
  const purchaseTotal = money(returns.purchase_total);

  if (
    saleCount === null || saleTotal === null ||
    purchaseCount === null || purchaseTotal === null
  ) {
    return UNREADABLE;
  }

  if (saleCount === 0 && purchaseCount === 0) {
    return {
      text: `${window}Nothing came back - no sale returns and no purchase returns.`,
      understood: true,
    };
  }

  const fromCustomers = saleCount === 0
    ? 'No sales came back'
    : `**${saleTotal}** of sales came back over ${saleCount} ${
      plural(saleCount, 'sale return', 'sale returns')
    }`;
  const toSuppliers = purchaseCount === 0
    ? 'nothing went back to a supplier'
    : `**${purchaseTotal}** went back to suppliers over ${purchaseCount} ${
      plural(purchaseCount, 'purchase return', 'purchase returns')
    }`;

  return { text: `${window}${fromCustomers}, and ${toSuppliers}.`, understood: true };
}

/** What the owner spent, over and above what he bought for stock. */
function renderExpensesSection(
  envelope: Record<string, unknown>,
  window: string,
): RenderedAnswer {
  const expenses = asRecord(envelope.expenses);
  const count = integer(expenses.count);
  const total = money(expenses.total);

  if (count === null || total === null) {
    return UNREADABLE;
  }

  if (count === 0) {
    return { text: `${window}No expenses were recorded.`, understood: true };
  }

  return {
    text: `${window}${count} ${
      plural(count, 'expense was', 'expenses were')
    } recorded, totalling **${total}**.`,
    understood: true,
  };
}

/**
 * What is on the shelf - and *now* is the point, which is why this one takes no period.
 *
 * `product_stock` is a live view of the batches, so the figure is today's whatever
 * period the question mentioned. Saying so is the whole job of this sentence: an owner
 * asking "how much stock do I have" after a question about September should not be shown
 * one number that claims to be both.
 */
function renderStockSection(envelope: Record<string, unknown>): RenderedAnswer {
  const stock = asRecord(envelope.stock);
  const products = integer(stock.products);
  const units = integer(stock.units);
  const atCost = money(stock.value_at_cost);
  const atMrp = money(stock.value_at_mrp);

  if (products === null || units === null || atCost === null || atMrp === null) {
    return UNREADABLE;
  }

  return {
    text:
      `Stock on hand now is worth **${atCost}** at cost: ${units} ${
        plural(units, 'unit', 'units')
      } across ${products} ${plural(products, 'product', 'products')}, ` +
      `and **${atMrp}** at MRP.`,
    understood: true,
  };
}

/** The broad question: one line on each of the three things an owner checks first. */
function renderEverything(
  envelope: Record<string, unknown>,
  window: string,
): RenderedAnswer {
  const sales = asRecord(envelope.sales);
  const purchases = asRecord(envelope.purchases);
  const stock = asRecord(envelope.stock);

  const count = integer(sales.count);
  const grandTotal = money(sales.grand_total);
  const collected = money(sales.collected);
  const outstanding = money(sales.outstanding);
  const purchaseCount = integer(purchases.count);
  const stockValue = money(stock.value_at_cost);

  if (
    count === null || grandTotal === null || collected === null ||
    outstanding === null || purchaseCount === null || stockValue === null
  ) {
    return UNREADABLE;
  }

  return {
    text:
      `${window}${count} ${plural(count, 'sale', 'sales')} for **${grandTotal}**, ` +
      `${collected} collected and **${outstanding}** still due. ` +
      `${purchaseCount} ${plural(purchaseCount, 'purchase was', 'purchases were')} received. ` +
      `Stock on hand is worth **${stockValue}** at cost.`,
    understood: true,
  };
}

function renderLowStock(data: unknown): RenderedAnswer {
  const rows = asArray(data);
  if (rows === null) {
    return UNREADABLE;
  }
  if (rows.length === 0) {
    return { text: 'Nothing is below its reorder level.', understood: true };
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
      `${rows.length} ${
        plural(
          rows.length,
          'product is below its reorder level',
          'products are below their reorder level',
        )
      }. ` +
      `The biggest gap is **${name}**: **${shortfall} ${plural(shortfall, 'unit', 'units')} short** ` +
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

  // Both halves are the answer's point - "6 days left" on the one you can still
  // move, "already expired" on the one that is already a loss - so both are marked.
  const when = daysLeft < 0
    ? `**already expired ${Math.abs(daysLeft)} ${plural(Math.abs(daysLeft), 'day', 'days')} ago**`
    : `**${daysLeft} ${plural(daysLeft, 'day', 'days')} left**`;

  return {
    text:
      `${rows.length} ${plural(rows.length, 'batch expires', 'batches expire')} within ${days} days. ` +
      `The soonest is **${product}**${batchNo !== null ? ` batch ${batchNo}` : ''}, ${when}` +
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
  // The winner's identity and both of its figures are the answer, so all three are
  // marked - and only in this clause: the runner-up is context, and marking it too
  // would leave nothing for the marker to point at.
  let text =
    `By ${by}, ${window} the top seller is **${name}**: **${units} ${plural(units, 'unit', 'units')}** for **${revenue}**.`;

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
      `The most cash tied up is **${name}**: ${qty} ${plural(qty, 'unit', 'units')} worth **${value}** at cost, ` +
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
