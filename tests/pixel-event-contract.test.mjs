import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const pixelSource = readFileSync("extensions/henvalt-pixel/src/index.js", "utf8");
const collectorSource = readFileSync("cloudflare/pixel-collector.js", "utf8");

function extractEvents(source, expression, label) {
  const match = source.match(expression);
  assert.ok(match, `Could not find ${label} event list`);
  return [...match[1].matchAll(/"([^"]+)"/g)].map((entry) => entry[1]).sort();
}

test("every subscribed Shopify pixel event is accepted by the Cloudflare collector", () => {
  const subscribed = extractEvents(
    pixelSource,
    /const ALLOWED_EVENTS = \[([\s\S]*?)\];/,
    "pixel subscription",
  );
  const accepted = extractEvents(
    collectorSource,
    /const ALLOWED_EVENTS = new Set\(\[([\s\S]*?)\]\);/,
    "collector allow-list",
  );

  assert.deepEqual(accepted, subscribed);
  assert.ok(subscribed.includes("product_removed_from_cart"));
});
