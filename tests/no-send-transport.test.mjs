import test from "node:test";
import assert from "node:assert/strict";
import { createNoSendTransport } from "../n8n/no-send-transport.mjs";

test("no-send transport blocks MailerSend without exposing request payload", async () => {
  const guard = createNoSendTransport();
  await assert.rejects(
    () => guard.fetchImpl("https://api.mailersend.com/v1/email?token=synthetic-secret", {
      method: "POST",
      headers: { authorization: "Bearer synthetic-secret" },
      body: JSON.stringify({ to: "private@example.invalid", text: "private body" }),
    }),
    /no_send_transport_provider_blocked/,
  );
  assert.equal(guard.blockedProviderAttempts, 1);
  assert.deepEqual(guard.attempts, [{ destination: "api.mailersend.com", method: "POST" }]);
  assert.equal(JSON.stringify(guard.attempts).includes("synthetic-secret"), false);
  assert.equal(JSON.stringify(guard.attempts).includes("private@example.invalid"), false);
  assert.equal(JSON.stringify(guard.attempts).includes("private body"), false);
});

test("no-send transport blocks MailerSend apex and subdomains, including terminal-dot DNS names", async () => {
  const guard = createNoSendTransport({
    allowedHosts: ["mailersend.com", "api.mailersend.com", "events.mailersend.com", "mailersend.com.", "api.mailersend.com."],
  });
  const hosts = [
    "mailersend.com",
    "api.mailersend.com",
    "events.mailersend.com",
    "mailersend.com.",
    "api.mailersend.com.",
    "events.mailersend.com.",
    "events.mailersend.com..",
  ];
  for (const host of hosts) {
    await assert.rejects(
      () => guard.fetchImpl(`https://${host}/path?token=synthetic-secret`, {
        method: "POST",
        headers: { authorization: "Bearer synthetic-secret" },
        body: "private@example.invalid",
      }),
      /no_send_transport_provider_blocked/,
    );
  }
  assert.equal(guard.blockedProviderAttempts, hosts.length);
  assert.deepEqual(guard.attempts, hosts.map((host) => ({
    destination: host.replace(/\.+$/, ""),
    method: "POST",
  })));
  assert.equal(JSON.stringify(guard.attempts).includes("synthetic-secret"), false);
  assert.equal(JSON.stringify(guard.attempts).includes("private@example.invalid"), false);
});

test("no-send transport rejects unapproved hosts and non-HTTPS destinations", async () => {
  const guard = createNoSendTransport();
  await assert.rejects(
    () => guard.fetchImpl("https://unapproved.example.invalid/path?recipient=private@example.invalid"),
    /no_send_transport_destination_blocked/,
  );
  await assert.rejects(
    () => guard.fetchImpl("http://edge.invalid/path"),
    /no_send_transport_destination_blocked/,
  );
  assert.equal(guard.blockedUnapprovedAttempts, 1); // only the unapproved hostname; HTTP is separately rejected by protocol policy
  assert.deepEqual(guard.attempts, [
    { destination: "unapproved.example.invalid", method: "GET" },
    { destination: "edge.invalid", method: "GET" },
  ]);
});


test("no-send transport blocks uppercase MailerSend Request URLs and repeated terminal dots", async () => {
  const guard = createNoSendTransport();
  const request = new Request("https://API.MAILERSEND.COM../v1/email?token=synthetic-secret", {
    method: "POST",
    headers: { authorization: "Bearer synthetic-secret" },
    body: "private@example.invalid",
  });
  await assert.rejects(
    () => guard.fetchImpl(request),
    /no_send_transport_provider_blocked/,
  );
  assert.deepEqual(guard.attempts, [{ destination: "api.mailersend.com", method: "POST" }]);
  assert.equal(guard.blockedProviderAttempts, 1);
  assert.equal(JSON.stringify(guard.attempts).includes("synthetic-secret"), false);
  assert.equal(JSON.stringify(guard.attempts).includes("private@example.invalid"), false);
});

test("no-send transport never performs network I/O even for allowlisted synthetic hosts", async () => {
  const guard = createNoSendTransport({ allowedHosts: ["edge.invalid"] });
  await assert.rejects(
    () => guard.fetchImpl("https://edge.invalid/synthetic-endpoint", { method: "POST" }),
    /no_send_transport_mock_response_required/,
  );
  assert.equal(guard.attempts.length, 1);
  assert.equal(guard.blockedProviderAttempts, 0);
  assert.equal(guard.blockedUnapprovedAttempts, 0);
});
