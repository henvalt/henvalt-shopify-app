import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildManifestSummary, canonicalJson, isCompleteExport, makeOpaqueObjectKey, serializeArtifact } from "../supabase/functions/henvalt-shopify-privacy-export-processor-v2/artifact-helpers.mjs";
const source = readFileSync(new URL("../supabase/functions/henvalt-shopify-privacy-export-processor-v2/index.ts", import.meta.url), "utf8");
test("canonical artifact serialization is deterministic and preserves array order", () => {
  assert.equal(canonicalJson({ z: 1, a: { y: 2, x: 3 } }), '{"a":{"x":3,"y":2},"z":1}');
  assert.equal(canonicalJson([2, 1]), "[2,1]");
});
test("manifest summary contains category names and counts only", () => {
  assert.deepEqual(buildManifestSummary({ orders: [{ customer_email: "private@example.com" }], customer_identity: { external_customer_reference: "secret-id" }, refunds: [] }),
    { schema_version: 1, categories: [{ name: "customer_identity", count: 1 }, { name: "orders", count: 1 }, { name: "refunds", count: 0 }] });
  assert.throws(() => buildManifestSummary({ "customer-email": [] }), /invalid export category/);
});
test("artifact gate rejects legacy review, wrong store and unverified identity", () => {
  const claim = { shop_domain: "store-a.myshopify.com", customer_id: "cust-1" };
  const valid = { exported: true, completion_eligible: true, legacy_scope_review_required: false, customer_identity_found: true,
    shop_domain: claim.shop_domain, shopify_customer_id: claim.customer_id, records: {}, review_code: null };
  assert.equal(isCompleteExport(valid, claim), true);
  assert.equal(isCompleteExport({ ...valid, legacy_scope_review_required: true }, claim), false);
  assert.equal(isCompleteExport({ ...valid, shop_domain: "store-b.myshopify.com" }, claim), false);
  assert.equal(isCompleteExport({ ...valid, customer_identity_found: false }, claim), false);
  assert.equal(isCompleteExport({ ...valid, completion_eligible: false }, claim), false);
});
test("object keys are opaque UUID filenames and artifact size is bounded", () => {
  assert.equal(makeOpaqueObjectKey("123e4567-e89b-42d3-a456-426614174000"), "123e4567-e89b-42d3-a456-426614174000.json");
  assert.throws(() => makeOpaqueObjectKey("../tenant/customer.json"), /UUID/);
  assert.throws(() => serializeArtifact({ data: "x".repeat(25 * 1024 * 1024) }), /size limit/);
});
test("processor checks completeness before metadata insert and private upload", () => {
  assert.match(source, /authorization !== "Bearer " \+ SERVICE_ROLE_KEY/);
  assert.match(source, /isCompleteExport\(draft, claim\)/);
  assert.ok(source.indexOf("if (!isCompleteExport(draft, claim))") < source.indexOf("const insertResponse = await rest("));
  assert.ok(source.indexOf("if (!isCompleteExport(draft, claim))") < source.indexOf("/storage/v1/object/"));
  assert.match(source, /state: "STAGED"/);
  assert.match(source, /\/storage\/v1\/object\//);
  assert.match(source, /private_object_integrity_mismatch/);
  assert.match(source, /"x-upsert": "false"/);
  assert.match(source, /state: "AVAILABLE"/);
  assert.doesNotMatch(source, /console\.(log|error)\(/);
  assert.doesNotMatch(source, /createSignedUrl|publicUrl/);
});
