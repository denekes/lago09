# TLS verification and trust boundaries

Read this when a change touches a TLS option, a Redis/Kafka/OTEL client, a connector pipeline, or
anything that decides which organization an event belongs to.
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. `$API` = lago-api at the pinned SHA `591ae90` (2026-09-08).
Checked 2026-10-01.

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
| events-processor memory-cache consumers (Debezium CDC) | `events-processor/cache/consumer.go:27-35` | never | n/a: no TLS, no SASL, `SeedBrokers` with the raw unsplit string | Production-relevant: production runs `LAGO_USE_MEMORY_CACHE=true` (DECIDED OD-1 (owner, 2026-10-02)). Same `LAGO_KAFKA_BOOTSTRAP_SERVERS` as the main clients, which add SCRAM/TLS when set (`config/kafka/kafka.go:48-68`): either the broker accepts plaintext, unauthenticated clients or the CDC consumers fail and the cache freezes at its snapshot (`architecture-contract` WP10). Production auth and broker list: OPEN DECISION OD-1b (owner). Hardening: `event-accounting-campaign` W6-2 (DEFAULT APPLIED OD-20) |
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
- lago-api `VERIFY_NONE` is lago-api code: a lago-api PR (change-control N6; DECIDED OD-4 (owner,
  2026-10-02): PRs go where the dependent code lives).
- CDC consumers: build them through `kafka.NewKafkaClient` (broker split, SCRAM, TLS, logger) instead of
  a bare `kgo.NewClient` (`cache/consumer.go:30-35`); C4, `event-accounting-campaign` W6-2. Until then,
  ask the owner first which listener production's CDC consumers use (OPEN DECISION OD-1b (owner)).
- Gotenberg: drop the flag unless invoices embed self-signed assets (CANDIDATE; not in the OD
  register: raise a new owner decision as a GitHub issue titled "OD-n: Gotenberg ignores TLS errors",
  per change-control Terms "owner").

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
plus C7. OPEN DECISION OD-17 (owner): is the HTTP connector ever deployed reachable from outside a
private network, and may it trust a client-sent `organization_id`?

Also in `http.yml:32-36`: any non-number `precise_total_amount_cents` becomes `"0"`, and a JSON
number passes through, which the events-processor then fails to unmarshal (`models/event.go:18`
declares a string; the record is committed, Sentry only). There is no value-preserving workaround
through the connectors. That is an accounting defect, not a security one: see the
`event-accounting-campaign` skill (W2).

## 3. Cross-tenant history

- `9ef876a` (#738, 2026-05-18, ING-123): "Add organization_id in fetch flat filters query". Whether
  the missing scope ever returned another tenant's filters in production is OPEN DECISION OD-9
  (owner); label UNVERIFIED. The flat-filters code path was later removed (`d9c32b6`; see the
  `failure-archaeology` skill).
- Rule for reviewers: any new SQL in `events-processor/models/` must carry `organization_id`
  (change-control N4) and the sqlmock test must pin it.

## 4. Tenant trust inside lago-api and the expression engine (re-implementation kit, 2026-10-02)

The re-implementation kit executed lago-api at the pin through its oracle (`reimplementation-kit`;
how to run it: `diagnostics-and-tooling` H13). Four findings touch tenant trust. Each row says what was
executed and what is only inferred.

### 4.1 One RSA key signs every organization's JWT webhooks (`reimplementation-kit` RBD-93)

- Code (read 2026-10-02): the key is loaded once per installation from `config/keys/private.pem` or
  `LAGO_RSA_PRIVATE_KEY`, and boot aborts if it is blank (`$API/config/initializers/rsa_keys.rb:6-18`).
  `jwt_signature` encodes `{data: payload.to_json, iss: issuer}` with that key, RS256
  (`$API/app/models/webhook.rb:72-81`), and `issuer` is `ENV["LAGO_API_URL"]` (`:88-90`). The HMAC
  alternative uses the per-organization `organization.hmac_key` (`:83-86`). JWT is the default:
  `SIGNATURE_ALGOS = [:jwt, :hmac]` (`$API/app/models/webhook_endpoint.rb:6-9`) and
  `signature_algo integer DEFAULT 0` (`$API/db/structure.sql:6096`). The public key is served to anyone
  by `GET /api/v1/webhooks/public_key` (`$API/app/controllers/api/v1/webhooks_controller.rb:8`).
- Executed: the kit vectors `webhooks.sign.003`, `webhooks.sign.004` and `webhooks.public_key.001`
  (`grep -c '"id": *"webhooks.sign.00[34]"' .claude/skills/billing-engine-spec/vectors/webhooks.jsonl` -> `2`)
  (EXECUTED by the oracle with a kit test key swapped in for the installation key) pin the token
  shape: header `{"alg":"RS256"}`, claims `data` + `iss`, no expiry, no nonce, no organization claim.
- Consequence (INFERRED, not exercised): on a multi-tenant installation every tenant receives
  validly signed tokens, and the token says nothing about the intended receiver. A receiver that
  verifies only the signature accepts a token replayed from another tenant's delivery. Rotating the
  key rotates it for all tenants at once (procedure UNVERIFIED).
- Receiver guidance (CANDIDATE, for self-hosters and integrators): after verifying the signature,
  check `organization_id` in the payload (the envelope always carries it:
  `$API/app/services/webhooks/base_service.rb:16-21`) and de-duplicate on the `X-Lago-Unique-Key`
  header (`$API/app/models/webhook.rb:68`); or switch the endpoint to HMAC, whose key is per organization.
- Not an open owner decision today: the kit keeps this behaviour (RBD-93 = KEEP; `billing-engine-spec` reference/12-webhooks.md BE-WH-16). Raise one (change-control
  "owner") if Cloud wants per-organization keys.

### 4.2 The Authorization scheme word is not checked (`reimplementation-kit` RBD-88)

- Code: `request.headers["Authorization"]&.split(" ")&.second` (`$API/app/controllers/api/base_controller.rb:36-38`).
- Executed: kit vector `api.auth_token.002` (compat, EXECUTED; `grep -c '"id": *"api.auth_token.002"' .claude/skills/billing-engine-spec/vectors/api.jsonl` -> `1`): `Bearer k`, `Token k` and `Basic k`
  all present the key `k`; extra tokens are ignored; a bare key (one token) presents no key (401).
- Impact (INFERRED): low on its own, a valid key is still required. A gateway, WAF rule or log
  scrubber that recognises API keys only after `Bearer ` misses keys sent as `Basic <key>` or
  `Token <key>`. The corrected profile proposes "Bearer only" (`api.auth_token.002x`, ruling proposed:
  OPEN DECISION OD-21 (owner)).

### 4.3 A division by zero in a metric expression aborts the events-processor (`reimplementation-kit` RBD-37)

- Tenants author billable-metric expressions; any event they send is evaluated in the
  events-processor at `events-processor/processors/events_processor/enrichment_service.go:132`
  (`expression.Evaluate`, expression-go v0.1.4 on lago-expression v0.2.0).
- Executed here (2026-10-02, a scratch module, nothing written to the repo):
  `expression.Evaluate("event.properties.a / event.properties.b", <event with "b":"0">)` prints
  `panicked at .../bigdecimal-0.4.6/src/impl_ops_div.rs:10:13: Division by zero`, then
  `fatal runtime error: failed to initiate panic, error 5, aborting` and `SIGABRT: abort`. A Rust panic
  cannot unwind through the C boundary, so `recover` in Go cannot catch it: the whole process dies.
- Consequence (INFERRED from the commit rule, not run end to end): the record is never committed, so
  every restart re-reads it and aborts again. Everything behind it on that partition stalls, including
  other tenants' events: lago-api produces raw events without a key
  (`$API/app/services/events/kafka_producer_service.rb:29-34`), so every partition mixes tenants. The kit's oracle run of lago-api shows the API side answers HTTP 500 and stores nothing
  while the server keeps serving (`reimplementation-kit` RBD-37, corrected twins
  `expression.div_zero.001x`/`.002x` and `events.validate.025x`, ruling proposed).
- Severity (this skill's CANDIDATE ranking): HIGH, cross-tenant availability. Fix options (all
  CANDIDATE, owner-gated through OPEN DECISION OD-21 (owner)): a guard in lago-expression that returns
  an evaluation error (then a pin bump in 4 places: change-control N3, C5 + C7), or validation that
  refuses such expressions at metric creation (lago-api). Until then, triage a crash loop with
  `debugging-playbook`.

### 4.4 Webhooks are requested after the commit (`reimplementation-kit` RBD-85, resolved: no defect)

- An early kit draft said a few emissions (customer upsert, credit-note creation) were requested inside the
  transaction. At the pin this is not so, and the kit now says the same (`billing-engine-spec`
  reference/12-webhooks.md BE-WH-8; `reimplementation-kit` RBD-85 decided KEEP).
- Code: credit-note webhooks are sent from `after_commit`
  (`$API/app/services/credit_notes/create_service.rb:96-98`,
  `$API/app/services/invoices/refresh_draft_and_finalize_service.rb:44,58`); the customer upsert
  enqueues `SendWebhookJob.perform_later` at `:157`/`:160`, after its own transaction block
  (`$API/app/services/customers/upsert_from_api_service.rb:47-143`); its only caller is the API
  controller (`$API/app/controllers/api/v1/customers_controller.rb:7`). Rails does not defer jobs to
  commit here (ActiveJob 8.0.5.1 default), so the ordering comes from where the code requests them.
- EXECUTED 2026-10-02 through the kit oracle: a recorder over the upsert, credit-note and
  refresh-and-finalize specs (181 examples, 0 failures) saw no webhook requested inside an application
  transaction, and a forced rollback inside the upsert requested none. Request sites in outer callers'
  transactions were not audited one by one.
- Either way (CANDIDATE guidance), receivers should treat a webhook as a notification and re-fetch the
  object over the API before acting on it.
