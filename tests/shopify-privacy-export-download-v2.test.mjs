import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/functions/henvalt-shopify-privacy-export-download-v2/index.ts", import.meta.url), "utf8");

test("privacy export download authenticates a real Supabase user and derives tenant scope server-side", () => {
  assert.match(source, /\/auth\/v1\/user/);
  assert.match(source, /user_id=eq\./);
  assert.match(source, /role=in\.\(OWNER,ADMIN\)/);
  assert.match(source, /m\.tenant_id === artifact\.tenant_id/);
  assert.doesNotMatch(source, /body\?\.tenant_id|body\?\.shop_domain|body\?\.connection_id/);
});

test("privacy export download revalidates active tenant, exact connection, and immutable receipt binding", () => {
  assert.match(source, /tenants\?select=id,status/);
  assert.match(source, /tenants\[0\]\?\.status !== "ACTIVE"/);
  assert.match(source, /shopify_connections\?select=id,tenant_id,app_key,shop_domain,active/);
  assert.match(source, /connection\.active !== true/);
  assert.match(source, /shopify_privacy_webhook_deliveries\?select=id,tenant_id,connection_id,app_key,shop_domain/);
  assert.match(source, /receipt\.connection_id !== artifact\.connection_id/);
  assert.match(source, /receipt\.app_key !== artifact\.app_key/);
  assert.match(source, /receipt\.shop_domain !== artifact\.shop_domain/);
});

test("only complete, available, unexpired opaque artifacts are streamed from the private bucket", () => {
  assert.match(source, /artifact\.state !== "AVAILABLE"/);
  assert.match(source, /COMPLETE_FOR_MERCHANT_REVIEW/);
  assert.match(source, /expiresAt <= Date\.now\(\)/);
  assert.match(source, /henvalt-privacy-exports-v2/);
  assert.match(source, /object_key/);
  assert.match(source, /crypto\.subtle\.digest\("SHA-256"/);
  assert.match(source, /bytes\.byteLength !== Number\(artifact\.byte_count\)/);
  assert.match(source, /digest !== artifact\.sha256_hex/);
  assert.doesNotMatch(source, /createSignedUrl|signedUrl|publicUrl/);
});

test("download evidence is append-only and never claims subject delivery", () => {
  assert.match(source, /DOWNLOAD_AUTHORIZED/);
  assert.match(source, /DOWNLOAD_STREAM_STARTED/);
  assert.match(source, /DOWNLOAD_STREAM_FAILED/);
  assert.doesNotMatch(source, /MERCHANT_ATTESTED_PROVIDED_TO_SUBJECT/);
  assert.match(source, /cache-control/);
  assert.match(source, /x-content-type-options/);
  assert.match(source, /content-disposition/);
});
