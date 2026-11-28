import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const audit = JSON.parse(readFileSync(
  new URL("./fixtures/legacy-control-plane-billing-route-audit.json", import.meta.url),
  "utf8",
));

test("legacy control-plane billing route snapshot records the real deployed auth boundary", () => {
  assert.equal(audit.control_plane.slug, "henvalt-control-plane");
  assert.equal(audit.control_plane.deployed_version, 24);
  assert.equal(audit.control_plane.status, "ACTIVE");
  assert.equal(audit.control_plane.gateway_verify_jwt, false);
  assert.equal(audit.control_plane.handler_bearer_verifier, "henvalt.control_plane_verify_api_token");
  assert.equal(audit.control_plane.vault_secret_name, "HENVALT_CONTROL_PLANE_TOKEN");
  assert.deepEqual(audit.control_plane.billing_routes, [
    { method: "POST", path: "/v1/billing/usage/claim", rpc: "control_plane_claim_billing_usage" },
    { method: "POST", path: "/v1/billing/usage/result", rpc: "control_plane_record_billing_usage_result" },
  ]);
  assert.match(audit.control_plane.risk, /can downgrade SUBMITTED on a late failure/i);
  assert.match(audit.control_plane.database_acl, /service_role only/i);
});

test("none of the three inspected active n8n workflows calls the legacy usage routes", () => {
  assert.deepEqual(audit.active_workflows.map(w => w.name), [
    "HENVALT_INGEST",
    "HENVALT_RECOVERY",
    "HENVALT_DELIVERY",
  ]);
  assert.deepEqual(audit.active_workflows.map(w => w.id), [
    "VTpfGKNtu1CSQ4Rv",
    "3GEDoeCA4paXTaDF",
    "CvVyybGJZSnklxiZ",
  ]);
  assert.deepEqual(audit.active_workflows.map(w => w.active_version_id), [
    "6368d539-708f-494a-8be8-b9601d0e8607",
    "32e50bf7-4cbd-4070-bbba-f259ed17b369",
    "621ae6ce-a006-4fed-a70e-acf774c360fb",
  ]);
  for (const workflow of audit.active_workflows) {
    assert.deepEqual(workflow.observed_legacy_billing_route_calls, [], workflow.name);
  }
});

test("audit snapshot does not overclaim caller inventory or expose the Vault secret", () => {
  assert.ok(audit.limitations.some(x => /does not inventory every external caller/i.test(x)));
  assert.ok(audit.limitations.some(x => /no secret value/i.test(x)));
  assert.ok(audit.limitations.some(x => /must not be exposed as the merchant billing interface/i.test(x)));
  assert.equal(Object.hasOwn(audit.control_plane, "vault_secret_value"), false);
});
