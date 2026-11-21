import test from "node:test";
import assert from "node:assert/strict";
import { createNoSendTransport } from "../n8n/no-send-transport.mjs";

// Candidate inventory based on the read-only Delivery graph review.
// This is a transport-policy contract, not proof that live n8n nodes changed.
const senderPaths = [
  { name: "normal MailerSend Send node", path: "/v1/email" },
  { name: "One-Off Test Email node", path: "/v1/email" },
];

const nonSenderHandlers = [
  "tracking-link GET",
  "unsubscribe GET",
  "unsubscribe POST",
  "MailerSend events POST",
  "MailerSend inbound POST",
  "tracking-click confirmation POST",
];

test("candidate no-send contract blocks every inventoried provider sender path", async () => {
  const guard = createNoSendTransport();
  for (const sender of senderPaths) {
    await assert.rejects(
      () => guard.fetchImpl(`https://api.mailersend.com${sender.path}`, {
        method: "POST",
        body: JSON.stringify({ synthetic: true, sender: sender.name }),
      }),
      /no_send_transport_provider_blocked/,
    );
  }
  assert.equal(guard.blockedProviderAttempts, senderPaths.length);
  assert.equal(guard.attempts.every((attempt) => attempt.destination === "api.mailersend.com" && attempt.method === "POST"), true);
  assert.equal(JSON.stringify(guard.attempts).includes("synthetic"), false);
});

test("non-sender webhook handlers remain separately classified, not disabled by sender policy", () => {
  assert.deepEqual(nonSenderHandlers, [
    "tracking-link GET",
    "unsubscribe GET",
    "unsubscribe POST",
    "MailerSend events POST",
    "MailerSend inbound POST",
    "tracking-click confirmation POST",
  ]);
  assert.equal(senderPaths.some((sender) => nonSenderHandlers.includes(sender.name)), false);
});
