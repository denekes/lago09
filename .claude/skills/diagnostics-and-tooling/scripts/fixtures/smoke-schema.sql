-- smoke-schema.sql — minimal Lago-shaped schema + one fixture tenant for probes.
--
-- NOT the real lago-api schema: only the tables and columns events-processor
-- reads (models/*.go: FetchBillableMetric, FetchSubscription,
-- HasPayInAdvanceCharge, and the GetAll* snapshot SELECTs used in memory-cache
-- mode). For the real schema use the pinned lago-api db/structure.sql (see
-- reference/harness-catalogue.md, "Real lago-api schema").
--
-- The ids and rows MUST stay identical to
-- kfake-harness/fixture/fixture.go (SeedCache). Change both together.
--
-- Load: scripts/scratch-pg.sh create <name> scripts/fixtures/smoke-schema.sql

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
  plan_id uuid NOT NULL, billable_metric_id uuid NOT NULL,
  pay_in_advance boolean NOT NULL DEFAULT false, accepts_target_wallet boolean NOT NULL DEFAULT false,
  properties jsonb NOT NULL DEFAULT '{}',
  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
  deleted_at timestamp(6));
-- The three filter tables are still snapshotted in memory-cache mode
-- (cache/cache.go LoadInitialSnapshot) although nothing reads them since d9c32b6.
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

-- Fixture tenant: org 11111111-..., plan 22222222-...
INSERT INTO billable_metrics (id, organization_id, code, aggregation_type, field_name, expression) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'api_calls',   1, 'amount', NULL),
 ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'count_calls', 0, NULL,     NULL),
 ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'expr_metric', 1, 'total',  'event.properties.a * 2');
-- started_at carries 500 microseconds on purpose (ms vs us comparisons become observable).
INSERT INTO subscriptions (id, organization_id, external_id, plan_id, started_at) VALUES
 ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'sub_ext_1',
  '22222222-2222-2222-2222-222222222222', '2025-01-01 00:00:00.000500');
INSERT INTO charges (id, organization_id, plan_id, billable_metric_id, pay_in_advance) VALUES
 ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000001', true),
 ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000002', false);
