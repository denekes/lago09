# Doc maintenance map: code path -> docs to re-check

Read this when a change touches code or config and you must decide which docs of record (and which
stale-claim entries) to re-check in the same PR. The table below is the single source of
`scripts/docs-to-recheck.sh`, which applies it to a diff. Keep the format: one row per path group;
first column = backticked shell globs separated by ", " (a `*` matches across `/`).

Verified 2026-10-01: every doc location below was opened and matched to the code it describes; SC
numbers refer to `stale-claims.md`.

## Map

| Changed path (globs) | Re-check these docs | Look for | Entries |
|---|---|---|---|
| `events-processor/main.go`, `events-processor/processors/main_processor.go`, `events-processor/config/tracing/*`, `events-processor/utils/env.go`, `events-processor/cache/consumer.go`, `events-processor/config/redis/*`, `events-processor/config/kafka/kafka.go`, `events-processor/config/kafka/consumer.go`, `events-processor/config/kafka/producer.go` | `events-processor/README.md` (Configuration, `:32-68`); `config-and-flags` skill; `docs/monitoring.md`, `README.md:190` if a metrics endpoint appears | env var names, defaults, which ones panic when missing, Kafka client options (SASL/SCRAM, TLS, batching) | SC-04 SC-05 SC-07 SC-08 SC-09 SC-10 SC-29 SC-41 |
| `events-processor/Dockerfile*`, `events-processor/go.mod`, `events-processor/mise.toml`, `.github/workflows/events-processor-tests.yml` | `events-processor/CLAUDE.md`; `events-processor/README.md:8-30`; the comment at `events-processor/Dockerfile.staging:20-22`; `build-and-env` skill | lago-expression ref (4 places), Go version, build and test commands | SC-01 SC-03 SC-11 |
| `events-processor/models/event.go`, `events-processor/processors/events_processor/*` | `connectors/README.md` (event format `:7-22`); `docs/architecture.md:224-232`; `rails-go-parity` and `architecture-contract` skills | field names and JSON types, what the processor does, disposition | SC-20 SC-33 |
| `events-processor/models/stores.go` | `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7-14` (comment, lago-api PR); `docs/architecture.md:333` | ZSET name, score, member, bucket | SC-19 SC-37 |
| `connectors/*` | `connectors/README.md:7-22` (event format) and `:25-84` (env tables) | env tables per connector, event format, SASL mechanism, logger settings | SC-33 SC-40 |
| `docker-compose.dev.yml`, `traefik/*` | `docs/dev_environment.md:73-106` (Traefik, hosts), `:116-137` (Running the app), `:192-207` (Redis Sentinel), `:288-302` (Emails) | `Host()` rules vs hosts list, external volumes, service and profile names, mail service name and aliases | SC-14 SC-15 SC-17 SC-39 |
| `.env.development.default` | `docs/dev_environment.md:150-158`; `events-processor/README.md` topic examples; `docs/architecture.md` env tables | names, defaults, interpolation, dangling service URLs | SC-06 SC-12 SC-13 SC-34 |
| `docker-compose.yml` | `README.md:217-229` (quickstart); `docs/database_partitioning.md:249-251`; `docs/architecture.md` | images and tags, required env (`LAGO_RSA_PRIVATE_KEY`), Postgres config | SC-28 |
| `deploy/*` | `deploy/README.md:1-117` (start commands, profiles at `:86-117`) | profile names and flag order, file names, image tags | SC-30 SC-31 |
| `docker/*` | `docker/README.md:19-42` (run commands, external services) | env defaults, ports, generated secrets | SC-32 |
| `scripts/postgresql.conf` | `docs/database_partitioning.md:143-251` (maintenance) | `shared_preload_libraries`, `pg_partman_bgw.*` | SC-28 |
| `extra/debezium_config.json` | `events-processor/README.md:68`; `architecture-contract` skill (memory-cache mode) | topic prefix, slot, publication | SC-07 |
| `api`, `front`, `.gitmodules` | every SC entry anchored in `$API` (re-run `doc-drift-check.sh`: a new pin can flip lines to RECHECK); `docs/architecture.md`, `docs/monitoring.md`, `docs/database_partitioning.md`, `docs/dev_environment.md` (Emails), `README.md:190` | lago-api facts quoted in umbrella docs | SC-12 SC-18 SC-19 SC-21 SC-22 SC-23 SC-24 SC-27 SC-29 SC-37 SC-39 SC-41 SC-42 |
| `.github/workflows/*` | `CONTRIBUTING.md:160` (status checks); `release-and-images` skill; `validation-and-qa` skill (CI shape) | which checks run on PRs, what builds on release | none |
| `examples/agentic-ai-demo/*` | `README.md:70-109` | ports (8080, 3001), credentials, version fallback | none |
| `PULL_REQUEST_TEMPLATE.md`, `CONTRIBUTING.md` | `change-control` (commit and PR conventions); `reference/templates.md` §1-2 | OD-7 defaults | SC-35 SC-36 |
| `docs/*`, `*.md` | `.claude/skills/docs-and-writing/reference/stale-claims.md` (close or update entries) and `inventory.md` (freshness, trust) | did the edit fix a register entry or introduce a new claim without evidence? | all |
| `.claude/skills/*` | the edited skill's Provenance section; every SKILL.md that names a renamed script | stale cross-references (`grep -rn '<old name>' .claude/skills`) | none |

## Procedure (run in the PR that changes code)

1. List the docs to re-check: `.claude/skills/docs-and-writing/scripts/docs-to-recheck.sh --range origin/main..HEAD`
   (or `--staged`, or plain to compare the working tree with HEAD).
2. Run `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh`. Compare the summary with the
   one recorded in SKILL.md. Investigate any `RECHECK` line: the code anchor of that entry moved,
   so the entry or the doc needs work.
3. Open each listed doc at the cited lines. For every sentence your change makes false, fix it in
   the same PR (C0 rides along with the code change) or add a register entry (`SC-NN`, next free
   number) with its check in `doc-drift-check.sh`.
4. Mention it in the PR body under "Evidence": the `docs-to-recheck.sh` output and what you did
   with each line ("updated", "still true", "SC-NN added").
