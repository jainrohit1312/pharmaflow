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
  DEFAULT_ANSWER_LANGUAGE,
  DEFAULT_SUMMARY_SUBJECT,
  type AnswerLanguage,
  type ChatParams,
  type ClassificationChoice,
  type SummarySubject,
  type SupportedRpc,
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

/**
 * The horizon range both expiry reports accept - their own, from migrations 00027 and
 * 00029 (`least(greatest(coalesce(p_days, 90), 1), 3650)`).
 *
 * Repeated here for the same reason the two defaults above are: a horizon outside this
 * range is a horizon the report cannot have used, so `effectiveParams` replaces it with
 * the default rather than forwarding a number the report would clamp. That is what lets
 * the sentence state a horizon that is *true*.
 */
export const HORIZON_MIN_DAYS = 1;

/** The largest horizon the expiry reports accept. */
export const HORIZON_MAX_DAYS = 3650;

/** The smallest row cap any list report accepts. */
export const LIST_MIN_LIMIT = 1;

/**
 * The largest row cap this function will ask a list report for.
 *
 * Inside every list report's own maximum (200 for `low_stock_products` and
 * `top_products`, 500 for the other two), and deliberately one number rather than four:
 * what the chatbot does with a list is name its leader and count it, so a cap beyond
 * this buys a longer count of the same answer and costs four more rules that must agree
 * with four migrations.
 */
export const LIST_MAX_LIMIT = 200;

/** The cap the list reports take when none is given (mirrors 00027/00029's 50). */
export const LIST_DEFAULT_LIMIT = 50;

/** The cap `top_products` takes when none is given (mirrors 00029's 20). */
export const TOP_PRODUCTS_DEFAULT_LIMIT = 20;

/**
 * The parameters a report is run with, and the values its sentence is written from.
 *
 * **One object, both jobs**, because they must not be able to disagree. Before this, the
 * arguments were defaulted as they were built while the sentence was written from the
 * *declared* parameters - so a model that asked for a 5000-day horizon was told about
 * batches expiring "within 5000 days" while the report had quietly queried 3650. Reading
 * both from here makes that unrepresentable rather than merely unlikely.
 *
 * A day or row value outside the ranges above is **replaced by the report's default**
 * rather than forwarded to be clamped. A horizon the report could not have used is not a
 * horizon the caller meant, and replacing it is the only way the sentence can state a
 * number that is true. The reports keep their own clamp as the backstop for a caller that
 * does not come through here (a screen calling the RPC directly).
 */
export function effectiveParams(
  rpc: SupportedRpc,
  params: ChatParams,
): ChatParams {
  switch (rpc) {
    case 'report_summary':
      return params;
    case 'low_stock_products':
      return { ...params, limit: listLimit(params.limit, LIST_DEFAULT_LIMIT) };
    case 'expiring_batches':
      return {
        ...params,
        days: horizon(params.days, EXPIRING_DEFAULT_DAYS),
        limit: listLimit(params.limit, LIST_DEFAULT_LIMIT),
      };
    case 'top_products':
      return { ...params, limit: listLimit(params.limit, TOP_PRODUCTS_DEFAULT_LIMIT) };
    case 'dead_stock':
      return {
        ...params,
        days: horizon(params.days, DEAD_STOCK_DEFAULT_DAYS),
        limit: listLimit(params.limit, LIST_DEFAULT_LIMIT),
      };
  }
}

/** [days] when the expiry reports could have used it, and [fallback] otherwise. */
function horizon(days: number | null, fallback: number): number {
  return days !== null && days >= HORIZON_MIN_DAYS && days <= HORIZON_MAX_DAYS
    ? days
    : fallback;
}

/** [limit] when a list report could have used it, and [fallback] otherwise. */
function listLimit(limit: number | null, fallback: number): number {
  return limit !== null && limit >= LIST_MIN_LIMIT && limit <= LIST_MAX_LIMIT
    ? limit
    : fallback;
}

/**
 * Whether the report stopped at its cap, which makes the rows a *page* rather than the
 * whole answer.
 *
 * A `null` limit means no cap was named, so there is nothing to compare against and no
 * total may be claimed - the honest reading, and the only one available. Every path
 * through the handler names one ([effectiveParams]); this is reachable from a direct
 * call, which is what the tests do.
 */
function isCapped(rows: number, limit: number | null): boolean {
  return limit !== null && rows >= limit;
}

/** The fixed sentence for a question none of the reports answers, in each language. */
export const UNSUPPORTED: Sentence = {
  en: 'I cannot answer that. I can answer questions about sales and purchases, stock levels, expiring batches, what sells best, and what has stopped selling.',
  hinglish:
    'Ye main bata nahi sakta. Main sales aur purchase, stock levels, expire hone wale batches, sabse zyada bikne wala maal, aur jo bikhna band ho gaya hai - inke baare mein bata sakta hoon.',
};

/**
 * One sentence, in every language this file can say it in.
 *
 * A sentence is a **map keyed by [AnswerLanguage]** rather than a branch inside the
 * sentence's own function, for one reason: *the compiler counts the languages, a person does
 * not.* A missing key is a type error, so adding Hindi script later cannot leave an English
 * sentence quietly standing in for it - which is the failure a language feature ships with
 * when nothing checks it. (That is also why the Hinglish key is spelled out at every
 * sentence instead of a fallback: falling back is exactly the silent English sentence.)
 *
 * The English half of every one of these is **byte-identical to the sentence this file wrote
 * before it could speak Hinglish**, so nothing about an English answer changed.
 */
type Sentence = Record<AnswerLanguage, string>;

/** The report [rpc] returned; [text] is what the caller reads, in [language]. */
export function renderAnswer(
  rpc: ClassificationChoice,
  data: unknown,
  params: ChatParams,
  language: AnswerLanguage = DEFAULT_ANSWER_LANGUAGE,
): RenderedAnswer {
  switch (rpc) {
    case 'report_summary':
      return renderSummary(data, params.subject ?? DEFAULT_SUMMARY_SUBJECT, language);
    case 'low_stock_products':
      return renderLowStock(data, params.limit, language);
    case 'expiring_batches':
      return renderExpiring(
        data,
        params.days ?? EXPIRING_DEFAULT_DAYS,
        params.limit,
        language,
      );
    case 'top_products':
      return renderTopProducts(data, language);
    case 'dead_stock':
      return renderDeadStock(
        data,
        params.days ?? DEAD_STOCK_DEFAULT_DAYS,
        params.limit,
        language,
      );
    case 'unsupported':
      return { text: UNSUPPORTED[language], understood: true };
  }
}

/** A refusal to render an envelope in an unexpected shape. */
const UNREADABLE: Record<AnswerLanguage, RenderedAnswer> = {
  en: {
    text: 'That report ran, but its answer came back in a shape this app does not understand.',
    understood: false,
  },
  hinglish: {
    text: 'Report chal gayi, lekin uska jawab aisi shape mein aaya jo ye app samajh nahi sakta.',
    understood: false,
  },
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
function renderSummary(
  data: unknown,
  subject: SummarySubject,
  language: AnswerLanguage,
): RenderedAnswer {
  const envelope = asRecord(data);
  const from = asString(envelope.from);
  const to = asString(envelope.to);
  // The period, as each language says it. A section that has no period - `stock` - never
  // reads this, so an absent window cannot leak a date range into a sentence about now.
  const window: Sentence = {
    en: from !== null && to !== null ? `Between ${from} and ${to}: ` : '',
    hinglish: from !== null && to !== null ? `${from} se ${to} tak: ` : '',
  };

  switch (subject) {
    case 'sales':
      return renderSalesSection(envelope, window[language], language);
    case 'purchases':
      return renderPurchasesSection(envelope, window[language], language);
    case 'returns':
      return renderReturnsSection(envelope, window[language], language);
    case 'expenses':
      return renderExpensesSection(envelope, window[language], language);
    case 'stock':
      return renderStockSection(envelope, language);
    case 'everything':
      return renderEverything(envelope, window[language], language);
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
  language: AnswerLanguage,
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
    return UNREADABLE[language];
  }

  const nothing: Sentence = {
    en: `${window}Nothing was billed.`,
    hinglish: `${window}Koi bill nahi bana.`,
  };
  if (count === 0) {
    return { text: nothing[language], understood: true };
  }

  const text: Sentence = {
    en:
      `${window}${count} ${plural(count, 'sale', 'sales')} for **${grandTotal}** - ` +
      `**${subTotal}** of it before tax and **${taxTotal}** tax. ` +
      `${collected} collected and **${outstanding}** still due.`,
    hinglish:
      `${window}${count} ${plural(count, 'bill bana', 'bill bane')} - total **${grandTotal}**, ` +
      `jisme **${subTotal}** tax se pehle aur **${taxTotal}** tax hai. ` +
      `**${collected}** mil gaye, **${outstanding}** abhi baaki hai.`,
  };

  return { text: text[language], understood: true };
}

/** What was bought in, and how much of the bill was tax. */
function renderPurchasesSection(
  envelope: Record<string, unknown>,
  window: string,
  language: AnswerLanguage,
): RenderedAnswer {
  const purchases = asRecord(envelope.purchases);
  const count = integer(purchases.count);
  const grandTotal = money(purchases.grand_total);
  const taxTotal = money(purchases.tax_total);

  if (count === null || grandTotal === null || taxTotal === null) {
    return UNREADABLE[language];
  }

  const nothing: Sentence = {
    en: `${window}No purchases were received.`,
    hinglish: `${window}Koi purchase receive nahi hua.`,
  };
  if (count === 0) {
    return { text: nothing[language], understood: true };
  }

  const text: Sentence = {
    en:
      `${window}${count} ${plural(count, 'purchase was', 'purchases were')} received ` +
      `for **${grandTotal}**, of which **${taxTotal}** is tax.`,
    hinglish:
      `${window}${count} purchase receive hue, total **${grandTotal}** ka - ` +
      `jisme **${taxTotal}** tax hai.`,
  };

  return { text: text[language], understood: true };
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
  language: AnswerLanguage,
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
    return UNREADABLE[language];
  }

  const nothing: Sentence = {
    en: `${window}Nothing came back - no sale returns and no purchase returns.`,
    hinglish: `${window}Kuch bhi wapas nahi aaya - na koi sale return, na koi purchase return.`,
  };
  if (saleCount === 0 && purchaseCount === 0) {
    return { text: nothing[language], understood: true };
  }

  const fromCustomers: Sentence = {
    en: saleCount === 0
      ? 'No sales came back'
      : `**${saleTotal}** of sales came back over ${saleCount} ${
        plural(saleCount, 'sale return', 'sale returns')
      }`,
    hinglish: saleCount === 0
      ? 'Customer se kuch wapas nahi aaya'
      : `customer se **${saleTotal}** ka maal wapas aaya (${saleCount} sale return)`,
  };
  const toSuppliers: Sentence = {
    en: purchaseCount === 0
      ? 'nothing went back to a supplier'
      : `**${purchaseTotal}** went back to suppliers over ${purchaseCount} ${
        plural(purchaseCount, 'purchase return', 'purchase returns')
      }`,
    hinglish: purchaseCount === 0
      ? 'supplier ko kuch wapas nahi gaya'
      : `supplier ko **${purchaseTotal}** ka maal wapas gaya (${purchaseCount} purchase return)`,
  };

  const text: Sentence = {
    en: `${window}${fromCustomers.en}, and ${toSuppliers.en}.`,
    hinglish: `${window}${fromCustomers.hinglish}, aur ${toSuppliers.hinglish}.`,
  };

  return { text: text[language], understood: true };
}

/** What the owner spent, over and above what he bought for stock. */
function renderExpensesSection(
  envelope: Record<string, unknown>,
  window: string,
  language: AnswerLanguage,
): RenderedAnswer {
  const expenses = asRecord(envelope.expenses);
  const count = integer(expenses.count);
  const total = money(expenses.total);

  if (count === null || total === null) {
    return UNREADABLE[language];
  }

  const nothing: Sentence = {
    en: `${window}No expenses were recorded.`,
    hinglish: `${window}Koi kharch record nahi hua.`,
  };
  if (count === 0) {
    return { text: nothing[language], understood: true };
  }

  const text: Sentence = {
    en: `${window}${count} ${
      plural(count, 'expense was', 'expenses were')
    } recorded, totalling **${total}**.`,
    hinglish: `${window}${count} kharch record hue, total **${total}**.`,
  };

  return { text: text[language], understood: true };
}

/**
 * What is on the shelf - and *now* is the point, which is why this one takes no period.
 *
 * `product_stock` is a live view of the batches, so the figure is today's whatever
 * period the question mentioned. Saying so is the whole job of this sentence: an owner
 * asking "how much stock do I have" after a question about September should not be shown
 * one number that claims to be both.
 */
function renderStockSection(
  envelope: Record<string, unknown>,
  language: AnswerLanguage,
): RenderedAnswer {
  const stock = asRecord(envelope.stock);
  const products = integer(stock.products);
  const units = integer(stock.units);
  const atCost = money(stock.value_at_cost);
  const atMrp = money(stock.value_at_mrp);

  if (products === null || units === null || atCost === null || atMrp === null) {
    return UNREADABLE[language];
  }

  const text: Sentence = {
    en:
      `Stock on hand now is worth **${atCost}** at cost: ${units} ${
        plural(units, 'unit', 'units')
      } across ${products} ${plural(products, 'product', 'products')}, ` +
      `and **${atMrp}** at MRP.`,
    hinglish:
      `Abhi stock ki value cost par **${atCost}** hai: ${units} unit, ${products} product - ` +
      `aur MRP par **${atMrp}**.`,
  };

  return { text: text[language], understood: true };
}

/** The broad question: one line on each of the three things an owner checks first. */
function renderEverything(
  envelope: Record<string, unknown>,
  window: string,
  language: AnswerLanguage,
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
    return UNREADABLE[language];
  }

  const text: Sentence = {
    en:
      `${window}${count} ${plural(count, 'sale', 'sales')} for **${grandTotal}**, ` +
      `${collected} collected and **${outstanding}** still due. ` +
      `${purchaseCount} ${plural(purchaseCount, 'purchase was', 'purchases were')} received. ` +
      `Stock on hand is worth **${stockValue}** at cost.`,
    hinglish:
      `${window}${count} ${plural(count, 'bill bana', 'bill bane')}, total **${grandTotal}** - ` +
      `**${collected}** mil gaye, **${outstanding}** abhi baaki hai. ` +
      `${purchaseCount} purchase receive hue. ` +
      `Stock cost par **${stockValue}** ka hai.`,
  };

  return { text: text[language], understood: true };
}

/**
 * What is running out, worst first.
 *
 * [limit] is the cap the report was actually asked for, and it is here for one reason: a
 * capped list is a *page*, and "2 products are below their reorder level" is a claim about
 * the whole catalogue that a capped list cannot support. When the page came back full the
 * sentence says "at least", which is true whether or not there is a row behind it.
 */
function renderLowStock(
  data: unknown,
  limit: number | null,
  language: AnswerLanguage,
): RenderedAnswer {
  const rows = asArray(data);
  if (rows === null) {
    return UNREADABLE[language];
  }
  if (rows.length === 0) {
    const quiet: Sentence = {
      en: 'Nothing is below its reorder level.',
      hinglish: 'Koi bhi product apne reorder level se neeche nahi hai.',
    };
    return { text: quiet[language], understood: true };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const shortfall = integer(first.shortfall);
  const totalQty = integer(first.total_qty);
  const level = integer(first.min_stock_level);

  if (name === null || shortfall === null || totalQty === null || level === null) {
    return UNREADABLE[language];
  }

  const capped = isCapped(rows.length, limit);
  const atLeast: Sentence = {
    en: capped ? 'At least ' : '',
    hinglish: capped ? 'Kam se kam ' : '',
  };

  const text: Sentence = {
    en:
      `${atLeast.en}${rows.length} ${
        plural(
          rows.length,
          'product is below its reorder level',
          'products are below their reorder level',
        )
      }. ` +
      `The biggest gap is **${name}**: **${shortfall} ${plural(shortfall, 'unit', 'units')} short** ` +
      `(${totalQty} in stock against a level of ${level}).`,
    hinglish:
      `${atLeast.hinglish}${rows.length} ${
        plural(
          rows.length,
          'product apne reorder level se neeche hai',
          'products apne reorder level se neeche hain',
        )
      }. ` +
      `Sabse badi kami **${name}** mein hai: **${shortfall} unit kam** ` +
      `(stock ${totalQty}, level ${level}).`,
  };

  return { text: text[language], understood: true };
}

/**
 * What is about to go off, soonest first.
 *
 * [days] is the horizon the report was asked for and [limit] the cap it was asked for, both
 * as `effectiveParams` resolved them - so the horizon in this sentence is the horizon the
 * query used, and a full page is described as a page rather than as the whole list.
 */
function renderExpiring(
  data: unknown,
  days: number,
  limit: number | null,
  language: AnswerLanguage,
): RenderedAnswer {
  const rows = asArray(data);
  if (rows === null) {
    return UNREADABLE[language];
  }
  if (rows.length === 0) {
    const quiet: Sentence = {
      en: `No batches expire within ${days} days.`,
      hinglish: `${days} din mein koi batch expire nahi ho raha.`,
    };
    return { text: quiet[language], understood: true };
  }

  const first = asRecord(rows[0]);
  const product = asString(first.product_name);
  const batchNo = asString(first.batch_no);
  const daysLeft = integer(first.days_left);
  const qty = integer(first.qty);
  const expiryDate = asString(first.expiry_date);

  if (product === null || daysLeft === null || qty === null) {
    return UNREADABLE[language];
  }

  // Both halves are the answer's point - "6 days left" on the one you can still
  // move, "already expired" on the one that is already a loss - so both are marked.
  const when: Sentence = {
    en: daysLeft < 0
      ? `**already expired ${Math.abs(daysLeft)} ${plural(Math.abs(daysLeft), 'day', 'days')} ago**`
      : `**${daysLeft} ${plural(daysLeft, 'day', 'days')} left**`,
    hinglish: daysLeft < 0
      ? `**${Math.abs(daysLeft)} din pehle expire ho gaya**`
      : `**${daysLeft} din bache hain**`,
  };

  const capped = isCapped(rows.length, limit);
  const atLeast: Sentence = {
    en: capped ? 'At least ' : '',
    hinglish: capped ? 'Kam se kam ' : '',
  };

  const batch = batchNo !== null ? ` batch ${batchNo}` : '';
  const on = expiryDate !== null ? ` (${expiryDate})` : '';

  const text: Sentence = {
    en:
      `${atLeast.en}${rows.length} ${plural(rows.length, 'batch expires', 'batches expire')} within ${days} days. ` +
      `The soonest is **${product}**${batch}, ${when.en}${on} - ${qty} ${plural(qty, 'unit', 'units')} on the shelf.`,
    hinglish:
      `${atLeast.hinglish}${rows.length} batch ${days} din mein expire ho rahe hain. ` +
      `Sabse pehle **${product}**${batch} - ${when.hinglish}${on} - shelf par ${qty} unit.`,
  };

  return { text: text[language], understood: true };
}

/**
 * What sells best, in the window the report itself stated.
 *
 * No cap is taken, because this sentence claims no total: it names the winner and the
 * runner-up, and "the top seller is Dolo 650" is true of a page and of the whole list
 * alike. A sentence here that ever *counts* will need one - the way the three list
 * sentences above do - and that is the point at which it should be added.
 */
function renderTopProducts(
  data: unknown,
  language: AnswerLanguage,
): RenderedAnswer {
  const envelope = asRecord(data);
  const rows = asArray(envelope.rows);
  const meta = asRecord(envelope.meta);

  if (rows === null) {
    return UNREADABLE[language];
  }

  const from = asString(meta.window_from);
  const to = asString(meta.window_to);
  const window: Sentence = {
    en: from !== null && to !== null ? `between ${from} and ${to}` : 'in that window',
    hinglish: from !== null && to !== null ? `${from} se ${to} ke beech` : 'us period mein',
  };

  if (rows.length === 0) {
    const quiet: Sentence = {
      en: `Nothing sold ${window.en}.`,
      hinglish: `${window.hinglish} kuch nahi bika.`,
    };
    return { text: quiet[language], understood: true };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const units = integer(first.units_sold);
  const revenue = money(first.revenue);

  if (name === null || units === null || revenue === null) {
    return UNREADABLE[language];
  }

  const by: Sentence = {
    en: `By ${meta.metric_used === 'revenue' ? 'revenue' : 'units sold'}, `,
    hinglish: `${meta.metric_used === 'revenue' ? 'Revenue' : 'Units'} ke hisaab se, `,
  };

  const text: Sentence = {
    en:
      `${by.en}${window.en} the top seller is **${name}**: **${units} ${
        plural(units, 'unit', 'units')
      }** for **${revenue}**.`,
    hinglish:
      `${by.hinglish}${window.hinglish} sabse zyada bikne wala **${name}** hai: ` +
      `**${units} unit**, **${revenue}** ka.`,
  };

  if (rows.length > 1) {
    const second = asRecord(rows[1]);
    const secondName = asString(second.name);
    const secondUnits = integer(second.units_sold);
    if (secondName !== null && secondUnits !== null) {
      text.en += ` Next is ${secondName} with ${secondUnits} ${plural(secondUnits, 'unit', 'units')}.`;
      text.hinglish += ` Uske baad ${secondName}, ${secondUnits} unit.`;
    }
  }

  return { text: text[language], understood: true };
}

/**
 * Money sitting on a shelf, most of it first.
 *
 * [days] comes from the report's own `meta` when it is there (`quiet_days`), because that is
 * the number the query used; [limit] is the cap it was asked for, and a full page is again
 * described as a page.
 */
function renderDeadStock(
  data: unknown,
  days: number,
  limit: number | null,
  language: AnswerLanguage,
): RenderedAnswer {
  const envelope = asRecord(data);
  const rows = asArray(envelope.rows);
  const meta = asRecord(envelope.meta);

  if (rows === null) {
    return UNREADABLE[language];
  }

  const quietDays = integer(meta.quiet_days) ?? days;

  if (rows.length === 0) {
    const quiet: Sentence = {
      en: `Nothing has gone quiet in the last ${quietDays} days.`,
      hinglish: `Pichhle ${quietDays} din mein kuch bhi nahi bika.`,
    };
    return { text: quiet[language], understood: true };
  }

  const first = asRecord(rows[0]);
  const name = asString(first.name);
  const qty = integer(first.total_qty);
  const value = money(first.stock_value_at_cost);
  const lastSold = asString(first.last_sold_on);

  if (name === null || qty === null || value === null) {
    return UNREADABLE[language];
  }

  const capped = isCapped(rows.length, limit);
  const atLeast: Sentence = {
    en: capped ? 'At least ' : '',
    hinglish: capped ? 'Kam se kam ' : '',
  };

  const sold: Sentence = {
    en: lastSold === null ? 'never sold' : `last sold ${lastSold}`,
    hinglish: lastSold === null ? 'kabhi nahi bika' : `aakhri baar ${lastSold} ko bika`,
  };

  const text: Sentence = {
    en:
      `${atLeast.en}${rows.length} ${plural(rows.length, 'product has', 'products have')} stock that has not sold in ${quietDays} days. ` +
      `The most cash tied up is **${name}**: ${qty} ${plural(qty, 'unit', 'units')} worth **${value}** at cost, ` +
      `${sold.en}.`,
    hinglish:
      `${atLeast.hinglish}${rows.length} product ka maal ${quietDays} din se nahi bika. ` +
      `Sabse zyada paisa **${name}** mein atka hai: ${qty} unit, cost par **${value}** - ${sold.hinglish}.`,
  };

  return { text: text[language], understood: true };
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
