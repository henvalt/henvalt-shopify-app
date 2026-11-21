import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const checkout = readFileSync("supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts", "utf8");
const webhook = readFileSync("supabase/functions/henvalt-mailersend-webhook-v2/index.ts", "utf8");
const helper = readFileSync("supabase/functions/_shared/request-body-v2.ts", "utf8");

test("shared request reader enforces streaming byte limits without trusting Content-Length", () => {
  assert.match(helper, /request\.body\?\.getReader\(\)/);
  assert.match(helper, /total > maxBytes/);
  assert.match(helper, /reader\.cancel\(\)/);
  assert.match(helper, /Number\(declared\) > maxBytes/);
});
test("JSON delivery requests require JSON content type, valid UTF-8 and an object body", () => {
  assert.match(helper, /application\\\/json/);
  assert.match(helper, /new TextDecoder\("utf-8", \{ fatal: true \}\)/);
  assert.match(helper, /Array\.isArray\(value\)/);
  assert.match(checkout, /readJsonObject\(req,160000\)/);
  assert.match(checkout, /invalid_delivery_request/);
});
test("checkout delivery no longer buffers an unbounded request with request.json()", () => {
  assert.match(checkout, /RequestBodyError/);
  assert.doesNotMatch(checkout, /await req\.json\(\)/);
});
test("MailerSend signed webhook body is bounded while streaming and parsed only after signature acceptance", () => {
  assert.match(webhook, /readBoundedBody\(req,1_000_000\)/);
  assert.doesNotMatch(webhook, /await req\.arrayBuffer\(\)/);
  assert.match(webhook, /fatal:true/);
  assert.match(webhook, /invalid_provider_event_body/);
  assert.match(webhook, /recipient_pii_stored:false/);
});
test("webhook body-size and content-type failures return bounded client errors", () => {
  assert.match(webhook, /BODY_TOO_LARGE/);
  assert.match(helper, /INVALID_CONTENT_TYPE/);
  assert.match(webhook, /BODY_TOO_LARGE"?\?413/);
});
