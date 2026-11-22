-- Prove that a tenant-owned root row cannot carry foreign-tenant links.
INSERT INTO henvalt.tenants(id,status)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ACTIVE'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','ACTIVE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.customers(id,tenant_id,shopify_customer_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa11','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','graph-customer-a'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','graph-customer-b')
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.checkouts(id,tenant_id,customer_id,created_at,updated_at)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa21','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',now(),now()),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',now(),now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.webhook_events(id,tenant_id,source_event_id,topic,idempotency_key,payload)
VALUES
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','graph-webhook-b','orders/create','graph-webhook-b','{}'::jsonb)
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.canonical_events(
 id,tenant_id,webhook_event_id,event_type,event_class,source,source_event_id,
 occurred_at,payload,metadata,idempotency_key
) VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3','orders/create','OTHER','shopify','graph-event-a',now(),'{}'::jsonb,'{}'::jsonb,'graph-event-a'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb5','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',NULL,'orders/create','OTHER','shopify','graph-event-b',now(),'{}'::jsonb,'{}'::jsonb,'graph-event-b')
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.opportunities(id,tenant_id,opportunity_type,status,customer_id,checkout_id,source_event_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa41','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ABANDONED_CHECKOUT','ELIGIBLE','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',NULL,NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa42','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ABANDONED_CHECKOUT','ELIGIBLE',NULL,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4',NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa43','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ABANDONED_CHECKOUT','ELIGIBLE',NULL,NULL,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb5'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','ABANDONED_CHECKOUT','ELIGIBLE',NULL,NULL,NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.orders(id,tenant_id,customer_id,checkout_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa52','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',NULL,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb7','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',NULL,NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.recovery_sequences(id,tenant_id,opportunity_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa61','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6')
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,status,sequence_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa41','PENDING','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8'),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa72','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6','PENDING',NULL),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6','PENDING',NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.order_attributions(id,tenant_id,order_id,attribution_confidence,opportunity_id,recovery_id,matched_intervention_id)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa81','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb7','HIGH',NULL,NULL,NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa82','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51','HIGH','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6',NULL,NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa83','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51','HIGH',NULL,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8',NULL),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa84','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51','HIGH',NULL,NULL,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9')
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.expect_replay_graph_rejection(p_table text,p_id uuid)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  BEGIN
    PERFORM henvalt.assert_shopify_replay_object_graph_tenant(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',p_table,p_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN;
  END;
  RAISE EXCEPTION 'CROSS_TENANT_GRAPH_EDGE_ACCEPTED: % %',p_table,p_id;
END;
$function$;

DO $graph_acceptance$
BEGIN
  PERFORM pg_temp.expect_replay_graph_rejection('checkouts','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa21');
  PERFORM pg_temp.expect_replay_graph_rejection('canonical_events','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31');
  PERFORM pg_temp.expect_replay_graph_rejection('opportunities','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa41');
  PERFORM pg_temp.expect_replay_graph_rejection('opportunities','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa42');
  PERFORM pg_temp.expect_replay_graph_rejection('opportunities','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa43');
  PERFORM pg_temp.expect_replay_graph_rejection('orders','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51');
  PERFORM pg_temp.expect_replay_graph_rejection('orders','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa52');
  PERFORM pg_temp.expect_replay_graph_rejection('recovery_sequences','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa61');
  PERFORM pg_temp.expect_replay_graph_rejection('recovery_interventions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71');
  PERFORM pg_temp.expect_replay_graph_rejection('recovery_interventions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa72');
  PERFORM pg_temp.expect_replay_graph_rejection('order_attributions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa81');
  PERFORM pg_temp.expect_replay_graph_rejection('order_attributions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa82');
  PERFORM pg_temp.expect_replay_graph_rejection('order_attributions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa83');
  PERFORM pg_temp.expect_replay_graph_rejection('order_attributions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa84');

  -- Same-tenant control: the helper must allow a valid graph with no foreign edges.
  INSERT INTO henvalt.orders(id,tenant_id)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa91','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO henvalt.order_attributions(id,tenant_id,order_id,attribution_confidence)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa92','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa91','HIGH')
  ON CONFLICT (id) DO NOTHING;
  PERFORM henvalt.assert_shopify_replay_object_graph_tenant(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','order_attributions','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa92'
  );
  RAISE NOTICE 'SHOPIFY_REPLAY_OBJECT_TENANT_GRAPH_ACCEPTANCE_PASSED';
END;
$graph_acceptance$;
