import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const oauth = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth-v2/index.ts", import.meta.url), "utf8");
const ingress = readFileSync(new URL("../supabase/functions/henvalt-shopify-webhook-ingress/index.ts", import.meta.url), "utf8");
const uninstall = readFileSync(new URL("../supabase/migrations/202611170009_shopify_exact_store_uninstall_processor_v2.sql", import.meta.url), "utf8");

test("OAuth registers only webhook topics with a durable V2 processing path", () => {
  const start = oauth.indexOf("const specs = [");
  const end = oauth.indexOf("];", start);
  assert.ok(start >= 0 && end > start, "OAuth webhook topic manifest must exist");
  const manifest = oauth.slice(start, end);
  const topics = [...manifest.matchAll(/topic:"([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(topics, [
    "orders/create",
    "orders/updated",
    "orders/paid",
    "orders/cancelled",
    "refunds/create",
    "checkouts/create",
    "checkouts/update",
    "customers_email_marketing_consent/update",
    "app/uninstalled",
  ]);
  for (const topic of topics) {
    if (topic === "app/uninstalled") {
      assert.match(uninstall, /WHEN \(NEW\.topic = 'app\/uninstalled'\)/);
    } else {
      assert.ok(ingress.includes(topic), `Ingress must explicitly route ${topic}`);
    }
  }
});

test("unprojected cart and transaction topics are not subscribed or silently acknowledged", () => {
  assert.doesNotMatch(oauth, /topic:"(?:carts\/(?:create|update)|order_transactions\/create)"/);
  assert.match(ingress, /return json\(422,\{error:"unsupported_topic"\}\)/);
  assert.doesNotMatch(ingress, /return json\(200,\{accepted:true,duplicate:receipt\.duplicate===true,status:receipt\.receipt_status\}\)/);
});
