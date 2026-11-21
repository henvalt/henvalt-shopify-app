import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const snapshot = JSON.parse(readFileSync(
  new URL("./fixtures/n8n-recovery-route-snapshot.json", import.meta.url),
  "utf8",
));

test("active recovery scheduler currently claims only intervention jobs", () => {
  assert.equal(snapshot.schedulerTrigger, "Every Minute");
  assert.equal(snapshot.claimNode, "Claim Due Job");
  assert.equal(snapshot.claimFunction, "henvalt.claim_next_job");
  assert.deepEqual(snapshot.activeClaimJobTypes, ["execute_intervention"]);
});

test("current background job inventory has no Shopify webhook replay jobs", () => {
  assert.deepEqual(snapshot.observedBackgroundJobTypes, [
    "execute_intervention",
    "HENVALT_TEST_JOB",
  ]);
  assert.equal(snapshot.requiredReplayJobType, "process_shopify_webhook");
  assert.equal(snapshot.replayJobTypeCurrentlyClaimed, false);
});

test("stale repair and payment reconciliation are not general webhook replay", () => {
  assert.deepEqual(snapshot.staleRepairFunctions, [
    "henvalt.requeue_stale_jobs(900)",
    "henvalt.recover_stale_interventions(900)",
  ]);
  assert.equal(snapshot.paymentReconciliationFunction, "henvalt.reconcile_deferred_payment_webhooks");
  assert.equal(snapshot.generalWebhookReplayRpcPresent, false);
  assert.equal(snapshot.generalWebhookReplayLaunchBlocker, true);
});

test("replay jobs cannot pass the current intervention-only worker guard", () => {
  assert.equal(snapshot.normalizeGuard.currentHasJobExpression, "jobId != null && interventionId != null");
  assert.equal(snapshot.normalizeGuard.requiresInterventionId, true);
  assert.equal(snapshot.normalizeGuard.replayPayloadHasInterventionId, false);
  assert.equal(snapshot.normalizeGuard.replayJobsPassCurrentGuard, false);
  assert.equal(snapshot.normalizeGuard.requiresJobTypeRouter, true);
});
