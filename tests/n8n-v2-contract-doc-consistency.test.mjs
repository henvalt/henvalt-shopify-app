import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = path => readFileSync(new URL(path, import.meta.url), "utf8");
const buildSheet = read("../docs/n8n-native-v2-three-workflow-build-sheet-2026-11-19.md");
const cutoverContract = read("../docs/shopify-v2-n8n-cutover-execution-contract-2026-11-19.md");
const snippets = read("../n8n/v2-n8n-code-node-snippets.md");
const adapter = read("../n8n/v2-handoff-adapter.mjs");

test("three-workflow V2 documentation and runtime agree on the exact correlation ID contract", () => {
  assert.match(buildSheet, /correlation ID `v2:<work_id>`/);
  assert.match(cutoverContract, /"correlation_id": "v2:<work_id>"/);
  assert.match(cutoverContract, /require `correlation_id` to equal exactly `v2:<work_id>`/);
  assert.match(snippets, /correlation_id: `v2:\$\{item\.work_id\}`/);
  assert.match(adapter, /value !== `v2:\$\{workId\}`/);
  assert.match(adapter, /correlation_id: valid\.correlationId/);
});

test("V2 automation remains exactly three named workflows with strict responsibility boundaries", () => {
  for (const name of ["HENVALT_INGEST", "HENVALT_RECOVERY", "HENVALT_DELIVERY"]) {
    assert.ok(buildSheet.includes(name), `missing workflow contract for ${name}`);
  }
  assert.match(buildSheet, /Preserve exactly three production workflows/);
  assert.match(buildSheet, /must not render messages, resolve recipients, call MailerSend/i);
  assert.match(buildSheet, /must not call legacy send RPCs/i);
  assert.match(buildSheet, /must not receive the same V2 Shopify callback/i);
});
