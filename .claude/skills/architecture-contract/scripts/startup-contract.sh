#!/usr/bin/env bash
set -euo pipefail
# startup-contract.sh — prove the events-processor startup contract (only partially fail-fast: architecture-contract
# I14) by running the REAL binary with environment variables added one step at a time, and checking each panic /
# log line. Step ids: S0-S7 (default run) and SK1-SK9 (need --broker; SK5-SK9 also Postgres, SK7-SK9 --redis);
# architecture-contract SKILL.md section 2 and reference/startup-and-shutdown.md map them to startup steps.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/architecture-contract/scripts/startup-contract.sh [options]
#     --bin PATH        reuse an already built binary (default: build one into a temp dir, ~60 s cold)
#     --pg URL          a reachable Postgres for the steps that need one
#                       (default: $DATABASE_URL, else postgres://lago:lago@localhost:5432/lago)
#     --broker H:P      a DISPOSABLE Kafka broker (e.g. an in-process kfake from the diagnostics-and-tooling
#                       skill) to run the steps after the producer Ping. Never a shared broker: the last
#                       step joins a consumer group (on a random, unused topic name).
#     --redis H:P       a disposable plaintext Redis (e.g. miniredis) for the flag-store and full-start steps
#     --wait SECS       how long the full-start steps run before SIGTERM (default 6)
#     --out DIR         keep every step's log in DIR (default: temp dir, deleted on exit)
#     -v                print each step's last log lines
#
# No Kafka, Redis or Docker is needed for the default run (steps S0-S7). Postgres is only needed for S6
# (skipped when unreachable). The binary is built with the CGO env from
# .claude/skills/build-and-env/scripts/ep-env.sh and run with `env -i` (nothing leaks from your shell).
# Read-only on the repo: the build output and logs go to a temp dir (or --out).
# Needs: go, GNU coreutils `timeout`, and on first use cargo + network (ep-env.sh builds libexpression_go.so).
#
# Output: one line per step, PASS | FAIL | SKIP, with the observed panic / log line; last line
#   SUMMARY steps=<n> fails=<n> logs=<dir>
# Exit code: 0 = no FAIL (the startup contract documented in the architecture-contract skill still holds),
# 1 = at least one FAIL (count in the SUMMARY line), 2 = setup error (cannot build, bad arguments).
# Expected as of 2026-10-01 (code as of 5308258): default run "SUMMARY steps=9 fails=0" (S6 SKIP without Postgres;
# SK1-SK9 one SKIP line); with --broker + --redis + reachable Postgres "SUMMARY steps=17 fails=0".

BIN=""; PG="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"; BROKER=""; REDIS=""; WAIT=6; OUTDIR=""; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN="${2:?}"; shift 2 ;;
    --pg) PG="${2:?}"; shift 2 ;;
    --broker) BROKER="${2:?}"; shift 2 ;;
    --redis) REDIS="${2:?}"; shift 2 ;;
    --wait) WAIT="${2:?}"; shift 2 ;;
    --out) OUTDIR="${2:?}"; shift 2 ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside the lago git checkout" >&2; exit 2; }
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
LOGS="${OUTDIR:-$WORK/logs}"; mkdir -p "$LOGS"

# CGO env (libexpression_go.so path); ep-env.sh is a foundation script owned by build-and-env.
set +u
# shellcheck disable=SC1091
source "$REPO/.claude/skills/build-and-env/scripts/ep-env.sh" 2>/dev/null || { echo "ep-env.sh failed (cargo/network?)" >&2; exit 2; }
set -u
LIB="$LAGO_EXPRESSION_LIB"

if [ -z "$BIN" ]; then
  echo "building events-processor into $WORK (go build, ~60 s cold) ..." >&2
  (cd "$REPO/events-processor" && go build -o "$WORK/ep" .) || { echo "go build failed" >&2; exit 2; }
  BIN="$WORK/ep"
fi
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }

FAILS=0; N=0
pg_ok() { command -v pg_isready >/dev/null 2>&1 && pg_isready -q -d "$PG" 2>/dev/null; }

# run_step ID "description" "expect1|||expect2|||!absent" TIMEOUT NOLIB(0/1) VAR=VAL ...
run_step() {
  local id="$1" desc="$2" expects="$3" t="$4" nolib="$5"; shift 5
  local log="$LOGS/$id.log" rc=0 ok=1 e libenv=()
  N=$((N + 1))
  [ "$nolib" = 1 ] || libenv=("LD_LIBRARY_PATH=$LIB")
  env -i PATH=/usr/bin:/bin "${libenv[@]}" "$@" timeout -s TERM -k 5 "$t" "$BIN" > "$log" 2>&1 || rc=$?
  local IFS=$'\n'
  for e in $(printf '%s' "$expects" | sed 's/|||/\n/g'); do
    if [ "${e#!}" != "$e" ]; then grep -qF -- "${e#!}" "$log" && ok=0
    else grep -qF -- "$e" "$log" || ok=0; fi
  done
  unset IFS
  local obs
  obs="$(grep -m1 -E '^panic: |^fatal error|cannot open shared object|"msg":"Starting event consumer"' "$log" || true)"
  [ -n "$obs" ] || obs="$(grep -m1 '"level":"ERROR"' "$log" | cut -c1-200 || true)"
  if [ "$ok" = 1 ]; then echo "PASS $id $desc"; else echo "FAIL $id $desc"; FAILS=$((FAILS + 1)); fi
  echo "     exit=$rc observed: ${obs:-<no panic/error line>}"
  local m; m="$(grep -m1 '"level":"ERROR"' "$log" | sed -E 's/.*"msg":"(([^"\\]|\\.)*)".*/\1/' | cut -c1-160 || true)"
  [ -z "$m" ] || echo "     first ERROR log msg: $m"
  if [ "$ok" != 1 ]; then echo "     expected all of: $(printf '%s' "$expects" | sed 's/|||/ AND /g')"; fi
  if [ "$VERBOSE" = 1 ]; then tail -n 5 "$log" | cut -c1-220 | sed 's/^/     | /'; fi
}
skip() { N=$((N + 1)); echo "SKIP $1 $2 ($3)"; }

UNREACH_BROKER="127.0.0.1:1"
UNREACH_PG="postgres://lago:lago@127.0.0.1:1/lago"
T_ENR="LAGO_KAFKA_ENRICHED_EVENTS_TOPIC=events_enriched"
T_CIA="LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC=events_charged_in_advance"
T_DLQ="LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC=events_dead_letter"

echo "== default steps (no Kafka / Redis / Docker needed)"
if ldconfig -p 2>/dev/null | grep -q libexpression_go; then
  skip S0 "binary without LD_LIBRARY_PATH" "libexpression_go.so is installed system-wide here"
else
  run_step S0 "binary without LD_LIBRARY_PATH -> dynamic loader error (before main)" \
    "libexpression_go.so: cannot open shared object file" 10 1
fi
run_step S1 "empty env -> panic 'brokers not found' (processors/main_processor.go:103-107)" \
  'panic: brokers not found|||"msg":"brokers not found"' 15 0
run_step S2 "+ LAGO_KAFKA_BOOTSTRAP_SERVERS -> enriched topic required (main_processor.go:56-58,118-121)" \
  'panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required|||"msg":"failed to initialize enriched events producer"' 15 0 \
  "LAGO_KAFKA_BOOTSTRAP_SERVERS=$UNREACH_BROKER"
run_step S3 "+ enriched topic, broker unreachable -> producer Ping fails (main_processor.go:70-73)" \
  'panic: unable to dial|||"msg":"failed to initialize enriched events producer"' 30 0 \
  "LAGO_KAFKA_BOOTSTRAP_SERVERS=$UNREACH_BROKER" "$T_ENR"
run_step S4 "+ LAGO_KAFKA_SCRAM_ALGORITHM=PLAIN -> nil kgo.Opt SIGSEGV, no log line (config/kafka/kafka.go:48-64)" \
  'panic: runtime error: invalid memory address or nil pointer dereference|||kgo.validateCfg|||!"level":"ERROR"' 15 0 \
  "LAGO_KAFKA_BOOTSTRAP_SERVERS=$UNREACH_BROKER" "$T_ENR" "LAGO_KAFKA_SCRAM_ALGORITHM=PLAIN"
run_step S5 "cache mode, Postgres unreachable -> snapshot connect panic BEFORE any Kafka check (cache/cache.go:69-72)" \
  '"msg":"Error connecting to the database"|||cache.(*Cache).LoadInitialSnapshot|||!brokers not found' 20 0 \
  "LAGO_USE_MEMORY_CACHE=true" "DATABASE_URL=$UNREACH_PG"
if pg_ok; then
  run_step S6 "cache mode, Postgres reachable, no brokers -> 6 loaders + 6 CDC consumers start, THEN 'brokers not found'" \
    '"msg":"Starting snapshot load"|||"group_id":"lago_evp_subscriptions_|||"group_id":"lago_evp_charges_|||panic: brokers not found' 30 0 \
    "LAGO_USE_MEMORY_CACHE=true" "DATABASE_URL=$PG"
  echo "     snapshot loads completed: $(grep -c '"msg":"Completed snapshot load"' "$LOGS/S6.log" || true)/6 ; SQL errors swallowed: $(grep -c '"component":"db"' "$LOGS/S6.log" || true) (0/6 + 6 errors = empty DB: the process continues anyway)"
else
  skip S6 "cache mode with reachable Postgres" "Postgres at $PG not reachable (pg_isready)"
fi
run_step S7 "LAGO_USE_MEMORY_CACHE=1 is NOT cache mode (literal \"true\" only, main.go:67)" \
  'panic: brokers not found|||!Starting snapshot load' 15 0 \
  "LAGO_USE_MEMORY_CACHE=1" "DATABASE_URL=$UNREACH_PG"

echo "== broker steps (need --broker; Redis steps also need --redis)"
if [ -z "$BROKER" ]; then
  skip SK1-SK9 "steps after the producer Ping" "no --broker given"
else
  B="LAGO_KAFKA_BOOTSTRAP_SERVERS=$BROKER"
  run_step SK1 "+ reachable broker -> in-advance topic required (main_processor.go:123-126)" \
    'panic: LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC variable is required' 20 0 "$B" "$T_ENR"
  run_step SK2 "+ in-advance topic -> DLQ topic required (main_processor.go:128-131)" \
    'panic: LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC variable is required' 20 0 "$B" "$T_ENR" "$T_CIA"
  run_step SK3 "+ DLQ topic, bad max connections -> int parse panic (main_processor.go:134-137)" \
    '"msg":"Error converting max connections into integer"|||panic: strconv.Atoi: parsing "abc"' 20 0 \
    "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS=abc"
  run_step SK4 "DB mode, Postgres unreachable (main_processor.go:144-147)" \
    '"msg":"Error connecting to the database"|||processors.StartProcessingEvents' 20 0 \
    "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$UNREACH_PG"
  if pg_ok; then
    run_step SK5 "+ Postgres OK, LAGO_REDIS_STORE_DB=x -> flag store panic (main_processor.go:79-82,152-155)" \
      '"msg":"Error connecting to the flag store"|||panic: strconv.Atoi: parsing "x"' 20 0 \
      "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$PG" "LAGO_REDIS_STORE_DB=x"
    run_step SK6 "+ Redis unreachable -> Ping fails after go-redis dial retries (config/redis/redis.go:50-53)" \
      '"msg":"Error connecting to the flag store"|||connect: connection refused' 30 0 \
      "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$PG" "LAGO_REDIS_STORE_URL=127.0.0.1:1"
    if [ -z "$REDIS" ]; then
      skip SK7-SK9 "Redis-dependent steps" "no --redis given"
    else
      R="LAGO_REDIS_STORE_URL=$REDIS"
      run_step SK7 "ENV=production turns Redis TLS on (legacy default, main_processor.go:85,91) -> plaintext Redis fails" \
        '"msg":"Error connecting to the flag store"' 30 0 \
        "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$PG" "$R" "ENV=production"
      TOPIC="startup-contract-probe-$$-$RANDOM"
      run_step SK8 "full start + SIGTERM after ${WAIT}s -> group <group>_<topic>, graceful shutdown" \
        "\"msg\":\"Starting event consumer\"|||\"msg\":\"Received shutdown signal\"|||\"msg\":\"Gracefully shutting down consumer group\"|||\"msg\":\"Consumer group shutdown is complete\"|||\"msg\":\"Event processor stopped\"|||!panic:" \
        "$WAIT" 0 "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$PG" "$R" \
        "LAGO_KAFKA_RAW_EVENTS_TOPIC=$TOPIC" "LAGO_KAFKA_CONSUMER_GROUP=startup-contract"
      echo "     group id seen in log: $(grep -m1 -oE '"group":"[^"]*"' "$LOGS/SK8.log" || echo '<none logged>') (expected startup-contract_$TOPIC)"
      run_step SK9 "empty LAGO_KAFKA_RAW_EVENTS_TOPIC / LAGO_KAFKA_CONSUMER_GROUP are NOT validated -> starts and idles" \
        '"msg":"Starting event consumer"|||!panic:' "$WAIT" 0 \
        "$B" "$T_ENR" "$T_CIA" "$T_DLQ" "DATABASE_URL=$PG" "$R"
    fi
  else
    skip SK5-SK9 "steps after the DB connection" "Postgres at $PG not reachable (pg_isready)"
  fi
fi

echo "SUMMARY steps=$N fails=$FAILS logs=${OUTDIR:-<deleted temp dir>}"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
