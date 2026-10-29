/**
 * Auth0 - Custom Email Provider script.
 * 
 * !! If you are viewing this code in Auth0, do not edit it here. Edit the source file at: 
 * https://github.com/ministryofjustice/hale-platform/tree/main/opt/auth0/main.cjs
 *
 * This script enables Auth0 to send emails via the UK Gov Notify service.

 * It is saved here as the source of truth:
 * - to prevent drift between our Auth0 dev and production tenants.
 * - so that it can be tested and peer reviewed.
 * - so that it is available for reuse/adaptation, e.g. with a new Intranet platform.
 *
 * When a change to this file is merged into main, the file's contents should
 * be copy and pasted into Auth0's settings. The settings screen is at:
 * Branding > Email Provider > Custom provider
 *
 * Ensure that the prerequisite values have been set on the Custom provider screen:
 * - NOTIFY_API_KEY
 * - NOTIFY_TEMPLATE_ID
 *
 * During testing, on Auth0 you can send a test email from the Custom provider screen.
 * It can be useful to check for success or failure logs at:
 * Monitoring > Logs
 */

const crypto = require("node:crypto");

// Notify API key format: {key name}-{service id}-{secret}
function notifyJwt(apiKey) {
  const iss = apiKey.slice(-73, -37);
  const secret = apiKey.slice(-36);
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const unsigned = `${enc({ typ: "JWT", alg: "HS256" })}.${enc({ iss, iat: Math.floor(Date.now() / 1000) })}`;
  return `${unsigned}.${crypto.createHmac("sha256", secret).update(unsigned).digest("base64url")}`;
}

exports.onExecuteCustomEmailProvider = async (event, api) => {
  const n = event.notification;

  if (!n.text?.trim()) {
    return api.notification.drop("Empty text body");
  }

  // Without this, a missing key throws inside the try below and is retried as "Notify unreachable".
  const { NOTIFY_API_KEY, NOTIFY_TEMPLATE_ID } = event.secrets;
  if (!NOTIFY_API_KEY || !NOTIFY_TEMPLATE_ID) {
    return api.notification.drop("Notify secrets missing");
  }

  let res;

  try {
    res = await fetch(
      "https://api.notifications.service.gov.uk/v2/notifications/email",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${notifyJwt(NOTIFY_API_KEY)}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email_address: n.to,
          template_id: NOTIFY_TEMPLATE_ID,
          personalisation: { subject: n.subject, body: n.text },
          reference: n.message_type, // must not contain personal data
        }),
        signal: AbortSignal.timeout(10000),
      },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return api.notification.retry(`Notify unreachable: ${message}`);
  }

  const text = await res.text().catch(() => "Response body unavailable");
  if (res.status === 429 || res.status >= 500) {
    return api.notification.retry(`Notify: ${res.status}, ${text}`);
  }
  if (!res.ok) {
    return api.notification.drop(`Notify: ${res.status}, ${text}`);
  }
};
