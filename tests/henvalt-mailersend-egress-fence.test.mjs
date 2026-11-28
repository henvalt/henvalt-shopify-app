import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(
  new URL("../supabase/functions/henvalt-mailersend-delivery/index.ts", import.meta.url),
  "utf8",
);

test("protected delivery worker restricts the ordinary path to generation one", () => {
  const generationGuard = source.indexOf("requestIdentity.generation_number !== 1");
  const credentialRelease = source.indexOf("/rpc/get_mailersend_token_for_delivery");
  assert.notEqual(generationGuard, -1, "generation-one guard must exist");
  assert.notEqual(credentialRelease, -1, "credential release RPC must exist");
  assert.ok(generationGuard < credentialRelease, "retry generations must be rejected before credential release");
});

test("durable provider egress fence is committed before MailerSend HTTP", () => {
  const fence = source.indexOf("/rpc/mark_mailersend_provider_egress_started");
  const provider = source.indexOf('fetch("https://api.mailersend.com/v1/email"');
  assert.notEqual(fence, -1, "durable egress fence RPC must exist");
  assert.notEqual(provider, -1, "MailerSend provider call must exist");
  assert.ok(fence < provider, "database egress fence must precede provider HTTP");
  assert.match(source, /provider_transport_ambiguous/);
});
