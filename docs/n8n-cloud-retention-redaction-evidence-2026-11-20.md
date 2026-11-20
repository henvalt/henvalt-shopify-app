# n8n Cloud retention and redaction evidence — 2026-11-20

## Scope and method

Read-only inspection of the three active HENVALT production workflows through the connected n8n workflow API. No workflow was executed, edited, published, or unpublished. No execution payloads or customer data were retrieved.

Official documentation reviewed:
- Cloud execution storage and pruning: https://docs.n8n.io/deploy/use-n8n-cloud/configure-cloud/manage-your-data/
- Execution data redaction: https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/redact-execution-data/
- Security policy enforcement: https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/manage-security-policies/
- Workflow execution settings: https://docs.n8n.io/workflows/settings/

## Live workflow metadata observed

All three workflows were active at inspection time. The connector returned these workflow-level settings:

| Workflow | ID | Nodes | Active | Workflow settings returned |
|---|---|---:|---|---|
| HENVALT_DELIVERY | CvVyybGJZSnklxiZ | 62 | yes | executionOrder=v1; binaryMode=separate; timeSavedMode=fixed; callerPolicy=workflowsFromSameOwner; availableInMCP=true |
| HENVALT_INGEST | VTpfGKNtu1CSQ4Rv | 51 | yes | executionOrder=v1; binaryMode=separate; timeSavedMode=fixed; callerPolicy=workflowsFromSameOwner; availableInMCP=true |
| HENVALT_RECOVERY | 3GEDoeCA4paXTaDF | 46 | yes | executionOrder=v1; binaryMode=separate; timeSavedMode=fixed; callerPolicy=workflowsFromSameOwner; availableInMCP=true |

The returned workflow settings contain no execution-save, pruning, or redaction fields. This connector surface therefore does not establish the effective Cloud console instance settings or account plan. Absence of a field in this API response is not evidence that a feature is disabled or enabled.

## Official n8n Cloud retention rules

n8n documents these Cloud automatic-pruning limits:
- Start / Starter: up to 2,500 saved executions or 7 days.
- Pro: up to 25,000 saved executions or 30 days.
- Enterprise: up to 50,000 saved executions with unlimited time retention.

Pruning removes the oldest executions when either the applicable count or time limit is reached. The account's current plan and actual retained-execution settings were not available from the connected workflow API and remain unverified.

n8n documents execution-save controls in the Cloud console:
1. Open the n8n Cloud console.
2. Select Instance settings.
3. Open Runtime.
4. Inspect Executions to save: Manual, Failed, Successful.
5. Record the selected values. Saving changes restarts the instance; this evidence task does not authorize changing them.

Workflow-level settings also include save-failed production executions, save-successful production executions, and save-manual executions. The live workflow settings response inspected here did not return those fields, so they must be checked in the UI for each workflow if no instance-level view conclusively covers them.

## Official redaction rules

n8n documents execution-data redaction as an Enterprise feature on Cloud and self-hosted. Per-workflow redaction is available from n8n 2.16.0; instance-level enforcement is available from n8n 2.26.0.

To inspect instance enforcement, n8n documents Settings > Policies > Data redaction. The enforcement scope can cover production executions, or both manual and production executions.

To inspect per-workflow settings, open each workflow > Workflow menu > Settings and inspect:
- Redact production execution data
- Redact manual execution data

The live workflow API response inspected for all three workflows did not include redaction settings. Neither the account's Enterprise entitlement nor effective instance/per-workflow redaction state has been verified. Do not assume redaction is enabled.

Redaction is not a substitute for data minimization or storage retention: n8n documents that redaction hides execution payloads when viewed through the API/UI, but does not rewrite stored database data or prevent downstream nodes from receiving it.

## Required evidence to close PRIV-01 / PRIV-02

Capture redacted screenshots or owner-confirmed values for:
1. Cloud console > Instance settings > Runtime > Executions to save.
2. Cloud console plan/tier, without account identifiers.
3. Settings > Policies > Data redaction, including enforcement scope, if the feature is available.
4. Each of the three workflow settings pages, including save execution and redaction controls where present.
5. A synthetic execution view demonstrating the effective redaction behavior, without real customer data or secrets.

If the current plan does not include redaction, record that as a product/plan limitation. Do not silently treat execution-save suppression as equivalent to redaction. Minimize what is saved and avoid real PII in manual tests.

## Safety conclusion

- Live workflow metadata was inspected read-only.
- No active workflow was executed or modified.
- No production sender interlock was deployed.
- No production credentials or secrets were accessed or copied.
- Effective retention, plan entitlement, and redaction remain NOT VERIFIED pending owner-visible Cloud console evidence.
- Production remains HOLD; this document does not authorize production changes.
