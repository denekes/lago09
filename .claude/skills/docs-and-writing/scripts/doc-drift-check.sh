#!/usr/bin/env bash
# doc-drift-check.sh — re-assert every entry of the stale-claim register
# (.claude/skills/docs-and-writing/reference/stale-claims.md) against the CURRENT repo, the
# pinned lago-api checkout and the full-history clone. One line per register entry:
#
#   STALE    the doc still carries the wrong claim AND the code anchor still contradicts it
#   PASS     the wrong claim is gone from the doc (someone fixed it): re-read the new text,
#            then mark the entry FIXED in reference/stale-claims.md
#   RECHECK  the doc still carries the claim but the code anchor moved: re-verify the entry
#            (the doc may have become right, or the evidence lines moved)
#   OPEN     the docs still disagree on an OPEN DECISION (OD-n): the owner's call, not a typo
#   KNOWN    immutable record (a commit message): cannot be edited; never quote it as fact
#   SKIP     the source that holds the claim is unavailable (pinned lago-api or history clone)
# "[anchor not re-checked: X]" after STALE means only the doc side was checked (X missing).
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/docs-and-writing/scripts/doc-drift-check.sh             # all entries
#   .../doc-drift-check.sh --only SC-01,SC-12   # selected entries
#   .../doc-drift-check.sh -q                   # summary line only
#   .../doc-drift-check.sh --list               # list entries, check nothing
#   .../doc-drift-check.sh --offline            # never fetch; use pinned lago-api / history
#                                               #   clone only if already in $LAGO_SKILLS_CACHE
#   .../doc-drift-check.sh --no-docker          # skip the two `docker compose` probes
# Output: "<STATUS> <ID> <doc:line> <claim>[ note]" per entry, then
#         "SUMMARY doc-drift-check: entries=N STALE=a PASS=b RECHECK=c OPEN=d KNOWN=e SKIP=f".
# Exit: number of STALE + RECHECK lines (capped at 255); 0 = nothing left to fix.
#       2 = usage error or not inside the lago repo (message on stderr, no SUMMARY line;
#       a run with exactly 2 STALE+RECHECK also exits 2 but prints SUMMARY).
# Read-only on the repo. Calls the research-methodology foundation scripts
# (pinned-checkout.sh api, history-setup.sh) unless --offline; they write only under
# ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}. `docker compose config` and
# `docker compose up --help` need only the docker CLI, not a daemon.
set -euo pipefail
export LC_ALL=C GIT_TERMINAL_PROMPT=0

only="" quiet=0 list=0 offline=0 nodocker=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only="${2:?--only needs a comma-separated list of IDs}"; shift 2 ;;
    -q) quiet=1; shift ;;
    --list) list=1; shift ;;
    --offline) offline=1; shift ;;
    --no-docker) nodocker=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "doc-drift-check: unknown argument: $1 (see -h)" >&2; exit 2 ;;
  esac
done

R="$(git rev-parse --show-toplevel 2>/dev/null || git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "doc-drift-check: not inside a git checkout" >&2; exit 2; }
[ -f "$R/events-processor/go.mod" ] && [ -d "$R/docs" ] || {
  echo "doc-drift-check: $R does not look like the lago umbrella repo" >&2; exit 2; }
FOUND="$R/.claude/skills/research-methodology/scripts"
CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"

# ---- sources (pinned lago-api, history clone, docker CLI) ---------------------------------
API="" H="" DOCKER=0
if [ "$list" -eq 0 ]; then
  if [ "$offline" -eq 1 ]; then
    sha="$(git -C "$R" ls-tree HEAD api | awk '{print $3}')"
    d="$CACHE/lago-api@${sha:0:12}"
    if [ -n "$sha" ] && [ "$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null || true)" = "$sha" ]; then API="$d"; fi
    [ -d "$CACHE/lago-history.git" ] && H="$CACHE/lago-history.git"
  else
    API="$("$FOUND/pinned-checkout.sh" api 2>/dev/null || true)"
    H="$("$FOUND/history-setup.sh" 2>/dev/null || true)"
  fi
  [ -n "$API" ] && [ -d "$API" ] || API=""
  [ -n "$H" ] && git -C "$H" rev-parse -q --verify HEAD >/dev/null 2>&1 || H=""
  if [ "$nodocker" -eq 0 ] && docker compose version >/dev/null 2>&1; then DOCKER=1; fi
fi

# ---- helpers ----------------------------------------------------------------------------
# Repo-file probes return 0 = found, 1 = not found (a missing file counts as not found).
# lago-api / history probes return 2 when that source is unavailable.
at_f() { local n; n="$(grep -nF -m1 -- "$2" "$R/$1" 2>/dev/null | cut -d: -f1 || true)"; [ -n "$n" ] || return 1; LOC="$1:$n"; }
at_e() { local n; n="$(grep -nE -m1 -- "$2" "$R/$1" 2>/dev/null | cut -d: -f1 || true)"; [ -n "$n" ] || return 1; LOC="$1:$n"; }
has_f() { grep -qF -- "$2" "$R/$1" 2>/dev/null; }
has_e() { grep -qE -- "$2" "$R/$1" 2>/dev/null; }
api_f() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }; grep -qF -- "$2" "$API/$1" 2>/dev/null; }
api_e() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }; grep -qE -- "$2" "$API/$1" 2>/dev/null; }
no_clickhouse_client() {   # the EP has no ClickHouse dependency or import
  ! grep -qi 'clickhouse' "$R/events-processor/go.mod" &&
  ! grep -rqE '"github\.com/ClickHouse/' --include='*.go' "$R/events-processor"
}
ddl_cols() {               # count column lines of `CREATE TABLE public.enriched_events (` in $1
  awk 'index($0,"CREATE TABLE public.enriched_events (")==1{f=1;next}
       f && /^\)/ {exit}
       f && /^ +"?[a-z_]+"? [a-z]/ && !/PRIMARY KEY/ {n++}
       END{print n+0}' "$1"
}

# ---- register entries (keep IDs, order and wording in sync with reference/stale-claims.md)
# Each sets ID KIND (doc|code|open|immutable) LOC (default location) MSG, and defines
# claim() (0 = wrong text still present, 1 = gone, 2 = source unavailable) and
# truth() (0 = code anchor still contradicts the claim, 1 = anchor moved, 2 = not checkable).
E=()
def() { ID="$1"; KIND="$2"; LOC="$3"; MSG="$4"; NEED=""; }

E+=(sc01); sc01() { def SC-01 doc events-processor/CLAUDE.md:10 "says direct go build/go test \"won't work locally\"; always lago exec"
  claim() { at_f events-processor/CLAUDE.md "won't work locally"; }
  truth() { has_f .github/workflows/events-processor-tests.yml 'run: go test -v ./...' && has_e events-processor/Dockerfile 'git checkout v[0-9]'; }; }
E+=(sc02); sc02() { def SC-02 doc events-processor/README.md:6 "says the service needs ClickHouse"
  claim() { at_f events-processor/README.md 'configured with Clickhouse'; }
  truth() { no_clickhouse_client; }; }
E+=(sc03); sc03() { def SC-03 doc events-processor/README.md:13 "plain 'go build -o event_processors .' (fails to link; output not gitignored)"
  claim() { at_e events-processor/README.md '^go build -o event_processors'; }
  truth() { has_f events-processor/go.mod 'lago-expression/expression-go' && ! git -C "$R" check-ignore -q events-processor/event_processors; }; }
E+=(sc04); sc04() { def SC-04 doc events-processor/README.md:38 "ENV=production 'to not load .env file' (no .env loader exists)"
  claim() { at_f events-processor/README.md 'to not load `.env` file'; }
  truth() { ! grep -rqi 'dotenv' --include='*.go' --include='go.mod' "$R/events-processor"; }; }
E+=(sc05); sc05() { def SC-05 doc events-processor/README.md:47 "documents LAGO_REDIS_CACHE_* (dead since 2fd8e8b)"
  claim() { at_f events-processor/README.md 'LAGO_REDIS_CACHE_URL'; }
  truth() { local uses; uses="$(grep -rhE 'envLagoRedisCache|"LAGO_REDIS_CACHE_' --include='*.go' "$R/events-processor" | grep -cvE '^[[:space:]]*envLagoRedisCache[A-Za-z]+ += "LAGO_REDIS_CACHE_' || true)"
            [ "$uses" -eq 0 ] && has_f events-processor/processors/main_processor.go 'envLagoRedisCacheURL'; }; }
E+=(sc06); sc06() { def SC-06 doc events-processor/README.md:41 "topic examples events_raw / events_charge_in_advance differ from dev names"
  claim() { at_f events-processor/README.md 'eg: `events_raw`' || at_f events-processor/README.md 'eg: `events_charge_in_advance`'; }
  truth() { has_e .env.development.default '^LAGO_KAFKA_RAW_EVENTS_TOPIC=events-raw$' && has_e .env.development.default '^LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC=events_charged_in_advance$'; }; }
E+=(sc07); sc07() { def SC-07 doc events-processor/README.md:68 "'USE_MEMORY_CACHE' (real: LAGO_USE_MEMORY_CACHE); prefix example lago_dbz vs lago_proc_cdc"
  claim() { at_f events-processor/README.md 'Mandatory if USE_MEMORY_CACHE' || at_f events-processor/README.md 'eg: `lago_dbz`'; }
  truth() { has_f events-processor/main.go '"LAGO_USE_MEMORY_CACHE"' && has_e extra/debezium_config.json '"topic.prefix": *"lago_proc_cdc"'; }; }
E+=(sc08); sc08() { def SC-08 doc events-processor/README.md:56 "LAGO_REDIS_STORE_TLS 'default: false' (true when ENV=production)"
  claim() { at_e events-processor/README.md 'LAGO_REDIS_STORE_TLS.*default: false'; }
  truth() { has_f events-processor/processors/main_processor.go 'legacyTLS := os.Getenv(envEnv) == "production"' &&
            has_f events-processor/processors/main_processor.go 'GetEnvAsBool(envLagoRedisStoreTLS, legacyTLS)'; }; }
E+=(sc09); sc09() { def SC-09 doc events-processor/README.md:40 "multi-broker example breaks the memory-cache consumers (OD-1)"
  claim() { at_f events-processor/README.md 'redpanda:9092,kafka:9092'; }
  truth() { has_f events-processor/cache/consumer.go 'os.Getenv("LAGO_KAFKA_BOOTSTRAP_SERVERS")' && has_f events-processor/cache/consumer.go 'kgo.SeedBrokers(brokers)'; }; }
E+=(sc10); sc10() { def SC-10 doc events-processor/README.md:50 "env tables omit variables the code reads"
  claim() { local v; missing=""
    for v in SENTRY_DSN TRACING_PROVIDER KAFKA_TRACING_ENABLED DD_TRACE_ENABLED DD_AGENT_HOST DD_TRACE_AGENT_PORT DD_SERVICE_NAME LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS; do
      has_f events-processor/README.md "$v" || missing="$missing $v"; done
    [ -n "$missing" ] || return 1; MSG="$MSG:$missing"; }
  truth() { local v; for v in SENTRY_DSN TRACING_PROVIDER KAFKA_TRACING_ENABLED DD_TRACE_ENABLED LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS; do
      grep -rqF "\"$v\"" --include='*.go' "$R/events-processor" || return 1; done; }; }
E+=(sc11); sc11() { def SC-11 doc events-processor/Dockerfile.staging:22 "'bump both together' (the lago-expression ref lives in 4 places)"
  claim() { at_f events-processor/Dockerfile.staging 'bump both together'; }
  truth() { local f n=0
    for f in events-processor/Dockerfile events-processor/Dockerfile.dev events-processor/Dockerfile.staging .github/workflows/events-processor-tests.yml; do
      has_e "$f" 'git checkout v[0-9]|LAGO_EXPRESSION_REF=v[0-9]|ref: v[0-9]' && n=$((n+1)); done
    [ "$n" -eq 4 ]; }; }
E+=(sc12); sc12() { def SC-12 doc docs/dev_environment.md:154 "LAGO_CLICKHOUSE_ENABLED=false disables ClickHouse (MIXED: .present? sites stay on, org creation turns off)"
  claim() { at_f docs/dev_environment.md 'LAGO_CLICKHOUSE_ENABLED=false'; }
  truth() { api_f app/services/events/stores/store_factory.rb 'ENV["LAGO_CLICKHOUSE_ENABLED"].present?' &&
            api_f app/services/organizations/create_service.rb 'ActiveModel::Type::Boolean.new.cast(ENV["LAGO_CLICKHOUSE_ENABLED"])'; }; }
E+=(sc13); sc13() { def SC-13 doc docs/dev_environment.md:158 "env files 'are not interpolated' (they are)"
  claim() { at_f docs/dev_environment.md 'files are not interpolated'; }
  truth() { has_f .env.development.default 'DATABASE_URL=postgresql://${POSTGRES_USER}' || return 1
    [ "$DOCKER" -eq 1 ] || { NEED="docker compose CLI"; return 2; }
    local out; out="$(docker compose -f "$R/docker-compose.dev.yml" config api 2>/dev/null || true)"
    grep -qF 'postgresql://lago:changeme@db:5432/lago' <<<"$out"; }; }
E+=(sc14); sc14() { def SC-14 doc docs/dev_environment.md:97 "/etc/hosts list differs from the Host() rules of docker-compose.dev.yml"
  claim() { local c d miss extra
    c="$(grep -oE 'Host\(`[^`]+`\)' "$R/docker-compose.dev.yml" | sed -E 's/Host\(`([^`]+)`\)/\1/' | sort -u)"
    d="$(grep -oE '127\.0\.0\.1 +[a-z0-9.-]+\.lago\.dev' "$R/docs/dev_environment.md" | awk '{print $2}' | sort -u)"
    miss="$(comm -23 <(printf '%s\n' "$c") <(printf '%s\n' "$d") | tr '\n' ' ')"
    extra="$(comm -13 <(printf '%s\n' "$c") <(printf '%s\n' "$d") | tr '\n' ' ')"
    [ -n "${miss// /}${extra// /}" ] || return 1
    at_f docs/dev_environment.md '# Lago local domains' || true
    MSG="$MSG (doc lacks: ${miss% }; doc extra: ${extra% })"; }
  truth() { has_e docker-compose.dev.yml 'Host\(`'; }; }
E+=(sc15); sc15() { def SC-15 doc "docs/dev_environment.md (absent)" "never mentions the external volume lago_front_pnpm_store"
  claim() { ! has_f docs/dev_environment.md 'lago_front_pnpm_store'; }
  truth() { awk '/^  lago_front_pnpm_store:/{getline; if ($0 ~ /external: true/) f=1} END{exit !f}' "$R/docker-compose.dev.yml"; }; }
E+=(sc16); sc16() { def SC-16 doc docs/dev_environment.md:277 "'Updating a reference': commit the gitlink and git push origin main (change-control N1)"
  claim() { has_f docs/dev_environment.md 'git add api' && at_e docs/dev_environment.md '^git push origin main$'; }
  truth() { [ -n "$H" ] || { NEED="history clone"; return 2; }
    local s; s="$(git -C "$H" log -1 --format=%s ba292b6 2>/dev/null || true)"; grep -qF '(#792)' <<<"$s"; }; }
E+=(sc17); sc17() { def SC-17 doc docs/dev_environment.md:54 "defines the 'lago' alias, never mentions the lago-cli binary of the same name"
  claim() { has_f docs/dev_environment.md 'alias lago=' && ! has_f docs/dev_environment.md 'lago-cli' && at_f docs/dev_environment.md 'alias lago='; }
  truth() { has_f README.md 'getlago/lago-cli'; }; }
E+=(sc18); sc18() { def SC-18 doc docs/architecture.md:89 "env var SIDEKIQ_PDF (real: SIDEKIQ_PDFS)"
  claim() { at_e docs/architecture.md 'SIDEKIQ_PDF([^S]|$)'; }
  truth() { has_e .env.development.default '^SIDEKIQ_PDFS=' && api_f app/jobs/invoices/generate_pdf_job.rb 'ENV["SIDEKIQ_PDFS"]'; }; }
E+=(sc19); sc19() { def SC-19 doc docs/architecture.md:333 "flagged-subscription refresh 'Every 1 minute', needs only LAGO_REDIS_STORE_URL"
  claim() { at_f docs/architecture.md 'Refresh Flagged Subscriptions | Every 1 minute'; }
  truth() { api_f clock.rb 'every(10.seconds, "schedule:refresh_flagged_subscriptions")' &&
            api_f clock.rb 'ENV["LAGO_REDIS_STORE_URL"].present? && ENV["LAGO_CLICKHOUSE_ENABLED"].present?'; }; }
E+=(sc20); sc20() { def SC-20 doc docs/architecture.md:232 "events-processor 'Processes and aggregates usage events'"
  claim() { at_f docs/architecture.md 'Processes and aggregates usage events'; }
  truth() { no_clickhouse_client; }; }
E+=(sc21); sc21() { def SC-21 doc docs/architecture.md:546 "glossary inverts Customer and User"
  claim() { at_f docs/architecture.md '**Customer**: An individual or entity that operates within the application'; }
  truth() { api_f app/models/user.rb 'has_secure_password' && api_e app/models/customer.rb '^  belongs_to :organization'; }; }
E+=(sc22); sc22() { def SC-22 doc docs/architecture.md:67 "retry semantics ('Retry: 1 attempt', 'Retry #1 with exponential backoff')"
  claim() { at_f docs/architecture.md '**Retry**: 1 attempt' || at_f docs/architecture.md 'Retry #1 (with exponential backoff)'; }
  truth() { api_f app/jobs/application_job.rb 'sidekiq_options retry: 0' &&
            api_f app/jobs/application_job.rb 'retry_on RetriableError, wait: :polynomially_longer, attempts: 20' &&
            api_f config/initializers/sidekiq.rb 'config[:max_retries] = 0'; }; }
E+=(sc23); sc23() { def SC-23 doc docs/architecture.md:212 "'wallets' in the default worker / 'deprecated' (it is a live dedicated queue)"
  claim() { at_f docs/architecture.md '`invoices`, `wallets`, `integrations`' || at_f docs/architecture.md '| `wallets` | (deprecated' ||
            at_f docs/monitoring.md '| `wallets` | Default Worker (deprecated) |'; }
  truth() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }
    ! grep -qE '^ *- wallets' "$API/config/sidekiq/sidekiq.yml" && grep -qE '^ *- wallets' "$API/config/sidekiq/sidekiq_wallets.yml"; }; }
E+=(sc24); sc24() { def SC-24 doc docs/architecture.md:495 "env var RSA_PRIVATE_KEY (real: LAGO_RSA_PRIVATE_KEY or config/keys/private.pem)"
  claim() { at_f docs/architecture.md '`RSA_PRIVATE_KEY`' || at_f docs/architecture.md '#### 3b. RSA_PRIVATE_KEY'; }
  truth() { api_f config/initializers/rsa_keys.rb 'ENV["LAGO_RSA_PRIVATE_KEY"]'; }; }
E+=(sc25); sc25() { def SC-25 doc docs/architecture.md:527 "'Usage event' and 'Billing creation' are placeholders"
  claim() { at_f docs/architecture.md 'will be added to this section in a future update'; }
  truth() { return 0; }; }
E+=(sc26); sc26() { def SC-26 doc docs/arch_diagram.png "diagram: events-processor has no Postgres/Redis edge; no Debezium"
  claim() { [ "$(git -C "$R" hash-object docs/arch_diagram.png 2>/dev/null || true)" = 206170d902009a48b8101f0293edf30c7e207e15 ]; }
  truth() { has_f events-processor/processors/main_processor.go 'os.Getenv("DATABASE_URL")' &&
            has_f events-processor/processors/main_processor.go 'os.Getenv(envLagoRedisStoreURL)' && has_f extra/debezium_config.json '"topic.prefix"'; }; }
E+=(sc27); sc27() { def SC-27 doc docs/database_partitioning.md:58 "retroactive DDL column count differs from the schema (step 5 INSERT fails)"
  claim() { local d a; d="$(ddl_cols "$R/docs/database_partitioning.md")"
    if [ -n "$API" ]; then a="$(ddl_cols "$API/db/structure.sql")"; else a=18; fi
    [ "$d" -ne "$a" ] || return 1
    at_f docs/database_partitioning.md 'CREATE TABLE public.enriched_events (' || true
    MSG="$MSG (doc $d vs schema $a)"; }
  truth() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }; [ "$(ddl_cols "$API/db/structure.sql")" -gt 0 ]; }; }
E+=(sc28); sc28() { def SC-28 doc docs/database_partitioning.md:251 "'No additional setup' with the default compose (only dev mounts postgresql.conf)"
  claim() { at_f docs/database_partitioning.md 'No additional setup is required when using the default Docker Compose configuration'; }
  truth() { ! has_f docker-compose.yml 'postgresql.conf' && has_f docker-compose.dev.yml './scripts/postgresql.conf:/etc/postgresql.conf'; }; }
E+=(sc29); sc29() { def SC-29 doc docs/monitoring.md:47 "metrics from a 'lago-sidekiqs' service at /prometheus/metrics; omits lago-api's own exporters"
  claim() { at_f docs/monitoring.md 'lago-sidekiqs'; }
  truth() { api_f config/routes.rb 'at: "/sidekiq/prometheus/metrics"' && api_f config/routes.rb 'mount Yabeda::Prometheus::Exporter, at: "/metrics"'; }; }
E+=(sc30); sc30() { def SC-30 doc deploy/README.md:21 "'docker compose up --profile X' (--profile is a global flag)"
  claim() { local n; n="$(grep -cE 'docker compose up( -d)? --profile' "$R/deploy/README.md" 2>/dev/null || true)"
    [ "${n:-0}" -gt 0 ] || return 1; at_e deploy/README.md 'docker compose up( -d)? --profile' || true; MSG="$MSG ($n commands)"; }
  truth() { [ "$DOCKER" -eq 1 ] || { NEED="docker compose CLI"; return 2; }
    local h; h="$(docker compose up --help 2>&1 || true)"; ! grep -qF -- '--profile' <<<"$h"; }; }
E+=(sc31); sc31() { def SC-31 code deploy/deploy.sh:106 "deploy.sh defects (dead running-project check; file-name mismatch; status lines into .env)"
  claim() { local b=0
    has_f deploy/deploy.sh 'ps -q &>/dev/null' && b=$((b+1))
    has_f deploy/deploy.sh 'curl -s -o docker-compose.yml https://deploy.getlago.com/docker-compose.local.yml' &&
      has_f deploy/deploy.sh 'docker compose -f docker-compose.local.yml up -d' && b=$((b+1))
    has_f deploy/deploy.sh 'echo "${GREEN}✅ $var is already set.${NORMAL}"' && has_f deploy/deploy.sh '} > "$ENV_FILE"' && b=$((b+1))
    [ "$b" -gt 0 ] || return 1; at_f deploy/deploy.sh 'ps -q &>/dev/null' || true; MSG="$MSG ($b of 3 present)"; }
  truth() { return 0; }; }
E+=(sc32); sc32() { def SC-32 doc docker/README.md:40 "DATABASE_URL default password 'lago' (runner.sh generates a random one)"
  claim() { at_f docker/README.md 'postgres://lago:lago@localhost:5432/lago'; }
  truth() { has_e docker/runner.sh '\[POSTGRES_PASSWORD\]=\$\(openssl rand' && has_f docker/runner.sh 'postgresql://lago:$POSTGRES_PASSWORD@localhost:5432/lago'; }; }
E+=(sc33); sc33() { def SC-33 doc connectors/README.md:20 "event format: numeric precise_total_amount_cents (EP drops it), no organization_id (HTTP); Kinesis table lacks ORGANIZATION_ID"
  claim() { local b=0 first=""
    at_f connectors/README.md '"precise_total_amount_cents": 1000' && { b=$((b+1)); first="$LOC"; }
    has_f connectors/README.md 'organization_id' || { b=$((b+1)); first="${first:-connectors/README.md:8}"; }
    awk '/^## Kinesis Connector/{f=1;next} /^## /{f=0} f && /ORGANIZATION_ID/{x=1} END{exit x}' "$R/connectors/README.md" && { b=$((b+1)); first="${first:-connectors/README.md:54}"; }
    [ "$b" -gt 0 ] || return 1; LOC="$first"; MSG="$MSG ($b of 3 present)"; }
  truth() { has_e events-processor/models/event.go 'PreciseTotalAmountCents +string' &&
            has_f connectors/http.yml 'precise_total_amount_cents.type() == "number"' &&
            has_f connectors/http.yml 'root.organization_id = this.event.organization_id' &&
            has_f connectors/kinesis.yml 'root.organization_id = "${ORGANIZATION_ID}"'; }; }
E+=(sc34); sc34() { def SC-34 code .env.development.default:3 "LAGO_MCP_SERVER_URL points at an mcp-server service no compose file in this repo defines (lago-agent-toolkit overlay, undocumented)"
  claim() { at_e .env.development.default '^LAGO_MCP_SERVER_URL=.*mcp-server'; }
  truth() { local f; for f in docker-compose.yml docker-compose.dev.yml deploy/docker-compose.local.yml deploy/docker-compose.light.yml \
      deploy/docker-compose.production.yml examples/agentic-ai-demo/compose.yml; do has_e "$f" '^  mcp-server:' && return 1; done; return 0; }; }
E+=(sc35); sc35() { def SC-35 doc PULL_REQUEST_TEMPLATE.md:14 "requires 'pnpm test' (no package.json in this repo)"
  claim() { at_f PULL_REQUEST_TEMPLATE.md 'pnpm test'; }
  truth() { [ "$(git -C "$R" ls-files '*package.json' | wc -l)" -eq 0 ]; }; }
E+=(sc36); sc36() { def SC-36 open PULL_REQUEST_TEMPLATE.md:8 "OPEN DECISION OD-7: fix/ feature/ branches MUST; subject <=72 (CONTRIBUTING) vs <=50 (\$API/AGENTS.md)"
  claim() { at_f PULL_REQUEST_TEMPLATE.md 'start with either the `fix/` or `feature/`' && return 0
    has_f CONTRIBUTING.md 'Limit the first line to 72 characters' && api_f AGENTS.md 'The first line must be 50 characters or less' && LOC=CONTRIBUTING.md:170; }
  truth() { return 0; }; }
E+=(sc37); sc37() { def SC-37 doc "\$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11" "lago-api comment: ZSET score is 'the event timestamp' (Go writes wall-clock time)"
  claim() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }
    local p=app/services/subscriptions/consume_subscription_refreshed_queue_service.rb n
    n="$(grep -nF -m1 'using the event timestamp as score' "$API/$p" 2>/dev/null | cut -d: -f1 || true)"
    [ -n "$n" ] || return 1; LOC="\$API/$p:$n"; }
  truth() { has_f events-processor/models/stores.go 'now := time.Now().Unix()' && has_e events-processor/models/stores.go 'Score: +float64\(now\)'; }; }
E+=(sc38); sc38() { def SC-38 immutable "commit 5308258 message" "says lago-deploy kept the AWS account id out of public repos (it is in public workflows)"
  claim() { [ -n "$H" ] || { NEED="history clone"; return 2; }
    local m; m="$(git -C "$H" log -1 --format=%B 5308258 2>/dev/null || true)"; grep -qF 'AWS account id out of a public repository' <<<"$m"; }
  truth() { grep -qE '[0-9]{12}\.dkr\.ecr\.' "$R"/.github/workflows/*.y*ml 2>/dev/null; }; }

E+=(sc39); sc39() { def SC-39 doc docs/dev_environment.md:290 "Mailpit catches dev mail, but lago-api sends to SMTP host mailhog:1025 (no such service or alias)"
  claim() { at_f docs/dev_environment.md 'We rely on [Mailpit]' && ! has_f docs/dev_environment.md 'mailhog'; }
  truth() { has_e docker-compose.dev.yml '^  mailpit:' && ! has_f docker-compose.dev.yml 'mailhog' &&
            api_f config/environments/development.rb 'address: "mailhog"'; }; }
E+=(sc40); sc40() { def SC-40 doc connectors/README.md:31 "documents LOG_LEVEL, which no connector config reads"
  claim() { at_f connectors/README.md '|LOG_LEVEL|'; }
  truth() { ! grep -qF 'LOG_LEVEL' "$R"/connectors/*.yml "$R/connectors/Dockerfile" 2>/dev/null; }; }
E+=(sc41); sc41() { def SC-41 doc README.md:190 "Prometheus metrics 'for APIs, queues, workers, events, billing, webhooks, and dependencies' (lago-api: requests+Puma; Sidekiq only with LAGO_SIDEKIQ_WEB; EP none)"
  claim() { at_f README.md 'Prometheus metrics for APIs, queues, workers, events, billing, webhooks'; }
  truth() { [ -n "$API" ] || { NEED="pinned lago-api"; return 2; }
    api_f config/routes.rb 'mount Yabeda::Prometheus::Exporter, at: "/metrics"' &&
    ! grep -rqF 'Yabeda.' "$API/app" "$API/lib" 2>/dev/null &&
    ! grep -rqE 'ListenAndServe|promhttp' --include='*.go' "$R/events-processor"; }; }
E+=(sc42); sc42() { def SC-42 doc docs/database_partitioning.md:84 "retroactive steps: step 4 index names collide with the renamed table's; step 3 PRIMARY KEY absent from the schema"
  claim() { local b=0 first=""
    if has_f docs/database_partitioning.md 'RENAME TO enriched_events_old' && ! has_e docs/database_partitioning.md '(DROP|ALTER) INDEX'; then
      at_f docs/database_partitioning.md 'CREATE INDEX idx_billing_on_enriched_events' && { b=$((b+1)); first="$LOC"; }; fi
    at_e docs/database_partitioning.md '^ +PRIMARY KEY \(id, "timestamp"\)' && { b=$((b+1)); first="${first:-$LOC}"; }
    [ "$b" -gt 0 ] || return 1; LOC="$first"; MSG="$MSG ($b of 2 present)"; }
  truth() { api_f db/migrate/20260109110146_create_enriched_events.rb 'name: "idx_billing_on_enriched_events"' || return $?
    ! grep -qE 'enriched_events_pkey|enriched_events.*PRIMARY KEY' "$API/db/structure.sql"; }; }

# ---- evaluate -----------------------------------------------------------------------------
n_STALE=0 n_PASS=0 n_RECHECK=0 n_OPEN=0 n_KNOWN=0 n_SKIP=0 total=0
for e in "${E[@]}"; do
  "$e"
  if [ -n "$only" ] && [[ ",$only," != *",$ID,"* ]]; then continue; fi
  total=$((total+1))
  if [ "$list" -eq 1 ]; then printf '%-6s %-9s %-52s %s\n' "$ID" "$KIND" "$LOC" "$MSG"; continue; fi
  note=""
  if claim; then c=0; else c=$?; fi
  if [ "$c" -eq 2 ]; then st=SKIP; note=" [needs $NEED]"
  elif [ "$c" -ne 0 ]; then st=PASS; note=" -> claim gone: re-read the doc, then mark $ID FIXED"
  else
    case "$KIND" in
      open) st=OPEN ;;
      immutable) st=KNOWN ;;
      *) if truth; then t=0; else t=$?; fi
         case "$t" in
           0) st=STALE ;;
           1) st=RECHECK; note=" -> code anchor moved: re-verify $ID" ;;
           *) st=STALE; note=" [anchor not re-checked: no $NEED]" ;;
         esac ;;
    esac
  fi
  case "$st" in
    STALE) n_STALE=$((n_STALE+1)) ;; PASS) n_PASS=$((n_PASS+1)) ;; RECHECK) n_RECHECK=$((n_RECHECK+1)) ;;
    OPEN) n_OPEN=$((n_OPEN+1)) ;; KNOWN) n_KNOWN=$((n_KNOWN+1)) ;; SKIP) n_SKIP=$((n_SKIP+1)) ;;
  esac
  [ "$quiet" -eq 1 ] || printf '%-8s %-6s %-52s %s%s\n' "$st" "$ID" "$LOC" "$MSG" "$note"
done
[ "$list" -eq 1 ] && exit 0
[ "$total" -gt 0 ] || { echo "doc-drift-check: no entry matches --only $only" >&2; exit 2; }
yn() { if [ -n "$1" ] && [ "$1" != 0 ]; then echo yes; else echo no; fi; }
echo "SUMMARY doc-drift-check: entries=$total STALE=$n_STALE PASS=$n_PASS RECHECK=$n_RECHECK OPEN=$n_OPEN KNOWN=$n_KNOWN SKIP=$n_SKIP (pinned lago-api: $(yn "$API"); history clone: $(yn "$H"); docker CLI: $(yn "$DOCKER"))"
bad=$(( n_STALE + n_RECHECK )); [ "$bad" -le 255 ] || bad=255
exit "$bad"
