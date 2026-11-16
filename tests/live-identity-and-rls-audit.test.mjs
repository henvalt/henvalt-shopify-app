import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const identityAudit = readFileSync(
  new URL("../docs/shopify-to-henvalt-identity-propagation-audit.md", import.meta.url),
  "utf8",
);
const rlsAudit = readFileSync(
  new URL("../docs/live-rls-grants-security-advisor-audit.md", import.meta.url),
  "utf8",
);

test("identity propagation audit records the live ingress and release contract", () => {
  for (const phrase of [
    "henvalt-clean-ingress-v1",
    "verify_shopify_webhook_hmac",
    "resolve_shopify_tenant",
    "app_key + shopify_connection_id",
    "HENVALT_INGEST",
    "HENVALT_RECOVERY",
    "HENVALT_DELIVERY",
    "henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks",
    "12 topics",
    "henvalt_shopify_app_secret",
    "control_plane_connect_shop",
    "same-store collision risk",
    "authorize_delivery_request",
    "never delete the entire tenant",
    "No production changes were made",
  ]) {
    assert.ok(identityAudit.includes(phrase), `identity audit missing: ${phrase}`);
  }
});

test("live RLS audit distinguishes intentional service-only tables from the SECURITY DEFINER warning", () => {
  for (const phrase of [
    "Every base table returned in the `henvalt` schema has row-level security enabled",
    "No direct table grants to anon or authenticated",
    "is_tenant_member(p_tenant_id uuid)",
    "search_path",
    "auth.uid()",
    "Do not blindly revoke it",
    "leaked-password protection disabled",
    "No production changes were made",
  ]) {
    assert.ok(rlsAudit.includes(phrase), `RLS audit missing: ${phrase}`);
  }
});
