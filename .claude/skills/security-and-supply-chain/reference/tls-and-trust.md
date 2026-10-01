# TLS verification and trust boundaries

Read this when a change touches a TLS option, a Redis/Kafka/OTEL client, a connector pipeline, or
anything that decides which organization an event belongs to. Facts checked 2026-10-01 at HEAD
(code `5308258`) and `$API` = lago-api `591ae90`.

## 1. Certificate verification matrix

| Client | Where | TLS on when | Verifies the server cert? | Note |
|---|---|---|---|---|
| events-processor -> Redis flag store (`subscription_refreshed_v2`) | `events-processor/config/redis/redis.go:42-48` | `LAGO_REDIS_STORE_TLS=true`, or legacy default `ENV=production` (`processors/main_processor.go:84-91`) | **No**: `InsecureSkipVerify: true` (`redis.go:44`), always | go-redis v9.17.1 dials lazily and reads `opt.TLSConfig` at dial time, so the post-construction assignment takes effect. The `rediss://` scheme is stripped (`redis.go:25-28`), so the scheme alone never enables TLS |
| lago-api -> same Redis store (reader) | `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:63-69` | `LAGO_REDIS_STORE_SSL` set or `rediss:` URL | Yes, unless `LAGO_REDIS_STORE_DISABLE_SSL_VERIFY` is set | Same Redis, two policies: Rails verifies by default, Go never does |
| lago-api Sidekiq Redis | `$API/lib/lago/redis_config_builder.rb:53-57` | `rediss://` in `REDIS_URL` | **No**: `VERIFY_NONE` always | applies whenever TLS is used |
| lago-api cache Redis | `$API/lib/lago/redis_config_builder.rb:73-77` | `rediss://` in `LAGO_REDIS_CACHE_URL` | **No**: `VERIFY_NONE` always | |
| lago-api outbound HTTP session client | `$API/lib/lago_http_client/lago_http_client/session_client.rb:52-55` | https URLs | Yes in production; `VERIFY_NONE` only in development/test | positive control |
| lago-api S3 | `$API/config/storage.yml:9-24` (`amazon`, and `amazon_compatible_endpoint` when `LAGO_AWS_S3_ENDPOINT` is set) | https endpoints | Yes by default: AWS SDK default for `amazon`; `ssl_verify_peer` from `LAGO_AWS_S3_SSL_VERIFY` (default true, `:24`) for the custom endpoint | `LAGO_AWS_S3_SSL_VERIFY` is not passed by any compose anchor |
| events-processor -> Kafka (main consumer + producers) | `events-processor/config/kafka/kafka.go:66-69` | `LAGO_KAFKA_TLS=true` | Yes: `kgo.DialTLS()` with the default `tls.Config` | positive control |
| events-processor memory-cache consumers (Debezium CDC) | `events-processor/cache/consumer.go:27-35` | never | n/a: no TLS, no SASL, `SeedBrokers` with the raw unsplit string | only with `LAGO_USE_MEMORY_CACHE=true`; production use is OPEN DECISION OD-1 (owner). Forces a plaintext, unauthenticated broker path for CDC rows |
| events-processor OTEL exporter | `events-processor/config/tracing/otel_tracer.go:219-223,238-242`; `tracer.go:128-129` | unless `OTEL_INSECURE=true` | Yes (system roots) by default | positive control |
| Gotenberg (PDF) Chromium | `deploy/docker-compose.local.yml:243`, `light.yml:304`, `production.yml:452` | always | **No**: `--chromium-ignore-certificate-errors=true` | affects assets fetched while rendering invoices |
| Traefik -> Let's Encrypt | `deploy/docker-compose.light.yml:87`, `production.yml:87` | always | n/a: issues certificates from the **staging** CA, which browsers reject | see selfhost-defaults.md section 5 |
| Redpanda Connect HTTP pipeline -> Kafka | `connectors/http.yml:44-45`; `kinesis.yml:50-51` | `KAFKA_TLS` (default `false`) | default config (verifying) when enabled | SASL hard-coded SCRAM-SHA-512 (`http.yml:46-49`) |
| Redpanda Connect SQS pipeline -> Kafka | `connectors/sqs.yml:46-47` | always (`enabled: true`) | default config | |

Hardening (CANDIDATE, C7 + C3/C4 per change-control):
- Go Redis: replace `InsecureSkipVerify: true` with a verifying `tls.Config{ServerName: host}`,
  plus an opt-out variable mirroring lago-api (`LAGO_REDIS_STORE_DISABLE_SSL_VERIFY`) for
  self-signed managed Redis. Adding a variable is a config-and-flags checklist item. Test with
  miniredis over TLS (see the `diagnostics-and-tooling` skill). Not done here.
- lago-api `VERIFY_NONE` is lago-api code: a paired lago-api PR (change-control N6 / OD-4).
- Gotenberg: drop the flag unless invoices embed self-signed assets (owner question).

## 2. Trust boundary: who decides `organization_id`

Every events-processor DB lookup is scoped by `organization_id` (change-control N4; example
`events-processor/models/billable_metrics.go:61-63`, `models/charges.go:53-54`,
`models/subscriptions.go:30`). The scoping is only as good as the `organization_id` on the record.

| Ingest path | Source of `organization_id` | Authentication |
|---|---|---|
| lago-api `POST /api/v1/events` -> raw topic | `current_organization` of the API key (`$API/app/controllers/api/v1/events_controller.rb:14`) -> `organization_id: organization.id` (`$API/app/services/events/kafka_producer_service.rb:38`) | API key |
| `connectors/sqs.yml` | deploy-time env `ORGANIZATION_ID` (`sqs.yml:27`, key `:45`) | AWS IAM on the queue |
| `connectors/kinesis.yml` | deploy-time env `ORGANIZATION_ID` (`kinesis.yml:31`) | AWS IAM on the stream |
| `connectors/http.yml` | **the request body**: `root.organization_id = this.event.organization_id` (`http.yml:25`) | **none**: `http_server` on `0.0.0.0:3000`, path `/events`, POST only (`http.yml:1-7`) |

Tenant risk of the HTTP connector (inferred from `connectors/http.yml:1-7,25,43`, not exercised):
1. Any client that reaches port 3000 writes straight to the raw topic, bypassing lago-api's API key.
2. It chooses the tenant: an event with another org's `organization_id` and a matching
   `external_subscription_id` is enriched against that org's subscription and billed to it.
   The attacker needs the victim's org UUID and external subscription id; both are identifiers, not
   secrets.
3. Kafka key is `organization_id-external_subscription_id` (`http.yml:43`), so injected events land
   in the victim's partition ordering.
4. The connectors README documents `ORGANIZATION_ID` as required (`connectors/README.md:44`), but the
   HTTP pipeline ignores it.

Recommended fix (CANDIDATE): either `root.organization_id = "${ORGANIZATION_ID}"` like SQS/Kinesis
(one deployment per tenant), or put the endpoint behind an authenticating gateway that maps
credentials to an org. Changing the mapping is a C4 cross-repo payload change (change-control N6)
plus C7. OPEN question for the owner: is the HTTP connector ever deployed reachable from outside a
private network?

Also in `http.yml:32-36`: a numeric `precise_total_amount_cents` passes through as a JSON number and
the events-processor then fails to unmarshal it (`models/event.go:18` declares a string). That is an
accounting defect, not a security one: see the `event-accounting-campaign` skill.

## 3. Cross-tenant history

- `9ef876a` (#738, 2026-05-18, ING-123): "Add organization_id in fetch flat filters query". Whether
  the missing scope ever returned another tenant's filters in production is OPEN DECISION OD-9
  (owner); label UNVERIFIED. The flat-filters code path was later removed (`d9c32b6`; see the
  `failure-archaeology` skill).
- Rule for reviewers: any new SQL in `events-processor/models/` must carry `organization_id`
  (change-control N4) and the sqlmock test must pin it.
