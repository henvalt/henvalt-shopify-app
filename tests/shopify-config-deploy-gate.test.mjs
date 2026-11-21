import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const workflow=readFileSync(new URL("../.github/workflows/shopify-config-validation.yml",import.meta.url),"utf8");

test("Shopify app preparation cannot run on push, pull request, or an unconfirmed dispatch",()=>{
  assert.match(workflow,/deploy-shopify-version:[\s\S]*?if:\s*github\.event_name\s*==\s*'workflow_dispatch'\s*&&\s*inputs\.confirm_shopify_prepare\s*==\s*true\s*&&\s*github\.ref\s*==\s*'refs\/heads\/main'/);
  assert.match(workflow,/Require reviewed main-branch preparation confirmation[\s\S]*?GITHUB_REF.*refs\/heads\/main/);
  assert.match(workflow,/Explicit Shopify preparation confirmation is required/);
});

test("Shopify CLI deployment is token-gated and creates only an unreleased version",()=>{
  assert.match(workflow,/SHOPIFY_SERVICE_ACCOUNT_TOKEN:\s*\$\{\{\s*secrets\.SHOPIFY_SERVICE_ACCOUNT_TOKEN\s*\}\}/);
  assert.match(workflow,/if:\s*env\.SHOPIFY_SERVICE_ACCOUNT_TOKEN\s*!=\s*''[\s\S]*?shopify app deploy --no-release --config=shopify\.app\.toml/);
  assert.doesNotMatch(workflow,/shopify app deploy --config=shopify\.app\.toml\s*$/m);
});
