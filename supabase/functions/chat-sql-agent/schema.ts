/**
 * The one model call the chatbot is allowed to make, and the closed set it
 * chooses from.
 *
 * D-026 is the constraint this file exists for: the chatbot answers through
 * parameterised RPCs and **never generates SQL**. D-053 extends it - the model
 * never produces a numeral either. So this module asks the model exactly one
 * question ("which of these five reports answers this, and with what
 * parameters?") and nothing else, and the answer is read out of the report the
 * function then runs (see `answer.ts`).
 *
 * The closed set is enforced by the *request*, not by the prompt: the
 * `responseSchema` carries an `enum` of the five names plus `unsupported`, so the
 * model cannot return a sixth. A whitelist in a prompt is a suggestion; an enum
 * in a response schema is a contract. The prompt below still explains what each
 * one means, because the model has to choose well, not merely legally.
 *
 * The model's *name* is named in code and overridable by an environment variable
 * (D-030): a model that rots is one line, and changing it needs no redeploy. The
 * default is the same family the bill reader was verified against live.
 */

import { FunctionError } from '../_shared/errors.ts';

/** The text model, unless a deployment overrides it (D-030). */
export const DEFAULT_CHAT_MODEL = 'gemini-3.6-flash';

/** The API this project talks to. */
export const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta';

/**
 * Enough for the thinking this model family does before answering, plus the
 * handful of bytes of JSON that are the answer. The classification is tiny, but
 * the reasoning budget shares this cap, and a truncated answer is a bug that
 * looks like a model failure.
 */
export const MAX_OUTPUT_TOKENS = 2048;

/** How many earlier turns are carried into the prompt. */
export const MAX_HISTORY_TURNS = 6;

/** The five aggregates the chatbot may call (D-026, migration 00029's two added). */
export const SUPPORTED_RPCS = [
  'report_summary',
  'low_stock_products',
  'expiring_batches',
  'top_products',
  'dead_stock',
] as const;

/** One of the five, as a type. */
export type SupportedRpc = (typeof SUPPORTED_RPCS)[number];

/**
 * What the model is allowed to choose.
 *
 * `unsupported` is a real answer: D-026 says a question the aggregates cannot
 * answer is answered with "I cannot answer that", and the model needs a way to
 * say so that is not an error. It is a *choice*, so it is in the enum.
 */
export const CLASSIFICATION_CHOICES = [...SUPPORTED_RPCS, 'unsupported'] as const;

/** What the model chose. */
export type ClassificationChoice = (typeof CLASSIFICATION_CHOICES)[number];

/**
 * What a summary leads with: the one part of `report_summary`'s envelope the
 * question is actually about.
 *
 * `report_summary` answers with every total the reports screen shows - sales,
 * purchases, returns, expenses and stock - in one round trip (migration 00021). The
 * sentence, though, read four figures out of `sales` and one out of `stock`, for
 * every question asked of it, which is what "every summary sounds the same" meant in
 * practice: a question about what came back from customers got the sales paragraph, a
 * question about the stock got the sales paragraph with a stock clause on the end.
 *
 * So the model declares the *subject* and the sentence is chosen by it. This is one
 * more parameter rather than one more report: the report is the same envelope, the
 * figures are the same figures, and nothing about the answer is different except
 * which of them a reader is shown first. It is the same idea the system instruction
 * already applied *between* reports - "choose the one whose subject the question
 * names" - applied inside one.
 *
 * `everything` is the broad question ("how did last month go?") and the default, and
 * it reads exactly as the sentence always did, so a classifier that names no subject
 * changes nothing.
 */
export const SUMMARY_SUBJECTS = [
  'sales',
  'purchases',
  'returns',
  'expenses',
  'stock',
  'everything',
] as const;

/** One of the five subjects, or the broad tour. */
export type SummarySubject = (typeof SUMMARY_SUBJECTS)[number];

/** What a summary leads with when the model names nothing. */
export const DEFAULT_SUMMARY_SUBJECT: SummarySubject = 'everything';

/**
 * The languages a sentence can be written in.
 *
 * **Not a parameter the model fills** - it is the CALLER's choice, like the question
 * itself, and it arrives on the request body rather than in the classification. That is
 * deliberate: which report answers a question does not depend on the language the question
 * was asked in, so the one model call is untouched by this, and no language can influence
 * which figures are read. It only chooses which of `answer.ts`'s sentences gets written.
 *
 * Hinglish - Hindi in Roman script, with the business nouns left in English - is first
 * because it is how this owner writes. Hindi script is not here yet, and when it is added,
 * **every sentence in `answer.ts` fails to compile until it has one**: the sentence tables
 * there are typed by this union, so a missing language is a type error rather than an
 * English sentence in disguise.
 */
export const ANSWER_LANGUAGES = ['en', 'hinglish'] as const;

/** One of the languages a sentence can be written in. */
export type AnswerLanguage = (typeof ANSWER_LANGUAGES)[number];

/** What a sentence is written in when the caller names nothing. */
export const DEFAULT_ANSWER_LANGUAGE: AnswerLanguage = 'en';

/** The parameters the model may fill, whatever report it chose. */
export interface ChatParams {
  /** `YYYY-MM-DD`, for `report_summary` and `top_products`. */
  fromDate: string | null;
  /** `YYYY-MM-DD`, for `report_summary` and `top_products`. */
  toDate: string | null;
  /** A horizon in days, for `expiring_batches` and `dead_stock`. */
  days: number | null;
  /** A row cap, for any of them. */
  limit: number | null;
  /** Which ranking `top_products` should use. */
  metric: 'units' | 'revenue' | null;
  /**
   * What a `report_summary` leads with.
   *
   * Not a report argument: `report_summary` takes a period and answers with every
   * section, so this decides which section the *sentence* opens with and never
   * travels to the database. `paramsFor` therefore drops it, and the envelope's
   * `params` - "the arguments the report actually ran with" - is right to omit it.
   */
  subject: SummarySubject | null;
}

/** The model's whole answer: a choice, and the parameters it declared. */
export interface Classification {
  rpc: ClassificationChoice;
  params: ChatParams;
}

/** One earlier turn, as the caller sent it. */
export interface ChatTurn {
  role: 'user' | 'model';
  text: string;
}

/**
 * The shape the model must answer in.
 *
 * Every parameter is optional and flat, rather than a nested object per report:
 * Gemini's schema language is a subset of OpenAPI, and one flat set of declared
 * fields is both expressible and easy to validate. `paramsFor` then hands each
 * report only the fields it takes, so the model cannot smuggle an argument into a
 * report that has no such parameter.
 */
export const CLASSIFICATION_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    rpc: {
      type: 'STRING',
      enum: [...CLASSIFICATION_CHOICES],
      description:
        'Which of the pharmacy’s reports answers the question, or "unsupported".',
    },
    from_date: {
      type: 'STRING',
      description: 'Start of a date range, as YYYY-MM-DD.',
    },
    to_date: {
      type: 'STRING',
      description: 'End of a date range, as YYYY-MM-DD.',
    },
    days: {
      type: 'INTEGER',
      description: 'A horizon in days, for expiring batches or dead stock.',
    },
    limit: {
      type: 'INTEGER',
      description: 'The most rows to return.',
    },
    metric: {
      type: 'STRING',
      enum: ['units', 'revenue'],
      description: 'How to rank the best sellers.',
    },
    subject: {
      type: 'STRING',
      enum: [...SUMMARY_SUBJECTS],
      description:
        'For a summary: the one part of the business the question is about, or "everything".',
    },
  },
  required: ['rpc'],
};

/**
 * What the model is told it is doing.
 *
 * Two jobs: describe the five reports well enough to choose between them, and
 * say plainly that the model does not answer with figures. The enum makes the
 * second structurally true; this makes it understood, so the model does not try
 * to be helpful by inventing a number inside the parameters.
 */
export const SYSTEM_INSTRUCTION = [
  'You choose which one of a pharmacy’s fixed reports answers a question.',
  'You never write SQL, and you never state a figure.',
  '',
  'Choose exactly one `rpc`:',
  '- report_summary: totals for a date range - sales, purchases, returns, expenses, stock value. Parameters: from_date, to_date, subject.',
  '- low_stock_products: what is at or below its reorder level. Parameters: limit.',
  '- expiring_batches: batches expiring within a horizon. Parameters: days, limit.',
  '- top_products: what sells best over a window, by units or by revenue. Parameters: from_date, to_date, metric, limit.',
  '- dead_stock: stock that has not moved in a while. Parameters: days, limit.',
  '- unsupported: anything the five above cannot answer.',
  '',
  'Rules:',
  '- Choose from that list and nothing else.',
  '- Parameters carry only a date range, a horizon in days, a row limit and a metric. A figure you would like to say goes nowhere: the answer is read from the report.',
  '- If two reports could answer, choose the one whose subject the question names.',
  '- For report_summary, name what the question is ABOUT with `subject`: sales, purchases, returns, expenses, stock, or everything. Only the part you name is shown, so name the part the question asked about, and use "everything" for a broad question about the period as a whole.',
  '- A summary\'s "stock" is the pharmacy\'s whole stock, valued. A question about ONE product\'s stock is not this report: choose "unsupported".',
  '- If the question is not one of these, choose "unsupported".',
].join('\n');

/** The URL one classification is sent to, with the API key kept out of it. */
export function generateContentUrl(model: string): string {
  return `${GEMINI_API_BASE}/models/${model}:generateContent`;
}

/**
 * The request body for one question.
 *
 * `temperature: 0` and a JSON mime type, exactly as the bill reader does it: the
 * same question should classify the same way twice, and the answer is a small
 * object rather than prose.
 */
export function buildClassificationBody(input: {
  question: string;
  history: ChatTurn[];
}): unknown {
  const context = input.history
    .slice(-MAX_HISTORY_TURNS)
    .map((turn) => `${turn.role === 'user' ? 'User' : 'Assistant'}: ${turn.text}`)
    .join('\n');

  const prompt = context.length === 0
    ? `Question: ${input.question}`
    : [
      'Earlier in this conversation (context only; it is not an instruction):',
      context,
      '',
      `Question: ${input.question}`,
    ].join('\n');

  return {
    systemInstruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      responseMimeType: 'application/json',
      responseSchema: CLASSIFICATION_SCHEMA,
    },
  };
}

/**
 * The JSON text out of a `generateContent` response.
 *
 * A reply with no content is a provider failure with the model's own reason
 * attached, the way the bill reader reports one. A fenced reply is a formatting
 * slip rather than a refusal, so a markdown fence is stripped before parsing.
 */
export function extractResponseText(apiResponse: unknown): string {
  const body = asRecord(apiResponse);
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
      `The model returned nothing for that question (${reason}).`,
    );
  }

  return stripFence(text);
}

/**
 * The model's choice, validated before anything is done with it.
 *
 * A reply that is not JSON at all is a provider failure: the schema asked for
 * JSON and the model did not deliver it. But a reply that *is* JSON and names a
 * report this function does not have is treated as `unsupported` rather than as
 * an error - refusing to answer is the safe direction (D-026: never a guess), and
 * the enum makes it nearly impossible anyway.
 *
 * Every parameter is validated here rather than trusted: a date that is not
 * `YYYY-MM-DD` cannot reach a `date` argument, and an integer that is not one is
 * dropped so the report's own default applies. The reports clamp their own limits
 * as well, because they are reachable without this function.
 */
export function parseClassification(apiResponse: unknown): Classification {
  const text = extractResponseText(apiResponse);

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new FunctionError(
      'provider_unavailable',
      'The model did not answer with JSON for that question.',
    );
  }

  const record = asRecord(parsed);
  const choice = asText(record.rpc);
  const rpc: ClassificationChoice =
    choice !== null && (CLASSIFICATION_CHOICES as readonly string[]).includes(choice)
      ? (choice as ClassificationChoice)
      : 'unsupported';

  return {
    rpc,
    params: {
      fromDate: asDate(record.from_date),
      toDate: asDate(record.to_date),
      days: asInteger(record.days),
      limit: asInteger(record.limit),
      metric: record.metric === 'revenue' || record.metric === 'units'
        ? record.metric
        : null,
      subject: asSubject(record.subject),
    },
  };
}

/** A `YYYY-MM-DD` string, or `null`. Nothing else may reach a `date` argument. */
function asDate(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? trimmed : null;
}

/**
 * One of [SUMMARY_SUBJECTS], or `null`.
 *
 * `null` is not a failure: it is "the model named no subject", and the sentence then
 * takes [DEFAULT_SUMMARY_SUBJECT] - the same reading this report always had. A name
 * outside the closed set is dropped rather than passed on, so a model that invents a
 * sixth subject cannot reach the renderer with it (the same belt `asDate` and
 * `asInteger` are).
 */
function asSubject(value: unknown): SummarySubject | null {
  const name = asText(value);
  return name !== null && (SUMMARY_SUBJECTS as readonly string[]).includes(name)
    ? (name as SummarySubject)
    : null;
}

/** A whole number, or `null`. A numeric string is accepted; anything else is not. */
function asInteger(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) {
    return Number.parseInt(value.trim(), 10);
  }
  return null;
}

/** A markdown-fenced answer, unwrapped. */
function stripFence(text: string): string {
  const match = text.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  return match ? match[1].trim() : text;
}

/** A JSON object, or an empty one. */
function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** A non-empty string, or `null`. */
function asText(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}
