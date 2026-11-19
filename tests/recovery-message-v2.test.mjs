import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { renderRecoveryMessageV2, mailerSendV2DeliveryReady } from "../supabase/functions/_shared/recovery-message-v2.mjs";

test("server renderer supports only the three explicitly approved recovery opportunity types", () => {
  for (const opportunityType of ["ABANDONED_CHECKOUT", "ABANDONED_CART", "BROWSE_ABANDONMENT"]) {
    const message = renderRecoveryMessageV2({
      shopDomain: "merchant-test.myshopify.com",
      opportunityType,
      brandName: "Merchant & Co",
    });
    assert.ok(message.subject.length > 0);
    assert.match(message.html, /href="https:\/\/merchant-test\.myshopify\.com\//);
    assert.match(message.html, /Merchant &amp; Co/);
    assert.equal(message.html.includes('href="{{unsubscribe}}"') && message.html.includes('>Unsubscribe</a>'), true);
    assert.equal(message.text.includes("Unsubscribe: {{unsubscribe}}"), true);
    assert.match(message.text, /https:\/\/merchant-test\.myshopify\.com\//);
    assert.equal(message.templateVersion, "recovery-v2-2026-11-19");
  }
});

test("renderer escapes sender-controlled branding and rejects untrusted domains and types", () => {
  const message = renderRecoveryMessageV2({
    shopDomain: "merchant-test.myshopify.com",
    opportunityType: "ABANDONED_CART",
    brandName: '<img src=x onerror="alert(1)">',
  });
  assert.doesNotMatch(message.html, /<img src=x/);
  assert.equal(message.html.includes('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;'), true);
  assert.throws(() => renderRecoveryMessageV2({
    shopDomain: "merchant-.myshopify.com",
    opportunityType: "ABANDONED_CART",
    brandName: "Store",
  }), /verified Shopify store domain/);
  assert.throws(() => renderRecoveryMessageV2({
    shopDomain: "attacker.example",
    opportunityType: "ABANDONED_CART",
    brandName: "Store",
  }), /verified Shopify store domain/);
  assert.throws(() => renderRecoveryMessageV2({
    shopDomain: "merchant-test.myshopify.com",
    opportunityType: "UNSUPPORTED",
    brandName: "Store",
  }), /Unsupported recovery opportunity type/);
});

test("rendered messages never contain customer identifiers, cart data, discounts or fabricated checkout URLs", () => {
  const message = renderRecoveryMessageV2({
    shopDomain: "merchant-test.myshopify.com",
    opportunityType: "ABANDONED_CHECKOUT",
    brandName: "Store",
  });
  for (const forbidden of ["{{customer", "checkout_token", "discount", "gid://", "cart_id", "/checkouts/"]) {
    assert.equal(message.html.includes(forbidden), false, forbidden);
    assert.equal(message.text.includes(forbidden), false, forbidden);
  }
});

test("MailerSend V2 readiness requires verified unsubscribe settings and exact enabled webhook", async () => {
  const token = "x".repeat(24);
  const providerKey = "provider-key-1234567890123456";
  const expectedUrl = "https://project.supabase.co/functions/v1/henvalt-mailersend-webhook-v2/" + providerKey;
  const requiredEvents = [
    "activity.sent", "activity.delivered", "activity.soft_bounced",
    "activity.hard_bounced", "activity.unsubscribed", "activity.spam_complaint",
    "activity.opened", "activity.clicked",
  ];
  const responses = [
    { data: [{
      id: "domain-123",
      name: "mail.merchant.com",
      is_verified: true,
      domain_settings: {
        track_unsubscribe: true,
        track_unsubscribe_html_enabled: true,
        track_unsubscribe_plain_enabled: true,
      },
    }] },
    { data: [{
      id: "webhook-123",
      url: expectedUrl,
      enabled: true,
      version: 2,
      events: requiredEvents,
    }] },
  ];
  let call = 0;
  const fetcher = async (url, options) => {
    assert.equal(options.method, "GET");
    assert.equal(options.headers.authorization, "Bearer " + token);
    assert.equal(options.signal instanceof AbortSignal, true);
    if (call++ === 0) {
      assert.equal(url, "https://api.mailersend.com/v1/domains?limit=100");
      return { ok: true, json: async () => responses[0] };
    }
    assert.equal(url, "https://api.mailersend.com/v1/webhooks?domain_id=domain-123&limit=100");
    return { ok: true, json: async () => responses[1] };
  };
  assert.equal(await mailerSendV2DeliveryReady(
    token, "recovery@mail.merchant.com", providerKey, "https://project.supabase.co", fetcher
  ), true);
  assert.equal(call, 2);
});

test("MailerSend V2 readiness fails closed for missing domains, disabled unsubscribe, or wrong webhook", async () => {
  const token = "x".repeat(24);
  const providerKey = "provider-key-1234567890123456";
  const expectedUrl = "https://project.supabase.co/functions/v1/henvalt-mailersend-webhook-v2/" + providerKey;
  const validDomain = {
    id: "domain-123", name: "merchant.com", is_verified: true,
    domain_settings: {
      track_unsubscribe: true,
      track_unsubscribe_html_enabled: true,
      track_unsubscribe_plain_enabled: true,
    },
  };
  const validEvents = [
    "activity.sent", "activity.delivered", "activity.soft_bounced",
    "activity.hard_bounced", "activity.unsubscribed", "activity.spam_complaint",
    "activity.opened", "activity.clicked",
  ];
  const cases = [
    [{ data: [] }, { data: [] }],
    [{ data: [{ ...validDomain, is_verified: false }] }, { data: [] }],
    [{ data: [{ ...validDomain, domain_settings: { ...validDomain.domain_settings, track_unsubscribe_plain_enabled: false } }] }, { data: [] }],
    [{ data: [validDomain] }, { data: [{ url: expectedUrl, enabled: false, version: 2, events: validEvents }] }],
    [{ data: [validDomain] }, { data: [{ url: expectedUrl + "/wrong", enabled: true, version: 2, events: validEvents }] }],
    [{ data: [validDomain] }, { data: [{ url: expectedUrl, enabled: true, version: 1, events: validEvents }] }],
    [{ data: [validDomain] }, { data: [{ url: expectedUrl, enabled: true, version: 2, events: validEvents.slice(1) }] }],
  ];
  for (const [domains, webhooks] of cases) {
    let call = 0;
    const fetcher = async () => ({
      ok: true,
      json: async () => call++ === 0 ? domains : webhooks,
    });
    assert.equal(await mailerSendV2DeliveryReady(
      token, "recovery@merchant.com", providerKey, "https://project.supabase.co", fetcher
    ), false);
  }
  assert.equal(await mailerSendV2DeliveryReady("short", "recovery@merchant.com", providerKey, "https://project.supabase.co"), false);
  assert.equal(await mailerSendV2DeliveryReady(token, "invalid", providerKey, "https://project.supabase.co"), false);
  assert.equal(await mailerSendV2DeliveryReady(token, "recovery@merchant.com", "bad", "https://project.supabase.co"), false);
  assert.equal(await mailerSendV2DeliveryReady(token, "recovery@merchant.com", providerKey, "http://project.supabase.co"), false);
  assert.equal(await mailerSendV2DeliveryReady(token, "recovery@merchant.com", providerKey, "https://project.supabase.co", async () => { throw new Error("network"); }), false);
});

test("checkout and pixel Edge Functions accept only opaque work identifiers and render messages server-side", async () => {
  const checkout = readFileSync(new URL("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts", import.meta.url), "utf8");
  const pixel = readFileSync(new URL("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts", import.meta.url), "utf8");
  for (const edge of [checkout, pixel]) {
    assert.match(edge, /resolve_shopify_recovery_message_context_v2/);
    assert.match(edge, /mailerSendV2DeliveryReady/);
    assert.match(edge, /renderRecoveryMessageV2/);
    assert.match(edge, /subject:message.subject/);
    assert.match(edge, /html:message.html/);
    assert.match(edge, /text:message.text/);
    assert.match(edge, /mailer_send_v2_delivery_preflight_failed/);
    assert.match(edge, /HENVALT_V2_MAILERSEND_EVENTS_READY/);
    assert.match(edge, /v2_provider_event_path_not_ready/);
    assert.doesNotMatch(edge, /input.subject|input.html|input.text/);
    assert.ok(edge.indexOf("v2_provider_event_path_not_ready") < edge.indexOf("resolve_shopify_recovery_message_context_v2"));
    assert.ok(edge.indexOf("v2_provider_event_path_not_ready") < edge.indexOf("api.mailersend.com/v1/email"));
  }
  assert.match(checkout, /key!=="intervention_id"/);
  assert.match(checkout, /providerSubmissionStarted=true/);
  assert.ok(checkout.includes('providerSubmissionStarted?"AMBIGUOUS":"FAILED"'));
  assert.match(checkout, /sent.status>=500\|\|sent.status===408/);
  assert.ok(checkout.indexOf("resolve_shopify_sender_profile_for_delivery_v2") < checkout.indexOf("issue_shopify_delivery_permit_v2"));
  assert.ok(checkout.indexOf("mailerSendV2DeliveryReady") < checkout.indexOf("issue_shopify_delivery_permit_v2"));
  assert.match(pixel, /key!=="opportunity_id"/);
  assert.match(pixel, /providerSubmissionStarted=true/);
  assert.ok(pixel.includes('providerSubmissionStarted?"AMBIGUOUS":"FAILED"'));
  assert.ok(pixel.indexOf("mailerSendV2DeliveryReady") < pixel.indexOf("issue_shopify_pixel_delivery_permit_v2"));
});

test("message context migration is service-only, exact-store and PII-free", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611190001_shopify_recovery_message_context_v2.sql", import.meta.url), "utf8");
  assert.match(sql, /request.jwt.claim.role[\s\S]*?service_role_required/);
  assert.match(sql, /p_work_type='CHECKOUT_INTERVENTION'/);
  assert.match(sql, /p_work_type='PIXEL_OPPORTUNITY'/);
  assert.match(sql, /p_work_type IS NULL/);
  assert.match(sql, /JOIN henvalt.shopify_connections sc[\s\S]*?sc.tenant_id/);
  assert.match(sql, /JOIN henvalt.shopify_app_registry ar/);
  assert.match(sql, /JOIN henvalt.tenants t/);
  assert.match(sql, /recipient_pii_returned',false/);
  assert.match(sql, /provider_secrets_returned',false/);
  assert.match(sql, /delivery_authorized',false/);
  assert.match(sql, /REVOKE ALL ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2[\s\S]*?TO service_role/);
  assert.doesNotMatch(sql, /email_address|recipient_email|access_token|mailer_send_api_token|checkout_token,|customer_gid/);
});

test("verified sender preflight migration is service-only and exact-store scoped", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611190002_shopify_sender_profile_preflight_v2.sql", import.meta.url), "utf8");
  assert.match(sql, /request.jwt.claim.role[\s\S]*?service_role_required/);
  assert.match(sql, /sp.id=p_sender_profile_id/);
  assert.match(sql, /sp.shopify_connection_id=p_shopify_connection_id/);
  assert.match(sql, /sp.provider_account_key=p_provider_account_key/);
  assert.match(sql, /sp.status='ACTIVE'/);
  assert.match(sql, /sp.verified_at IS NOT NULL/);
  assert.match(sql, /sc.active IS TRUE/);
  assert.match(sql, /ar.lifecycle_status='active'/);
  assert.match(sql, /pr.status='ACTIVE'/);
  assert.match(sql, /recipient_pii_returned',false/);
  assert.match(sql, /delivery_authorized',false/);
  assert.match(sql, /REVOKE ALL ON FUNCTION henvalt.resolve_shopify_sender_profile_for_delivery_v2/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_sender_profile_for_delivery_v2[\s\S]*?TO service_role/);
  assert.doesNotMatch(sql, /customer_email|recipient_email|access_token|api_token/);
});

test("MailerSend webhook.test uses the documented fixed signature and does not persist a provider event", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611190003_mailersend_webhook_test_signature_v2.sql", import.meta.url), "utf8");
  assert.match(sql, /ALTER FUNCTION henvalt\.ingest_mailersend_webhook_v2[\s\S]*?RENAME TO ingest_mailersend_webhook_v2_legacy/);
  assert.ok(sql.includes("test_Am3L1GuOIc4blLUuHqAPxxwkZaJyEk8"));
  assert.ok(!sql.includes("test_Am3L3GuOIc4blLUuHqAPxxwkZaJyEk5"));
  assert.match(sql, /v_event_type IS DISTINCT FROM 'webhook\.test'/);
  assert.match(sql, /'WEBHOOK_TEST_VERIFIED'/);
  assert.match(sql, /'event_persisted',false/);
  assert.match(sql, /REVOKE ALL ON FUNCTION henvalt\.ingest_mailersend_webhook_v2/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION henvalt\.ingest_mailersend_webhook_v2[\s\S]*?TO service_role/);
});

test("n8n cutover specification blocks legacy event duplication and gates V2 sends", () => {
  const docs = readFileSync(new URL("../docs/n8n-v2-cutover-boundary.md", import.meta.url), "utf8");
  assert.ok(docs.includes("henvalt-mailersend-delivery"));
  assert.ok(docs.includes("verify_mailersend_webhook_signature_api"));
  assert.ok(docs.includes("process_mailersend_webhook_event"));
  assert.ok(docs.includes("henvalt-mailersend-webhook-v2"));
  assert.ok(docs.includes("HENVALT_V2_MAILERSEND_EVENTS_READY=true"));
  const normalizedDocs = docs.replace(/\s+/g, " ");
  assert.ok(normalizedDocs.includes("processed by both the legacy n8n route and V2 function"));
  assert.ok(normalizedDocs.includes("must not be adapted by simply changing its HTTP URL"));
  assert.ok(docs.includes("HENVALT_INGEST"));
  assert.ok(docs.includes("HENVALT_RECOVERY"));
  assert.ok(docs.includes("HENVALT_DELIVERY"));
  assert.ok(docs.includes('with exactly `{"intervention_id":"<UUID>"}`'));
  assert.ok(docs.includes('with exactly `{"opportunity_id":"<UUID>"}`'));
  assert.ok(docs.includes("Message-rendering contract is implemented in this branch."));
  assert.ok(docs.includes("mailer_send_v2_delivery_preflight_failed"));
  assert.doesNotMatch(docs, /with `intervention_id`, `subject`, `html`/);
  assert.doesNotMatch(docs, /with `opportunity_id`, `subject`, `html`/);
  assert.doesNotMatch(docs, /Both Edge Functions currently require subject and HTML\/text from the caller/);
});


test("V2 n8n cutover contract keeps legacy delivery separate and requires opaque claims", () => {
  const docs = readFileSync(new URL("../docs/shopify-v2-n8n-cutover-execution-contract-2026-11-19.md", import.meta.url), "utf8");
  for (const required of [
    "claim_shopify_recovery_work_v2",
    "materialize_shopify_checkout_interventions_v2",
    "CHECKOUT_INTERVENTION",
    "PIXEL_OPPORTUNITY",
    "henvalt-shopify-contact-delivery-v2",
    "henvalt-shopify-pixel-delivery-v2",
    "finish_shopify_recovery_work_claim_v2",
    "HANDOFF_ACCEPTED",
    "TERMINAL",
    "DEFERRED",
    "henvalt-mailersend-webhook-v2",
    "original raw request body",
    "No-send dry-run acceptance suite",
    "hard-coded historical delivery request and recipient address",
    "No production send, billing, PR merge or deployment is authorized",
  ]) assert.ok(docs.includes(required), required);
  assert.match(docs, /exactly one finish outcome/);
  assert.match(docs, /Never retry a possibly submitted provider call as a fresh send/);
  assert.match(docs, /Never proxy parsed\/re-serialized JSON/);
  assert.match(docs, /must not be on the V2 send path/);
  assert.doesNotMatch(docs, /recipient email.*payload/i);
});
