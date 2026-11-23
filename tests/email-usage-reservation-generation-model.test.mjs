import test from "node:test";
import assert from "node:assert/strict";

// Executable reference model for the proposed delivery-generation contract.
// This is intentionally not production code and makes no network/database calls.
// PostgreSQL two-session acceptance is still required before implementation.

class GenerationModel {
  constructor() {
    this.parents = new Map();
    this.events = new Set();
  }

  parent(id) {
    if (!this.parents.has(id)) {
      this.parents.set(id, { id, frozen: false, incident: null, generations: [], retryCommands: new Map() });
    }
    return this.parents.get(id);
  }

  current(parentId) {
    const p = this.parent(parentId);
    return p.generations.at(-1) || null;
  }

  initial(parentId) {
    const p = this.parent(parentId);
    if (p.generations.length) return p.generations[0];
    return this.insertGeneration(p, 1, "initial");
  }

  insertGeneration(parent, number, commandKey) {
    const g = {
      parentId: parent.id,
      number,
      requestId: `request-${parent.id}-${number}`,
      idempotencyKey: `deliver:${parent.id}:g${number}`,
      commandKey,
      state: "PENDING",
      reservation: "NONE",
      egressStarted: false,
      providerMessageIds: [],
      eventIds: new Set(),
      history: ["CREATED"],
    };
    parent.generations.push(g);
    if (commandKey) parent.retryCommands.set(commandKey, g);
    return g;
  }

  retry(parentId, commandKey, trusted = true) {
    const p = this.parent(parentId);
    if (!trusted) throw new Error("UNTRUSTED_RETRY_COMMAND");
    if (!commandKey) throw new Error("MISSING_RETRY_COMMAND_KEY");
    if (p.retryCommands.has(commandKey)) return p.retryCommands.get(commandKey);
    const previous = this.current(parentId);
    if (!previous || previous.state !== "PRE_PROVIDER_FAILED" ||
        previous.reservation !== "RELEASED" || previous.egressStarted) {
      throw new Error("PREVIOUS_GENERATION_NOT_PROVEN_RETRYABLE");
    }
    if (p.frozen) throw new Error("INTERVENTION_FROZEN");
    return this.insertGeneration(p, previous.number + 1, commandKey);
  }

  claim(g, { consent = true, interlockOpen = true, tenantActive = true } = {}) {
    const p = this.parent(g.parentId);
    if (p.frozen || this.current(g.parentId) !== g || g.state !== "PENDING") return false;
    if (!consent || !interlockOpen || !tenantActive) return false;
    g.state = "CLAIMED_PRE_PROVIDER";
    g.reservation = "RESERVED";
    g.history.push("CLAIMED_PRE_PROVIDER");
    return true;
  }

  startEgress(g) {
    const p = this.parent(g.parentId);
    if (p.frozen || this.current(g.parentId) !== g ||
        g.state !== "CLAIMED_PRE_PROVIDER" || g.egressStarted) return false;
    // Durable fence is set before the external provider call.
    g.egressStarted = true;
    g.state = "PROVIDER_IN_FLIGHT";
    g.history.push("PROVIDER_EGRESS_STARTED");
    return true;
  }

  preProviderFailure(g, { serverProof = false } = {}) {
    if (!serverProof || g.egressStarted || g.state !== "CLAIMED_PRE_PROVIDER") {
      throw new Error("PRE_PROVIDER_PROOF_REJECTED");
    }
    g.state = "PRE_PROVIDER_FAILED";
    g.reservation = "RELEASED";
    g.history.push("PRE_PROVIDER_FAILED", "RESERVATION_RELEASED");
    return true;
  }

  providerResult(g, outcome, providerMessageId = null) {
    if (g.state !== "PROVIDER_IN_FLIGHT" || !g.egressStarted) {
      throw new Error("NO_PROVIDER_EGRESS_IN_PROGRESS");
    }
    if (outcome === "ACCEPTED") {
      g.state = "ACCEPTED";
      g.reservation = "CONSUMED";
      if (providerMessageId) g.providerMessageIds.push(providerMessageId);
    } else if (outcome === "AMBIGUOUS") {
      g.state = "AMBIGUOUS";
      // Existing policy counts/holds uncertain provider egress conservatively.
      g.reservation = "CONSUMED";
    } else if (outcome === "DEFINITIVE_REJECTION") {
      g.state = "REJECTED_BY_PROVIDER";
      g.reservation = "RELEASED";
    } else {
      throw new Error("UNKNOWN_PROVIDER_OUTCOME");
    }
    g.history.push(g.state);
  }

  lateAcceptance(g, eventId, providerMessageId) {
    if (this.events.has(eventId)) return false;
    this.events.add(eventId);
    const p = this.parent(g.parentId);
    const previousReservation = g.reservation;
    g.reservation = "CONSUMED";
    if (providerMessageId && !g.providerMessageIds.includes(providerMessageId)) {
      g.providerMessageIds.push(providerMessageId);
    }
    g.history.push("LATE_ACCEPTANCE", `RESERVATION_${previousReservation}_TO_CONSUMED`);
    if (g.state === "PRE_PROVIDER_FAILED" || this.current(g.parentId) !== g) {
      p.frozen = true;
      p.incident = "CONTRADICTORY_LATE_ACCEPTANCE";
    } else {
      g.state = "ACCEPTED";
    }
    return true;
  }

  reconcile(g, { matches, complete }) {
    if (g.state !== "AMBIGUOUS") throw new Error("GENERATION_NOT_AMBIGUOUS");
    if (!complete || matches.length === 0) return "UNRESOLVED";
    if (matches.length > 1) {
      for (const id of matches) if (!g.providerMessageIds.includes(id)) g.providerMessageIds.push(id);
      const p = this.parent(g.parentId);
      p.frozen = true;
      p.incident = "MULTIPLE_PROVIDER_MATCHES";
      g.history.push("DUPLICATE_PROVIDER_EVIDENCE");
      return "DUPLICATE_INCIDENT";
    }
    g.state = "ACCEPTED";
    g.reservation = "CONSUMED";
    g.providerMessageIds.push(matches[0]);
    g.history.push("RECONCILED_ACCEPTANCE");
    return "ACCEPTED";
  }

  recoverReplay(parentId) {
    return this.current(parentId);
  }
}

function setupFailedGeneration(parentId = "intervention-A") {
  const model = new GenerationModel();
  const g1 = model.initial(parentId);
  assert.equal(model.claim(g1), true);
  model.preProviderFailure(g1, { serverProof: true });
  return { model, g1 };
}

test("01 first generation starts at one with a stable parent identity", () => {
  const m = new GenerationModel();
  const g = m.initial("i1");
  assert.equal(g.number, 1);
  assert.equal(g.parentId, "i1");
  assert.equal(g.idempotencyKey, "deliver:i1:g1");
});

test("02 duplicate retry-command key returns the same generation", () => {
  const { model, g1 } = setupFailedGeneration();
  const a = model.retry(g1.parentId, "retry-command-1");
  const b = model.retry(g1.parentId, "retry-command-1");
  assert.equal(a, b);
  assert.equal(model.parent(g1.parentId).generations.length, 2);
});

test("03 serialized distinct retry commands cannot create two current generations", () => {
  const { model, g1 } = setupFailedGeneration();
  const first = model.retry(g1.parentId, "retry-A");
  assert.throws(() => model.retry(g1.parentId, "retry-B"), /NOT_PROVEN_RETRYABLE/);
  assert.equal(model.parent(g1.parentId).generations.length, 2);
  assert.equal(model.current(g1.parentId), first);
});

test("04 retry before prior terminal pre-provider failure is rejected", () => {
  const m = new GenerationModel();
  const g1 = m.initial("i4");
  assert.throws(() => m.retry("i4", "r4"), /NOT_PROVEN_RETRYABLE/);
});

test("05 trusted pre-provider failure permits exactly the next generation", () => {
  const { model, g1 } = setupFailedGeneration("i5");
  const g2 = model.retry("i5", "retry-5");
  assert.equal(g2.number, 2);
  assert.notEqual(g2.requestId, g1.requestId);
  assert.notEqual(g2.idempotencyKey, g1.idempotencyKey);
});

test("06 an untrusted pre-provider marker cannot release quota or permit retry", () => {
  const m = new GenerationModel();
  const g1 = m.initial("i6");
  assert.equal(m.claim(g1), true);
  assert.throws(() => m.preProviderFailure(g1, { serverProof: false }), /PROOF_REJECTED/);
  assert.equal(g1.reservation, "RESERVED");
  assert.throws(() => m.retry("i6", "retry-6"), /NOT_PROVEN_RETRYABLE/);
});

test("07 a generation with provider egress started cannot be retried", () => {
  const m = new GenerationModel();
  const g1 = m.initial("i7");
  m.claim(g1);
  m.startEgress(g1);
  assert.throws(() => m.retry("i7", "retry-7"), /NOT_PROVEN_RETRYABLE/);
});

test("08 timeout after egress remains ambiguous and cannot be retried", () => {
  const m = new GenerationModel();
  const g1 = m.initial("i8");
  m.claim(g1);
  m.startEgress(g1);
  m.providerResult(g1, "AMBIGUOUS");
  assert.equal(g1.state, "AMBIGUOUS");
  assert.equal(g1.reservation, "CONSUMED");
  assert.throws(() => m.retry("i8", "retry-8"), /NOT_PROVEN_RETRYABLE/);
});

test("09 provider 409, 429 and 5xx are represented as ambiguity, never retry permission", () => {
  for (const status of [409, 429, 500, 502, 503]) {
    const m = new GenerationModel();
    const g = m.initial("status-" + status);
    m.claim(g); m.startEgress(g); m.providerResult(g, "AMBIGUOUS");
    assert.equal(g.state, "AMBIGUOUS", String(status));
    assert.throws(() => m.retry(g.parentId, "retry-" + status), /NOT_PROVEN_RETRYABLE/);
  }
});

test("10 provider acceptance consumes the generation reservation", () => {
  const m = new GenerationModel();
  const g = m.initial("i10");
  m.claim(g); m.startEgress(g); m.providerResult(g, "ACCEPTED", "msg-10");
  assert.equal(g.state, "ACCEPTED");
  assert.equal(g.reservation, "CONSUMED");
  assert.deepEqual(g.providerMessageIds, ["msg-10"]);
});

test("11 late acceptance upgrades a released reservation and preserves event history", () => {
  const { model, g1 } = setupFailedGeneration("i11");
  assert.equal(g1.reservation, "RELEASED");
  model.lateAcceptance(g1, "provider-event-11", "msg-11");
  assert.equal(g1.reservation, "CONSUMED");
  assert.ok(g1.history.includes("RESERVATION_RELEASED_TO_CONSUMED"));
  assert.ok(g1.history.includes("PRE_PROVIDER_FAILED"));
});

test("12 duplicate provider acceptance event is idempotent", () => {
  const { model, g1 } = setupFailedGeneration("i12");
  assert.equal(model.lateAcceptance(g1, "same-event", "msg-12"), true);
  const historyLength = g1.history.length;
  assert.equal(model.lateAcceptance(g1, "same-event", "msg-12"), false);
  assert.equal(g1.history.length, historyLength);
  assert.equal(g1.providerMessageIds.length, 1);
});

test("13 contradictory late acceptance after a later generation freezes the parent", () => {
  const { model, g1 } = setupFailedGeneration("i13");
  const g2 = model.retry("i13", "retry-13");
  model.lateAcceptance(g1, "late-event-13", "msg-old");
  assert.equal(model.parent("i13").frozen, true);
  assert.equal(model.parent("i13").incident, "CONTRADICTORY_LATE_ACCEPTANCE");
  assert.equal(model.claim(g2), false);
  assert.equal(g1.reservation, "CONSUMED");
});

test("14 multiple provider matches freeze the parent and retain every provider ID", () => {
  const m = new GenerationModel();
  const g = m.initial("i14");
  m.claim(g); m.startEgress(g); m.providerResult(g, "AMBIGUOUS");
  assert.equal(m.reconcile(g, { matches: ["msg-A", "msg-B"], complete: true }), "DUPLICATE_INCIDENT");
  assert.equal(m.parent("i14").frozen, true);
  assert.equal(m.parent("i14").incident, "MULTIPLE_PROVIDER_MATCHES");
  assert.equal(g.state, "AMBIGUOUS");
});

test("15 incomplete or empty provider lookup leaves ambiguity unresolved", () => {
  for (const result of [
    { matches: [], complete: false },
    { matches: [], complete: true },
  ]) {
    const m = new GenerationModel();
    const g = m.initial("i15-" + String(result.complete));
    m.claim(g); m.startEgress(g); m.providerResult(g, "AMBIGUOUS");
    assert.equal(m.reconcile(g, result), "UNRESOLVED");
    assert.equal(g.state, "AMBIGUOUS");
    assert.equal(g.reservation, "CONSUMED");
  }
});

test("16 stale generation worker cannot claim after a newer generation exists", () => {
  const { model, g1 } = setupFailedGeneration("i16");
  const g2 = model.retry("i16", "retry-16");
  assert.equal(model.claim(g1), false);
  assert.equal(model.claim(g2), true);
});

test("17 stale generation cannot cross provider-egress fence", () => {
  const { model, g1 } = setupFailedGeneration("i17");
  model.retry("i17", "retry-17");
  assert.equal(model.startEgress(g1), false);
});

test("18 new generation does not bypass consent, tenant status or global interlock", () => {
  const { model, g1 } = setupFailedGeneration("i18");
  const g2 = model.retry("i18", "retry-18");
  assert.equal(model.claim(g2, { consent: false }), false);
  assert.equal(model.claim(g2, { interlockOpen: false }), false);
  assert.equal(model.claim(g2, { tenantActive: false }), false);
  assert.equal(g2.reservation, "NONE");
});

test("19 replaying recovery without an explicit retry command does not increment generation", () => {
  const { model, g1 } = setupFailedGeneration("i19");
  const g2 = model.retry("i19", "retry-19");
  assert.equal(model.recoverReplay("i19"), g2);
  assert.equal(model.recoverReplay("i19"), g2);
  assert.equal(model.parent("i19").generations.length, 2);
  assert.equal(g1.number, 1);
});

test("20 generation numbers and request identities remain monotonic and immutable", () => {
  const { model, g1 } = setupFailedGeneration("i20");
  const original = { number: g1.number, requestId: g1.requestId, key: g1.idempotencyKey };
  const g2 = model.retry("i20", "retry-20");
  assert.deepEqual(
    { number: g1.number, requestId: g1.requestId, key: g1.idempotencyKey },
    original,
  );
  assert.equal(g2.number, 2);
  assert.notEqual(g2.requestId, g1.requestId);
  assert.notEqual(g2.idempotencyKey, g1.idempotencyKey);
});
