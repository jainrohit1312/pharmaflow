/**
 * The real world behind the match handler's seams: the caller's credentials, the
 * RPC that ranks, and the embedding model.
 *
 * Nothing here makes a decision - every rule lives in `handler.ts` and
 * `_shared/embedding.ts`, where it can be tested. This is the wiring, and its job
 * is to be small enough to read in one sitting.
 */

import { env, requirePharmacyId, userClient } from '../_shared/client.ts';
import {
  batchEmbedContentsUrl,
  buildBatchEmbedContentsBody,
  DEFAULT_EMBEDDING_MODEL,
  parseEmbeddings,
  QUERY_TASK_TYPE,
} from '../_shared/embedding.ts';
import { FunctionError } from '../_shared/errors.ts';
import { postGemini } from '../_shared/gemini.ts';
import { MATCH_LIMIT, type HandlerDeps, type MatchQuery } from './handler.ts';

/** The embedding model to ask. A deployment can move it without a redeploy. */
const model =
  Deno.env.get('GEMINI_EMBEDDING_MODEL')?.trim() || DEFAULT_EMBEDDING_MODEL;

export const defaultDeps: HandlerDeps = {
  model,

  /**
   * The caller's pharmacy, read as the caller.
   *
   * The matcher does not use the value - the RPC derives the same tenant from the
   * same identity - but asking for it first means an account with no pharmacy is
   * refused as such instead of being handed an empty candidate list to interpret.
   */
  getPharmacyId: (request) => requirePharmacyId(userClient(request)),

  /**
   * One `batchEmbedContents` request for the whole bill.
   *
   * The key is read per request rather than at module load, so a missing secret
   * is a sentence the caller can read ("the lines could not be embedded…") rather
   * than a function that fails to start.
   */
  embed: async (request, texts) => {
    const apiKey = env('GEMINI_API_KEY');

    const reply = await postGemini(
      {
        url: batchEmbedContentsUrl(model),
        request: buildBatchEmbedContentsBody({
          model,
          texts,
          taskType: QUERY_TASK_TYPE,
        }),
      },
      apiKey,
    );

    return parseEmbeddings(reply, texts.length);
  },

  /**
   * The ranking, from the database, as the caller (D-004).
   *
   * `p_queries` carries the invoice text, the supplier and the query vector;
   * nothing else travels, and the pharmacy does not travel at all. The RPC is
   * `security definer` and reads the tenant from `get_my_pharmacy_id()`, so this
   * call cannot ask for another pharmacy's catalogue even if this file were wrong.
   */
  match: async (request, queries: MatchQuery[]) => {
    const { data, error } = await userClient(request).rpc('match_products', {
      p_queries: queries,
      p_limit: MATCH_LIMIT,
    });

    if (error) {
      throw new FunctionError(
        'internal',
        `The catalogue match failed: ${error.message}`,
      );
    }
    return data;
  },
};
