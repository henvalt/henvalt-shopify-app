import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const snapshot = JSON.parse(readFileSync(
  new URL("./fixtures/n8n-delivery-route-snapshot.json", import.meta.url),
  "utf8",
));
const workflow = snapshot.workflow;

function hasEdge(route, from, to) {
  return route.edges.some(([source, target]) => source === from && target === to);
}

test("snapshot is pinned to the inspected active HENVALT_DELIVERY version", () => {
  assert.equal(workflow.name, "HENVALT_DELIVERY");
  assert.equal(workflow.id, "CvVyybGJZSnklxiZ");
  assert.equal(workflow.active_version_id, "621ae6ce-a006-4fed-a70e-acf774c360fb");
});

test("ordinary delivery cannot reach provider send without authorization gates", () => {
  const route = workflow.routes.find((item) => item.id === "ordinary");
  assert.ok(route, "ordinary route snapshot is required");
  assert.ok(hasEdge(route, "Internal Delivery Webhook", "Validate & Normalize"));
  assert.ok(hasEdge(route, "Validate & Normalize", "Precheck Valid?"));
  assert.ok(hasEdge(route, "Precheck Valid?", "Authorize & Context"));
  assert.ok(hasEdge(route, "Authorize & Context", "Cleared to Send?"));
  assert.ok(hasEdge(route, "Cleared to Send?", "Build Reply-To Address"));
  assert.ok(hasEdge(route, "Build Reply-To Address", "MailerSend Send"));
  assert.equal(route.provider_node, "MailerSend Send");
});

test("manual one-off route is a separate provider-send entry point with its own gate", () => {
  const route = workflow.routes.find((item) => item.id === "manual-one-off");
  assert.ok(route, "manual one-off route snapshot is required");
  assert.ok(hasEdge(route, "One-Off Test Email Trigger", "Prepare One-Off Test Delivery"));
  assert.ok(hasEdge(route, "Prepare One-Off Test Delivery", "One-Off Test Authorized?"));
  assert.ok(hasEdge(route, "One-Off Test Authorized?", "MailerSend One-Off Test Email"));
  assert.equal(route.provider_node, "MailerSend One-Off Test Email");
});

test("both outbound routes converge on the same provider authorization function", () => {
  assert.equal(workflow.routes.length, 2);
  for (const route of workflow.routes) {
    assert.equal(route.provider_method, "POST");
    assert.equal(route.provider_function_slug, workflow.provider_function_slug);
    assert.equal(route.provider_function_slug, "henvalt-mailersend-delivery");
  }
});

test("snapshot explicitly avoids representing read-only topology as send-block proof", () => {
  assert.ok(workflow.safety_notes.some((note) => note.includes("not proof")));
  assert.ok(workflow.safety_notes.some((note) => note.includes("provider egress denied")));
});
