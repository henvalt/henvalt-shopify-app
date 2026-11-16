# Store-scope trigger audit

**Status:** read-only inspection of deployed non-internal triggers and their trigger functions. No production changes.

Six user-defined triggers were found in the `henvalt` schema. No views were returned by the same schema inventory query.

## Findings

| Table | Trigger function | Scope concern |
|---|---|---|
| `conversation_messages` | `set_initial_customer_reply_intent()` | Only classifies inbound text; no store identity check itself |
| `delivery_attempts` | `measure_email_usage_after_attempt()` | Writes `email_usage_measurements` by tenant and delivery attempt; provider config lookup is tenant/channel/provider scoped |
| `delivery_requests` | `enforce_billing_entitlement_before_delivery()` | Reads tenant-keyed `billing_accounts`, tenant billing measurements and tenant email usage |
| `messages` | `messages_append_sender_identity_footer()` | Calls `render_sender_identity_footer(tenant_id, body)`; sender identity footer is tenant-scoped |
| `recovery_interventions` | `stamp_recovery_intervention_delivery_times()` | Only stamps lifecycle timestamps; no store check itself |

## Design implications

- The tenant-level MailerSend provider configuration can remain shared intentionally, but usage reporting should derive store identity through delivery request → intervention/opportunity → connection when store-level reporting is needed.
- The billing entitlement trigger is tenant-level today. Its future scope must match the decided billing principal (tenant or Shopify store). Do not make the trigger store-scoped until the billing account model and usage measurement lineage are agreed.
- Sender identity/footer is tenant-level. Recommended model is explicit store-specific sender profile/branding override with tenant-level fallback, with the delivery authorization path validating that the selected profile is allowed for the originating connection.
- Reply intent classification and delivery timestamp triggers do not add store lineage; the authoritative connection check must happen in the writer RPCs and delivery authorization, not be assumed from these triggers.

## Inventory status

This trigger audit is complete for user-defined triggers in `henvalt`. It does not prove there are no external callers, scheduled jobs, functions in other schemas, or application-side SQL statements that bypass these paths.
