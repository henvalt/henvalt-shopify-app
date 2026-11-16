import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("privileged function access audit records the observed least-privilege boundary", () => {
  const audit = readFileSync(
    new URL("../docs/supabase-privileged-function-access-audit.md", import.meta.url),
    "utf8",
  );
  for (const required of [
    "SECURITY DEFINER",
    "`anon`: no EXECUTE",
    "`authenticated`: no EXECUTE except `is_tenant_member`",
    "`service_role`: EXECUTE",
    "cannot CREATE objects",
    "service-role key",
    "default privileges",
  ]) {
    assert.ok(audit.includes(required), `Missing access-audit assertion: ${required}`);
  }
});
