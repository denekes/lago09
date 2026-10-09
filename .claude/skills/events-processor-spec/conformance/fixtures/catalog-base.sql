-- catalog-base.sql: events-processor conformance fixture (events-processor-spec kit skill).
-- The catalog tables an events-processor reads, with only the columns it reads plus the
-- NOT NULL ones, and one deterministic two-organization tenant. Column names and types are
-- those of the billing engine's catalog tables (reference/contract.md §4 "Postgres read set").
-- aggregation_type integers: 0 count, 1 sum, 2 max, 3 unique_count, 4 retired, 5 weighted_sum,
-- 6 latest, 7 custom. subscriptions.status integers: 0 pending, 1 active, 2 terminated,
-- 3 canceled, 4 incomplete (not read by the processor).
-- Timestamps are UTC wall-clock values in "timestamp without time zone" columns.
CREATE TABLE billable_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  name varchar NOT NULL DEFAULT 'n', code varchar NOT NULL, aggregation_type int NOT NULL,
  recurring boolean NOT NULL DEFAULT false, field_name varchar, expression varchar,
  properties jsonb DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));
CREATE TABLE subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  external_id varchar NOT NULL, plan_id uuid NOT NULL, status int NOT NULL DEFAULT 1,
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  started_at timestamp, terminated_at timestamp);
CREATE TABLE charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  plan_id uuid, billable_metric_id uuid,
  pay_in_advance boolean NOT NULL DEFAULT false, accepts_target_wallet boolean NOT NULL DEFAULT false,
  properties jsonb NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));
CREATE TABLE billable_metric_filters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  billable_metric_id uuid NOT NULL, key varchar NOT NULL, values varchar[] NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));
CREATE TABLE charge_filters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  charge_id uuid NOT NULL, properties jsonb NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));
CREATE TABLE charge_filter_values (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
  charge_filter_id uuid NOT NULL, billable_metric_filter_id uuid NOT NULL,
  values varchar[] NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));

-- Org O1 = 11111111-1111-1111-1111-111111111111 ; Org O2 = 99999999-9999-9999-9999-999999999999
-- Plans: P1 = 22222222-2222-2222-2222-222222222222, P0 = 22222222-2222-2222-2222-000000000000 (O1),
--        P2 = 22222222-2222-2222-2222-999999999999 (O2)
INSERT INTO billable_metrics (id, organization_id, code, aggregation_type, field_name, expression, recurring, deleted_at) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'api_calls',      1, 'amount',      NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'count_calls',    0, NULL,          NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'expr_metric',    1, 'total',       'event.properties.a * 2', false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'max_amount',     2, 'amount',      NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'unique_users',   3, 'user_id',     NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'storage_gb',     5, 'gb',          NULL, true,  NULL),
 ('aaaaaaaa-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'latest_level',   6, 'level',       NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'custom_metric',  7, NULL,          NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'legacy_type4',   4, 'amount',      NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'deleted_metric', 1, 'amount',      NULL, false, '2025-01-02 00:00:00'),
 ('aaaaaaaa-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'seats',          1, 'seats',       NULL, true,  NULL),
 ('aaaaaaaa-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111', 'filtered_calls', 1, 'amount',      NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000013', '11111111-1111-1111-1111-111111111111', 'expr_round',     1, 'total_value', 'round(event.properties.value * event.properties.units)', false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000014', '11111111-1111-1111-1111-111111111111', 'expr_ts',        1, 'ts_value',    'event.timestamp', false, NULL),
 ('aaaaaaaa-0000-0000-0000-000000000015', '11111111-1111-1111-1111-111111111111', 'count_field',    0, 'amount',      NULL, false, NULL),
 ('aaaaaaaa-0000-0000-0000-0000000000f1', '99999999-9999-9999-9999-999999999999', 'api_calls',      0, NULL,          NULL, false, NULL);

-- started_at of sub 01 carries +500 microseconds on purpose (ms-vs-us boundary).
INSERT INTO subscriptions (id, organization_id, external_id, plan_id, status, started_at, terminated_at) VALUES
 ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'sub_ext_1',          '22222222-2222-2222-2222-222222222222', 1, '2025-01-01 00:00:00.000500', NULL),
 ('bbbbbbbb-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'sub_ext_term',       '22222222-2222-2222-2222-222222222222', 2, '2025-01-01 00:00:00',        '2025-06-01 00:00:00.000700'),
 ('bbbbbbbb-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'sub_ext_multi',      '22222222-2222-2222-2222-000000000000', 2, '2025-01-01 00:00:00',        '2025-03-01 00:00:00'),
 ('bbbbbbbb-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'sub_ext_multi',      '22222222-2222-2222-2222-222222222222', 1, '2025-03-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'sub_ext_future',     '22222222-2222-2222-2222-222222222222', 0, '2030-01-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'sub_ext_late',       '22222222-2222-2222-2222-222222222222', 1, '2025-09-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'sub_ext_incomplete', '22222222-2222-2222-2222-222222222222', 4, '2025-01-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'acme',               '22222222-2222-2222-2222-222222222222', 1, '2025-01-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'acme:eu',            '22222222-2222-2222-2222-000000000000', 1, '2025-01-01 00:00:00',        NULL),
 ('bbbbbbbb-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'sub_ext_ms',         '22222222-2222-2222-2222-222222222222', 1, '2025-03-03 13:03:29.123',    NULL),
 ('bbbbbbbb-0000-0000-0000-0000000000f1', '99999999-9999-9999-9999-999999999999', 'sub_ext_1',          '22222222-2222-2222-2222-999999999999', 1, '2025-01-01 00:00:00',        NULL);

INSERT INTO charges (id, organization_id, plan_id, billable_metric_id, pay_in_advance, deleted_at) VALUES
 ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000001', true,  NULL),
 ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000002', false, NULL),
 ('cccccccc-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000005', true,  NULL),
 ('cccccccc-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000004', true,  '2025-01-02 00:00:00'),
 ('cccccccc-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000012', false, NULL),
 ('cccccccc-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000003', false, NULL),
 ('cccccccc-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000011', true,  NULL),
 ('cccccccc-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-000000000000', 'aaaaaaaa-0000-0000-0000-000000000001', false, NULL),
 ('cccccccc-0000-0000-0000-0000000000f1', '99999999-9999-9999-9999-999999999999', '22222222-2222-2222-2222-999999999999', 'aaaaaaaa-0000-0000-0000-0000000000f1', true,  NULL);

-- Filters on filtered_calls (the reference events-processor reads none of these tables in DB mode;
-- in memory-cache mode it loads them into the cache but no rule reads them).
INSERT INTO billable_metric_filters (id, organization_id, billable_metric_id, key, values) VALUES
 ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000012', 'region', '{eu,us}');
INSERT INTO charge_filters (id, organization_id, charge_id) VALUES
 ('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000005');
INSERT INTO charge_filter_values (id, organization_id, charge_filter_id, billable_metric_filter_id, values) VALUES
 ('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'eeeeeeee-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', '{eu}');
