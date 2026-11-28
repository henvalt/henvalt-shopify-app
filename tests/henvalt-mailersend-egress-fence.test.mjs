import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(
  new URL("../supabase/functions/henvalt-mailersend-delivery/index.ts", import.meta.url),
  "utf8",
);

test("protected delivery worker routes generations through the matching credential contract", () => {
  assert.match(source, /generationNumber === 1/);
  assert.match(source, /get_mailersend_token_for_delivery/);
  assert.match(source, /p_retry_job_id: retryJobId/);
  assert.match(source, /p_retry_worker_id: retryWorkerId/);
  assert.match(source, /p_generation_number: generationNumber/);
  assert.match(source, /retry_generation_requires_valid_lease/);
});

test("durable provider egress fence is committed before MailerSend HTTP for both generations", () => {
  const fence = source.indexOf("/rpc/mark_mailersend_provider_egress_started");
  const provider = source.indexOf('fetch("https://api.mailersend.com/v1/email"');
  assert.notEqual(fence, -1, "durable egress fence RPC must exist");
  assert.notEqual(provider, -1, "MailerSend provider call must exist");
  assert.ok(fence < provider, "database egress fence must precede provider HTTP");
  assert.match(source, /p_retry_job_id: retryJobId/);
  assert.match(source, /provider_transport_ambiguous/);
});
