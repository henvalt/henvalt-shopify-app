# HENVALT trusted recovery message rendering V2

**Status:** candidate implementation on the preparation branch; no production delivery is enabled by this document.

## Contract

The n8n workflow must pass only one opaque identifier:

- checkout: `{"intervention_id":"<UUID>"}`;
- cart/browse: `{"opportunity_id":"<UUID>"}`.

The two V2 delivery Edge Functions reject every additional input property. They do not accept caller-supplied subject, HTML, text, recipient address, store domain, brand name, item description or CTA URL.

Before rendering, the Edge Function calls the service-only
`henvalt.resolve_shopify_recovery_message_context_v2(work_type,work_id)`
RPC. The RPC returns a canonical myshopify.com domain and one of the three
approved opportunity types only after checking the matching tenant, immutable
connection, active app/store and exact source lineage. It never returns
customer PII, provider/Shopify secrets or delivery authority.

## Current template policy

The shared `recovery-message-v2.mjs` module renders three fixed, conservative
templates:

| Opportunity | Subject | CTA |
|---|---|---|
| `ABANDONED_CHECKOUT` | Still thinking it over? | Visit the store |
| `ABANDONED_CART` | Something caught your eye? | Visit the store |
| `BROWSE_ABANDONMENT` | Still interested? | Visit the store |

The only merchant-supplied display value is the verified sender profile's
display name. It is HTML-escaped before interpolation. The store link is
constructed only from the exact, validated canonical `*.myshopify.com`
hostname and uses HTTPS.

The current checkout CTA intentionally points to the store root rather than
pretending to resume a checkout. No checkout URL or token is persisted by the
current candidate identity graph. Product names, cart line data, customer
names, discounts and arbitrary HTML are not included. A future deep-link or
item-personalization enhancement needs a separately reviewed, exact-store
server context source and new tests.

## Mandatory MailerSend unsubscribe verification

Every HTML and text template contains the MailerSend `{{unsubscribe}}`
placeholder. MailerSend documents that this variable expands to a unique
unsubscribe URL only when unsubscribe tracking is enabled.

Before any provider submission, the Edge Function calls
`GET https://api.mailersend.com/v1/domains?limit=100` with the server-held
MailerSend API token. It requires an exact sender-domain match, `is_verified`
and all three settings:

- `domain_settings.track_unsubscribe === true`;
- `domain_settings.track_unsubscribe_html_enabled === true`;
- `domain_settings.track_unsubscribe_plain_enabled === true`.

It then calls `GET https://api.mailersend.com/v1/webhooks?domain_id={domain_id}&limit=100` and requires an enabled version-2 webhook whose URL exactly matches `SUPABASE_URL/functions/v1/henvalt-mailersend-webhook-v2/{provider_account_key}` and whose event list includes `activity.sent`, `activity.delivered`, `activity.soft_bounced`, `activity.hard_bounced`, `activity.unsubscribed`, `activity.spam_complaint`, `activity.opened` and `activity.clicked`. Any HTTP failure, timeout, malformed response, missing domain/webhook, wrong URL/version, missing event or disabled setting blocks delivery with `mailer_send_v2_delivery_preflight_failed`. The template placeholder is not knowingly sent without expansion, and a delivery cannot proceed without the exact signed V2 event route registered.

Both checkout and pixel paths resolve the exact-store verified sender profile and perform the MailerSend domain/webhook preflight before any one-use permit is issued or consumed. If the sender, unsubscribe settings or exact V2 webhook registration is missing, neither path creates a send attempt or cost reservation.

## Provider ambiguity

Both delivery functions set a provider-submission-started marker before the
HTTP request. Network errors, 408/5xx, missing provider message IDs and
post-request ledger failures are treated as AMBIGUOUS. The function retains
the cost reservation, returns a 202 reconciliation status and never tells n8n
to retry that work item. Signed provider webhook reconciliation owns the
outcome.

A definite provider rejection is recorded FAILED. Since the work-claim RPC
excludes opportunities with any existing send attempt, the same opportunity
must not be automatically re-claimed as a new email send.

## Verification

The candidate regression suite tests:

- all three allowlisted opportunity types;
- HTML escaping of sender display names;
- rejection of non-Shopify or malformed domains and unsupported types;
- no customer, cart, checkout token, discount or fabricated deep-link data;
- verified exact sender-domain lookup and both unsubscribe body settings;
- fail-closed behavior for missing domains, disabled tracking, network errors
  and malformed credentials;
- opaque-ID-only Edge Function request contracts;
- exact-store, service-role-only message context;
- conservative AMBIGUOUS handling for checkout and pixel provider requests.

The disposable PostgreSQL work-claim fixture also verifies the pixel message
context RPC returns the expected exact store/type and explicit no-PII,
no-secret, no-delivery-authority flags.

Both V2 delivery functions also require `HENVALT_V2_MAILERSEND_EVENTS_READY=true`. The functions dynamically verify the exact V2 webhook registration and require this operator attestation to confirm the legacy duplicate event route has been disabled. They return 503 before message-context resolution or permit issue when the flag is absent.

These tests validate candidate code only. They do not establish live
MailerSend domain settings, production schema parity, a real recovery message,
or active n8n integration.

## MailerSend webhook URL-validation ping

Migration 046 corrects a fixed-secret mismatch in the earlier candidate
provider-event ingress. MailerSend sends a `webhook.test` ping when a webhook
URL is registered/updated and signs that ping with the documented fixed test
secret. The earlier candidate migration had a mistyped value, which would
reject the provider's URL-validation request.

The new wrapper intercepts only `webhook.test`, verifies the exact documented
test signature in constant time, confirms the provider account is ACTIVE or
PENDING, returns `WEBHOOK_TEST_VERIFIED`, and does not persist a provider
event. Every non-test event is delegated unchanged to the prior V2 signed
ingress function, which still verifies the account-specific Vault signing
secret and performs the normal inbox/reconciliation flow.

The disposable PostgreSQL fixture computes the documented test signature,
asserts the URL-validation response, and verifies that no provider-event row
was inserted. It also verifies the wrapper rejects malformed/invalid
signatures through the same service-only RPC boundary.
