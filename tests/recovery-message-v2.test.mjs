import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { renderRecoveryMessageV2, mailerSendUnsubscribeReady } from "../supabase/functions/_shared/recovery-message-v2.mjs";

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

test("MailerSend unsubscribe gate requires verified exact sender domain and both HTML/plain tracking", async () => {
  const fetcher = async (_url, options) => {
    assert.equal(options.method, "GET");
    assert.equal(options.headers.authorization, "Bearer " + "x".repeat(24));
    return {
      ok: true,
      json: async () => ({ data: [{
        name: "mail.merchant.com",
        is_verified: true,
        domain_settings: {
          track_unsubscribe: true,
          track_unsubscribe_html_enabled: true,
          track_unsubscribe_plain_enabled: true,
        },
      }] }),
    };
  };
  assert.equal(await mailerSendUnsubscribeReady("x".repeat(24), "recovery@mail.merchant.com", fetcher), true);
});

test("MailerSend unsubscribe gate fails closed for missing, unverified or incomplete domain settings", async () => {
  const payloads = [
    { data: [] },
    { data: [{ name: "merchant.com", is_verified: false, domain_settings: { track_unsubscribe: true, track_unsubscribe_html_enabled: true, track_unsubscribe_plain_enabled: true } }] },
    { data: [{ name: "merchant.com", is_verified: true, domain_settings: { track_unsubscribe: true, track_unsubscribe_html_enabled: true, track_unsubscribe_plain_enabled: false } }] },
    { data: [{ name: "merchant.com", is_verified: true, domain_settings: { track_unsubscribe: false, track_unsubscribe_html_enabled: true, track_unsubscribe_plain_enabled: true } }] },
  ];
  for (const payload of payloads) {
    assert.equal(await mailerSendUnsubscribeReady("x".repeat(24), "recovery@merchant.com", async () => ({
      ok: true, json: async () => payload,
    })), false);
  }
  assert.equal(await mailerSendUnsubscribeReady("short", "recovery@merchant.com", async () => { throw new Error("must not fetch"); }), false);
  assert.equal(await mailerSendUnsubscribeReady("x".repeat(24), "invalid", async () => { throw new Error("must not fetch"); }), false);
  assert.equal(await mailerSendUnsubscribeReady("x".repeat(24), "recovery@merchant.com", async () => ({ ok: false })), false);
  assert.equal(await mailerSendUnsubscribeReady("x".repeat(24), "recovery@merchant.com", async () => { throw new Error("network"); }), false);
});

test("checkout and pixel Edge Functions accept only opaque work identifiers and render messages server-side", async () => {
  const checkout = readFileSync(new URL("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts", import.meta.url), "utf8");
  const pixel = readFileSync(new URL("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts", import.meta.url), "utf8");
  for (const edge of [checkout, pixel]) {
    assert.match(edge, /resolve_shopify_recovery_message_context_v2/);
    assert.match(edge, /mailerSendUnsubscribeReady/);
    assert.match(edge, /renderRecoveryMessageV2/);
    assert.match(edge, /subject:message.subject/);
    assert.match(edge, /html:message.html/);
    assert.match(edge, /text:message.text/);
    assert.match(edge, /mailer_send_unsubscribe_tracking_not_enabled/);
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
  assert.match(pixel, /key!=="opportunity_id"/);
  assert.match(pixel, /providerSubmissionStarted=true/);
  assert.ok(pixel.includes('providerSubmissionStarted?"AMBIGUOUS":"FAILED"'));
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
});
