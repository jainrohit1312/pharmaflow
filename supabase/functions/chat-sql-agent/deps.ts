/**
 * The real world behind the chatbot handler's seams: the caller's credentials,
 * the text model, and the reports.
 *
 * Nothing here makes a decision - every rule lives in `handler.ts`, `schema.ts`
 * and `answer.ts`, where it can be tested. This is the wiring, and its job is to
 * be small enough to read in one sitting.
 */

import { env, requirePharmacyId, userClient } from '../_shared/client.ts';
import { FunctionError } from '../_shared/errors.ts';
import { postGemini } from '../_shared/gemini.ts';
import type { HandlerDeps } from './handler.ts';
import {
  buildClassificationBody,
  DEFAULT_CHAT_MODEL,
  generateContentUrl,
  parseClassification,
} from './schema.ts';

/** The text model to ask. A deployment can move it without a redeploy (D-030). */
const model = Deno.env.get('GEMINI_CHAT_MODEL')?.trim() || DEFAULT_CHAT_MODEL;

export const defaultDeps: HandlerDeps = {
  model,

  /**
   * The caller's pharmacy, read as the caller.
   *
   * The chatbot does not use the value - every report derives the same tenant
   * from the same identity - but asking for it first means an account with no
   * pharmacy is refused as such instead of spending a model call on a question
   * nobody can answer.
   */
  getPharmacyId: (request) => requirePharmacyId(userClient(request)),

  /**
   * The one model call (D-026, D-053). The key is read per request rather than at
   * module load, so a missing secret is a sentence the caller can read rather
   * than a function that fails to start.
   *
   * `parseClassification` validates the choice and every parameter before either
   * is used; a reply with no usable decision comes back as `unsupported`, which
   * is a refusal rather than a guess.
   */
  classify: async (_request, question, history) => {
    const apiKey = env('GEMINI_API_KEY');

    const reply = await postGemini(
      {
        url: generateContentUrl(model),
        request: buildClassificationBody({ question, history }),
      },
      apiKey,
    );

    return parseClassification(reply);
  },

  /**
   * The report, run as the caller (D-004).
   *
   * The name is one of five constants and the arguments are the fixed set
   * `paramsFor` built, so nothing the model produced is *executed*. Each report
   * is `security definer` and reads the tenant from `get_my_pharmacy_id()`, so
   * this call cannot ask for another pharmacy's numbers even if this file were
   * wrong.
   */
  run: async (request, rpc, args) => {
    const { data, error } = await userClient(request).rpc(rpc, args);

    if (error) {
      throw new FunctionError(
        'internal',
        `The ${rpc} report failed: ${error.message}`,
      );
    }
    return data;
  },
};
