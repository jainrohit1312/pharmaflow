/**
 * The chatbot's request path.
 *
 * One question in, one answer out, and the answer is read from a report rather
 * than composed. Every effect arrives through `HandlerDeps`, so the whole path is
 * exercised by `handler_test.ts` with stubs - no Docker, no API key, no database.
 *
 * Three rules shape this file, and each is a decision rather than a style:
 *
 *   1. **The model chooses; the database answers** (D-026). This function calls
 *      the model exactly once, to ask which of the five reports answers the
 *      question and with what parameters. It then runs that report and renders the
 *      sentence from the report's own `jsonb` (D-053). No model output is ever
 *      rendered to the user, so no figure the database did not compute can appear.
 *   2. **One request makes one model call, and it does not retry** (N-2). The
 *      Gemini key is a free tier of five requests a minute, shared with the bill
 *      reader, and the reader's own policy is one attempt that reports itself as
 *      retryable (D-032). A chat turn that retried inside the function would halve
 *      the OCR flow's headroom to hide a failure the caller could have seen; the
 *      call comes back as `provider_unavailable` and the app retries visibly
 *      (D-033).
 *   3. **The tenant is never an argument** (D-004). It is not read from the body
 *      at all: `getPharmacyId` asks the caller's own identity, and each report
 *      derives it again from `get_my_pharmacy_id()`. A pharmacy id in the request
 *      would be exactly the thing an attacker supplies.
 *
 * The function reads and never writes: it moves no stock, posts no ledger entry
 * and sends no message. A question the five reports cannot answer is answered
 * with a sentence, not with a guess.
 */

import { FunctionError, isFunctionError } from '../_shared/errors.ts';
import { failJson, okJson, preflight } from '../_shared/response.ts';
import { effectiveParams, renderAnswer } from './answer.ts';
import {
  ANSWER_LANGUAGES,
  DEFAULT_ANSWER_LANGUAGE,
  MAX_HISTORY_TURNS,
  type AnswerLanguage,
  type ChatParams,
  type ChatTurn,
  type Classification,
  type SupportedRpc,
} from './schema.ts';

/** A question longer than this is not a question. */
export const MAX_QUESTION_LENGTH = 1000;

/** The most context one turn may carry, so a prompt stays bounded. */
export const MAX_TURN_LENGTH = 500;

/** Everything the handler needs from the outside world. */
export interface HandlerDeps {
  /** The text model, named in code (D-030) and reported in `meta`. */
  model: string;
  /** The pharmacy the caller belongs to. Never taken from the request. */
  getPharmacyId(request: Request): Promise<string>;
  /** The one model call: which report, and with what parameters. */
  classify(
    request: Request,
    question: string,
    history: ChatTurn[],
  ): Promise<Classification>;
  /** Runs the chosen report, as the caller, and returns its `jsonb`. */
  run(
    request: Request,
    rpc: SupportedRpc,
    args: Record<string, unknown>,
  ): Promise<unknown>;
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
        throw new FunctionError('invalid_request', 'This endpoint accepts POST.');
      }

      const body = await readJsonBody(request);
      const question = validateQuestion(body.question);
      const history = validateHistory(body.history);
      // The caller's own choice, not the model's: read beside the question, because it is
      // the same kind of thing (see `ANSWER_LANGUAGES`).
      const language = validateLanguage(body.language);

      // Before the model is paid for: an account with no pharmacy has no reports
      // to answer from, and saying so is better than a classification nobody can
      // use.
      await deps.getPharmacyId(request);

      const classification = await deps.classify(request, question, history);

      const warnings: string[] = [];
      let effective: ChatParams = classification.params;
      let args: Record<string, unknown> = {};
      let data: unknown = null;
      let rpc: SupportedRpc | null = null;

      if (classification.rpc !== 'unsupported') {
        rpc = classification.rpc;
        // One object decides the arguments *and* the sentence, so the two cannot come to
        // describe different queries: the horizon a sentence states is the horizon the
        // report ran (see `effectiveParams`, and the 5000-day horizon it exists for).
        effective = effectiveParams(rpc, classification.params);
        args = paramsFor(rpc, effective);
        data = await deps.run(request, rpc, args);
      }

      const rendered = renderAnswer(classification.rpc, data, effective, language);
      if (!rendered.understood) {
        warnings.push(
          'The report ran, but its answer came back in a shape this app does not understand.',
        );
      }

      return okJson({
        answer: rendered.text,
        // `null` on purpose when nothing could answer: the app renders that as a
        // successful answer that says so, not as an error (D-026).
        rpc,
        // The arguments the report actually ran with - what the caller needs to
        // show "what was asked" beside the answer.
        params: args,
        data,
        meta: { model: deps.model, warnings },
      });
    } catch (error) {
      if (isFunctionError(error)) {
        console.error(`chat-sql-agent refused: ${error.code} - ${error.message}`);
        return failJson(error);
      }

      console.error('chat-sql-agent failed unexpectedly', error);
      return failJson(error);
    }
  };
}

/**
 * The arguments one report takes, and only those.
 *
 * This is the boundary that makes "the model fills declared parameters" true: a report is
 * handed a fixed set of keys, so a value the model put somewhere unexpected cannot travel
 * as an argument to a report that has no such parameter.
 *
 * It is a pure mapper, and deliberately so: `effectiveParams` has already resolved every
 * default and every out-of-range value, so what this returns **is** what the sentence was
 * written from. `p_metric` is passed as `null` when the model named none, because the
 * report's own default is right there and its sentence says which metric it used - read
 * from the report's own `meta`.
 */
export function paramsFor(
  rpc: SupportedRpc,
  params: ChatParams,
): Record<string, unknown> {
  switch (rpc) {
    case 'report_summary':
      return { p_from: params.fromDate, p_to: params.toDate };
    case 'low_stock_products':
      return { p_limit: params.limit };
    case 'expiring_batches':
      return { p_days: params.days, p_limit: params.limit };
    case 'top_products':
      return {
        p_from: params.fromDate,
        p_to: params.toDate,
        p_limit: params.limit,
        p_metric: params.metric,
      };
    case 'dead_stock':
      return { p_days: params.days, p_limit: params.limit };
  }
}

/**
 * The question, from the body.
 *
 * Empty is refused because there is nothing to classify; an over-long one is
 * refused rather than truncated, because truncating a question changes what was
 * asked without saying so.
 */
export function validateQuestion(raw: unknown): string {
  if (typeof raw !== 'string' || raw.trim().length === 0) {
    throw new FunctionError('invalid_request', 'Ask a question in the "question" field.');
  }

  const question = raw.trim();
  if (question.length > MAX_QUESTION_LENGTH) {
    throw new FunctionError(
      'invalid_request',
      `That question is longer than ${MAX_QUESTION_LENGTH} characters. Ask a shorter one.`,
    );
  }

  return question;
}

/**
 * The language the answer should be written in, from the body.
 *
 * **Absent is the common case, and it is not a failure**: a caller that never heard of a
 * language gets the default, which is what every client sent before this existed. A name
 * this function does not know is *also* the default rather than a refusal, in the same
 * direction `asDate` and `asInteger` go and for the same reason - refusing to answer a
 * question because of the language it asked for would be a worse answer than answering it
 * in the wrong language.
 */
export function validateLanguage(raw: unknown): AnswerLanguage {
  if (typeof raw !== 'string') {
    return DEFAULT_ANSWER_LANGUAGE;
  }
  const wanted = raw.trim().toLowerCase();
  return (ANSWER_LANGUAGES as readonly string[]).includes(wanted)
    ? (wanted as AnswerLanguage)
    : DEFAULT_ANSWER_LANGUAGE;
}

/**
 * The earlier turns, from the body.
 *
 * Absent is fine - a first question has no history. What is present is validated
 * strictly, with the offending position named, and only the most recent
 * [MAX_HISTORY_TURNS] are kept: the conversation is context for the classifier,
 * not a transcript, and an unbounded one is a prompt that grows without limit.
 *
 * The text is carried as *data* and the prompt labels it as context rather than
 * instruction (see `buildClassificationBody`): history is caller-supplied text,
 * and it is never allowed to read as an instruction to the model.
 */
export function validateHistory(raw: unknown): ChatTurn[] {
  if (raw === undefined || raw === null) {
    return [];
  }
  if (!Array.isArray(raw)) {
    throw new FunctionError(
      'invalid_request',
      'Send the conversation as a list of {role, text} turns, or omit it.',
    );
  }

  const turns = raw.map((entry, index) => {
    const record =
      typeof entry === 'object' && entry !== null && !Array.isArray(entry)
        ? (entry as Record<string, unknown>)
        : null;
    if (record === null) {
      throw new FunctionError(
        'invalid_request',
        `Turn ${index + 1} of the conversation is not a {role, text} object.`,
      );
    }

    const role = asRole(record.role);
    if (role === null) {
      throw new FunctionError(
        'invalid_request',
        `Turn ${index + 1} of the conversation has no role of "user" or "model".`,
      );
    }

    const text = record.text;
    if (typeof text !== 'string' || text.trim().length === 0) {
      throw new FunctionError(
        'invalid_request',
        `Turn ${index + 1} of the conversation has no text.`,
      );
    }

    const trimmed = text.trim();
    return {
      role,
      text: trimmed.length > MAX_TURN_LENGTH ? trimmed.slice(0, MAX_TURN_LENGTH) : trimmed,
    };
  });

  return turns.slice(-MAX_HISTORY_TURNS);
}

/** A conversation role, or `null` for anything else. */
function asRole(value: unknown): ChatTurn['role'] | null {
  return value === 'user' || value === 'model' ? value : null;
}

/** The request body, or an `invalid_request` failure. */
async function readJsonBody(
  request: Request,
): Promise<Record<string, unknown>> {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    throw new FunctionError(
      'invalid_request',
      'Send the question as a JSON body, e.g. {"question": "what is low on stock?"}.',
    );
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new FunctionError(
      'invalid_request',
      'Send the question as a JSON object with a "question" field.',
    );
  }

  return parsed as Record<string, unknown>;
}
