/**
 * The real world behind the dispatch handler's seams: the caller's credentials,
 * the RPC that opens the attempt, the two providers, and the update that settles
 * it.
 *
 * Nothing here makes a decision - every rule lives in `handler.ts` and
 * `providers.ts`, where it can be tested. This is the wiring, and its job is to be
 * small enough to read in one sitting.
 *
 * Secrets are read **per request** rather than at module load, which is the shape
 * `match-product`'s deps established: a missing secret then arrives as a sentence
 * the caller can read, and as a log row with `status = 'skipped'` that names it,
 * rather than as a function that fails to start. Because this project has no
 * WhatsApp account and no SendGrid key at all (D-046), that path is the one a real
 * deployment meets today.
 */

import { env, requirePharmacyId, userClient } from '../_shared/client.ts';
import { FunctionError } from '../_shared/errors.ts';
import type { HandlerDeps, QueueResult } from './handler.ts';
import {
  DEFAULT_WHATSAPP_API_VERSION,
  postSendGrid,
  postWhatsApp,
  sendgridMail,
  whatsappMessage,
} from './providers.ts';

/**
 * The Graph API version to call. A deployment can move it without a redeploy.
 *
 * Named in code rather than inlined (D-030's pattern) because Meta retires
 * versions on a schedule, and an override is here for the day it does.
 */
const whatsappVersion =
  Deno.env.get('WHATSAPP_API_VERSION')?.trim() || DEFAULT_WHATSAPP_API_VERSION;

export const defaultDeps: HandlerDeps = {
  /**
   * The caller's pharmacy, read as the caller.
   *
   * The RPC derives the same tenant from the same identity - this is not passed to
   * it - but asking first means an account with no pharmacy is refused as such
   * instead of being handed the queue's own `check_violation` to interpret.
   */
  getPharmacyId: (request) => requirePharmacyId(userClient(request)),

  /**
   * Opens the attempt: the log row, and the in-app row it points at, in one
   * transaction (D-024).
   *
   * A `check_violation` from the function is a refusal with a sentence written for
   * a person - the same shape a schema CHECK has - so it is reported as
   * `invalid_request` and the sentence reaches the caller verbatim. Anything else
   * is this project's problem, not theirs.
   */
  queue: async (request, payload) => {
    const { data, error } = await userClient(request).rpc('queue_notification', {
      p_payload: payload,
    });

    if (error) {
      if (error.code === '23514') {
        throw new FunctionError('invalid_request', error.message);
      }
      throw new FunctionError(
        'internal',
        `The notification could not be opened: ${error.message}`,
      );
    }

    return readQueueResult(data);
  },

  /** One WhatsApp text message, as the caller. */
  whatsapp: (request, to, body) => {
    const token = env('WHATSAPP_TOKEN');
    const phoneNumberId = env('WHATSAPP_PHONE_NUMBER_ID');

    return postWhatsApp(
      whatsappMessage({ version: whatsappVersion, phoneNumberId, to, body }),
      token,
    );
  },

  /** One email, as the caller. */
  email: (request, to, subject, body) => {
    const apiKey = env('SENDGRID_API_KEY');
    const from = env('SENDGRID_FROM_EMAIL');

    return postSendGrid(sendgridMail({ from, to, subject, body }), apiKey);
  },

  /**
   * Records what happened, with the caller's own token.
   *
   * The log table's update policy is tenant-scoped, so this needs no `security
   * definer` help - and a row RLS refuses is not an error, it is *zero rows*, so
   * the row is asked for back and a silent no-op is treated as the failure it is.
   * When this throws, the row stays `queued`, which is what `queued` is for.
   */
  settle: async (request, logId, outcome) => {
    const { data, error } = await userClient(request)
      .from('notification_logs')
      .update({
        status: outcome.status,
        provider: outcome.provider,
        provider_message_id: outcome.providerMessageId,
        error: outcome.error,
      })
      .eq('id', logId)
      .select('id');

    if (error) {
      throw new FunctionError(
        'internal',
        `The message was attempted but its outcome could not be recorded: ${error.message}`,
      );
    }
    if (!Array.isArray(data) || data.length === 0) {
      throw new FunctionError(
        'internal',
        'The message was attempted but its outcome could not be recorded: the log row was not this caller\'s to update.',
      );
    }
  },
};

/** The two ids `queue_notification` answers with, or a failure saying it cannot be read. */
function readQueueResult(data: unknown): QueueResult {
  const record =
    typeof data === 'object' && data !== null
      ? (data as Record<string, unknown>)
      : {};
  const logId = record.log_id;

  if (typeof logId !== 'string' || logId.length === 0) {
    throw new FunctionError(
      'internal',
      'The notification was opened but came back in a shape this app does not understand, so it was left queued.',
    );
  }

  const notificationId = record.notification_id;
  return {
    logId,
    notificationId:
      typeof notificationId === 'string' && notificationId.length > 0
        ? notificationId
        : null,
  };
}
