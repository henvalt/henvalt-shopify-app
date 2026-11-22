import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const manifest = JSON.parse(readFileSync(new URL("../supabase/audit-baselines/deployed-2026-11-22/manifest.json", import.meta.url), "utf8"));

test("production Edge Function snapshots are pinned to the captured active versions", () => {
  assert.equal(manifest.project_id, "ocyplckdojdubyrsxcxa");
  assert.equal(manifest.functions.length, 5);
  const versions = Object.fromEntries(manifest.functions.map(f => [f.slug, f.version]));
  assert.deepEqual(versions, {
    "henvalt-shopify-privacy": 1,
    "henvalt-privacy-export": 1,
    "henvalt-merchant-dashboard": 4,
    "henvalt-shopify-oauth": 27,
    "henvalt-mailersend-delivery": 1
  });
  for (const f of manifest.functions) {
    assert.equal(f.status, "ACTIVE");
    assert.match(f.deployment_artifact_ezbr_sha256, /^[a-f0-9]{64}$/);
    assert.match(f.git_blob_sha, /^[a-f0-9]{40}$/);
    assert.ok(f.source_chars > 0 && f.source_lines > 0);
  }
});

test("each captured deployed entrypoint matches its immutable Git blob SHA", () => {
  for (const f of manifest.functions) {
    const source = readFileSync(new URL("../" + f.source_file.replace(/^supabase\//, "supabase/"), import.meta.url), "utf8");
    const header = Buffer.from("blob " + Buffer.byteLength(source, "utf8") + "\0");
    const actual = createHash("sha1").update(header).update(source, "utf8").digest("hex");
    assert.equal(actual, f.git_blob_sha, f.slug + " deployed source snapshot changed");
    assert.equal(source.length, f.source_chars);
    assert.equal(source.split("\n").length, f.source_lines);
  }
});

test("captured source files contain no common literal private-key or provider-token formats", () => {
  const patterns = [
    /sk_live_[A-Za-z0-9]+/,
    /whsec_[A-Za-z0-9]+/,
    /Bearer\s+[A-Za-z0-9._-]{24,}/i,
    /eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}\./,
    /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/
  ];
  for (const f of manifest.functions) {
    const source = readFileSync(new URL("../" + f.source_file, import.meta.url), "utf8");
    for (const pattern of patterns) assert.doesNotMatch(source, pattern, f.slug + " contains a credential-like literal");
  }
});
