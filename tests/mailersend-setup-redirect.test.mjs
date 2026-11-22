import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const setup = readFileSync(
  new URL("../supabase/functions/henvalt-mailersend-setup/index.ts", import.meta.url),
  "utf8",
);

test("every provider setup network request refuses redirects", () => {
  const fetchCalls = setup.match(/\bfetch\s*\(/g) || [];
  const redirectGuards = setup.match(/redirect\s*:\s*"error"/g) || [];
  assert.equal(fetchCalls.length, 4, "expected auth, membership, MailerSend validation and save requests");
  assert.equal(redirectGuards.length, fetchCalls.length);
  assert.match(setup, /https:\/\/api\.mailersend\.com\/v1\/domains/);
});

test("merchant MailerSend token is only sent to the fixed MailerSend domains endpoint", () => {
  assert.match(setup, /fetch\("https:\/\/api\.mailersend\.com\/v1\/domains\?limit=100&verified=true"/);
  assert.match(setup, /authorization:"Bearer "\+token/);
  assert.doesNotMatch(setup, /fetch\(\s*body\.(?:url|endpoint|host)/);
});
