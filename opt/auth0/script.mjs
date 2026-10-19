const crypto = require('node:crypto');

// Notify API key format: {key name}-{service id}-{secret}
function notifyJwt(apiKey) {
  const iss = apiKey.slice(-73, -37);
  const secret = apiKey.slice(-36);
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = `${enc({ typ: 'JWT', alg: 'HS256' })}.${enc({ iss, iat: Math.floor(Date.now() / 1000) })}`;
  return `${unsigned}.${crypto.createHmac('sha256', secret).update(unsigned).digest('base64url')}`;
}

exports.onExecuteCustomEmailProvider = async (event, api) => {
  const n = event.notification;
  if (!n.text?.trim()) {
    return api.notification.drop('Empty text body');
  }
  let res;
  try {
    res = await fetch('https://api.notifications.service.gov.uk/v2/notifications/email', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${notifyJwt(event.secrets.NOTIFY_API_KEY)}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email_address: n.to,
        template_id: event.secrets.NOTIFY_TEMPLATE_ID,
        personalisation: { subject: n.subject, body: n.text },
        reference: n.message_type, // must not contain personal data
      }),
      signal: AbortSignal.timeout(10000),
    });
  } catch (err) {
    return api.notification.retry(`Notify unreachable: ${err.message}`);
  }
  if (res.status === 429 || res.status >= 500) {
    return api.notification.retry(`Notify ${res.status}`);
  }
  if (!res.ok) {
    return api.notification.drop(`Notify ${res.status}`);
  }
};