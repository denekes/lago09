# Monitoring: what exists vs what the docs claim

Read when you set up metrics/alerts or someone asks "where are the metrics". Verified 2026-10-01.
Exposure and auth hardening: `security-and-supply-chain`.
`$API` = pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (591ae90).

## 1. What exists

| Endpoint / signal | Where | Condition | Evidence |
|---|---|---|---|
| `GET /health` (DB round-trip, returns version JSON), `GET /ready` (503 while shutting down) | api, port 3000 | always | `$API/config/routes.rb:16-17`; `app/controllers/application_controller.rb:11-39` |
| Prometheus, Rails + Puma (Yabeda) | `GET /metrics` on api :3000 | ALWAYS mounted, no auth; multi-process store in `/tmp/prometheus/`; tags `service` (`OTEL_SERVICE_NAME` or `lago-api`), `environment`, `version` (`LAGO_VERSION` or `unknown`) | `routes.rb:10`; `config/initializers/yabeda.rb`; `config/puma.rb:69-71`; Gemfile:88-91 |
| Prometheus, Sidekiq queues (sidekiq-prometheus-exporter) | `GET /sidekiq/prometheus/metrics` on api :3000 | only when `LAGO_SIDEKIQ_WEB == "true"` (default true in every compose file) | `routes.rb:4-7`; Gemfile:20 |
| Sidekiq Web UI | `GET /sidekiq` on api :3000 | same condition; NO authentication (only cookie/session middleware) | `routes.rb:5`; `config/initializers/sidekiq.rb:22-28` |
| Karafka Web UI | `/karafka` | mounted when `ENV["LAGO_KARAFKA_WEB"]` is non-nil; an empty string counts (Ruby truthiness), so dev (`LAGO_KARAFKA_WEB=`, .env.development.default:91) mounts the route while `Karafka::Web.enable!` (`.present?`, `$API/karafka.rb:70`) does not run: runtime effect UNVERIFIED | `routes.rb:8` |
| Sidekiq Pro per-job metrics (DogStatsD) | push to `LAGO_SIDEKIQ_STATSD_ENDPOINT` (`host:port`) | Sidekiq Pro installed + env set | `sidekiq.rb:30-56` |
| Sidekiq liveness | TCP 8080 inside each worker container (answers after a Redis PING) | always in workers | `sidekiq.rb:16,73-75`; compose healthchecks `curl -f http://localhost:8080` |
| Through Traefik (light/production) | `https://$LAGO_DOMAIN/api/metrics`, `/api/sidekiq`, `/api/sidekiq/prometheus/metrics` (router `PathPrefix(/api/)` + stripprefix) | reachable from the internet if the domain is public (inferred from labels; UNVERIFIED runtime) | deploy/docker-compose.production.yml:201-208 |
| events-processor | NOTHING scrapeable: no HTTP server, no health/readiness, no lag/DLQ/failure counters | only traces (OTel or Datadog) and, with OTel + `KAFKA_TRACING_ENABLED=true`, franz-go kotel client meters exported by the OTel meter provider (60 s reader) | `grep -rn 'ListenAndServe\|net/http' events-processor --include=*.go` → nothing; config/tracing/otel_tracer.go; config/kafka/kafka.go:40-46 |
| Kafka consumer lag | broker side: `rpk group describe lago_dev_events-raw` (dev) / your Kafka tooling | always | standard rpk (not run here) |
| Redpanda | admin API :9644 inside the container (`/v1/status/ready` used by the healthcheck); Console UI https://console.lago.dev | dev | docker-compose.dev.yml:384-389, 411-433 |
| Postgres | pghero https://pghero.lago.dev (+ `pg_stat_statements` preloaded) | dev | docker-compose.dev.yml:494-517; scripts/postgresql.conf:81-84 |
| Sentry | `SENTRY_DSN` for api and events-processor | not passed by any compose file | output-map.md §5 |

## 2. What the docs claim (and what is wrong)

| Doc | Claim | Reality |
|---|---|---|
| docs/monitoring.md:33,47-51 | Sidekiq metrics via a separate `lago-sidekiqs` service at `:3000/prometheus/metrics` | `getlago/lago-sidekiqs` is not publicly reachable (`git ls-remote` asks for credentials, 2026-10-01). lago-api's own path is `/sidekiq/prometheus/metrics` (routes.rb:6). The doc may describe Lago's managed setup: UNVERIFIED |
| docs/monitoring.md | (silent) | `/metrics` (Yabeda) is not mentioned; nothing on events-processor, Kafka lag, ClickHouse, Debezium or the DLQ |
| docs/monitoring.md:144-163 queue table | 18 queues; `wallets` = "Default Worker (deprecated)" | `wallets` has its own worker config (`$API/config/sidekiq/sidekiq_wallets.yml`) and the default `sidekiq.yml` no longer lists it; queues `payments`, `alerts`, `alerts_high_priority`, `analytics_low_priority`, `billing_low_priority`, `dedicated_alerts`, `dedicated_wallets` (from `sidekiq_{payments,alerts,analytics,billing,dedicated}.yml`) are missing from the table |
| docs/monitoring.md:75 | code anchor `#L36-L61` | the method is at sidekiq.rb:30-56 and its error string now ends with `, got: #{statsd_endpoint}` |
| README.md:190 | "Lago exposes Prometheus metrics for APIs, queues, workers, events, billing, webhooks, and dependencies" | APIs (Yabeda) and queues/workers (Sidekiq exporter) only; no events-processor, billing or dependency metrics in either repo |
| deploy/README.md:170-175 | links monitoring.md for production deployments | the deploy files expose those endpoints publicly via Traefik (see §1) |

## 3. Minimum viable monitoring for the event pipeline (CANDIDATE, not implemented anywhere)

- Lag: alert on `rpk group describe <group>_<topic>` lag growth (or your Kafka exporter) for the
  events-processor group and the ClickHouse `clickhouse` group.
- DLQ rate: `SELECT error_code, count() FROM events_dead_letter WHERE failed_at > now() - INTERVAL 1 HOUR GROUP BY error_code`.
- Liveness: process restarts (container restart count) — a fetch error panics the process.
- Memory cache (production runs it: DECIDED OD-1): snapshot completeness after every start (six
  `Completed snapshot load` lines), Debezium connector state, replication-slot lag of `lago_dbz_evt_proc`,
  lag of the pod's six `lago_evp_*` groups, and a `fetch_billable_metric` `Key not found` burst alert.
  Commands: `memory-cache-ops.md` §1-§2.
- Silent losses (unmarshal errors, skipped retryables) produce only Sentry events/log lines: count
  `Error unmarshalling message` log lines. Turning these into metrics is workstream W5 of
  `event-accounting-campaign` (target, not current state).
