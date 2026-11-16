# Shopify webhook delivery-ID replay integrity

The verified webhook and privacy inbox RPCs use delivery identity for idempotency, but idempotency must not silently accept a different signed body under a previously seen delivery ID.

Both V2 RPCs now compute SHA-256 over the exact raw request bytes before insert. On a duplicate key:

- if the stored body digest matches, return an idempotent duplicate acknowledgement;
- if the same delivery identity is presented with a different body digest, reject it with `DELIVERY_ID_BODY_MISMATCH`.

The webhook inbox key is connection + Shopify delivery ID. The privacy inbox key is app + shop domain + Shopify webhook ID. This preserves independent delivery namespaces across stores while detecting body substitution/replay anomalies.

The SQL integration suite exercises both exact duplicate retry and same-ID/different-body rejection. No raw body or secret is stored in the inbox.
