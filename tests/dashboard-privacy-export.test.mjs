import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dashboard = readFileSync("dashboard/index.html", "utf8");

test("dashboard exposes privacy requests only inside the signed-in workspace", () => {
  assert.match(dashboard, /data-page="privacy"/);
  assert.match(dashboard, /id="page-privacy"/);
  assert.match(dashboard, /async function loadPrivacyRequests\(\)/);
  assert.match(dashboard, /Authorization:"Bearer "\+token/);
  assert.match(dashboard, /PRIVACY_EXPORT/);
});

test("dashboard acknowledges the complete export response before initiating a local download", () => {
  const bodyRead = dashboard.indexOf("const blob=await response.blob()");
  const acknowledgement = dashboard.indexOf('method:"POST"', bodyRead);
  const localDownload = dashboard.indexOf("URL.createObjectURL(blob)", acknowledgement);
  assert.ok(bodyRead >= 0 && acknowledgement > bodyRead && localDownload > acknowledgement);
  assert.match(dashboard, /x-henvalt-delivery-ack-token/);
  assert.match(dashboard, /result\.acknowledged!==true/);
});

test("dashboard revokes the temporary object URL and never labels acknowledgement as file saved", () => {
  assert.match(dashboard, /URL\.revokeObjectURL\(url\)/);
  assert.match(dashboard, /does not prove the file was saved or opened/);
});

test("dashboard inline JavaScript parses before browser execution", () => {
  const scripts = [...dashboard.matchAll(/<script(?:\\s[^>]*)?>([\\s\\S]*?)<\\/script>/gi)];
  assert.ok(scripts.length > 0, "dashboard script block missing");
  for (const script of scripts) assert.doesNotThrow(() => new Function(script[1]));
});
