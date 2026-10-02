#!/usr/bin/env bash
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# oracle.sh — the kit's executable oracle: run the PINNED lago-api (591ae9005110) without Docker, either as its
# own rspec suite or as an adapter that answers kit ops (adapter protocol v1) with lago-api code.
#
# Usage:
#   oracle.sh setup            idempotent: Ruby 4.0.6 (conda-forge), writable copy, gems (under bundle.lock), RSA keys,
#                              Redis on :$ORACLE_REDIS_PORT, Postgres DB $ORACLE_DB (structure.sql minus pg_partman)
#   oracle.sh db [--reset]     (re)create $ORACLE_DB only (when missing or at the wrong migration count; --reset drops
#                              and recreates it even when current, e.g. after rows leaked from non-transactional specs)
#   oracle.sh clickhouse       optional, idempotent, under ch.lock: local ClickHouse on 127.0.0.1:8123 + CH migrations
#   oracle.sh run [-j N] [-r FILE]... <spec paths...>
#                              rspec on files/dirs relative to the writable copy; a file may carry an rspec location
#                              (spec/x_spec.rb:42, spec/x_spec.rb:42:57, spec/x_spec.rb[1:2:1]) to run single examples.
#                              ClickHouse-tagged files run only when ClickHouse answers and ORACLE_CLICKHOUSE != 0, all
#                              in job 1, under ch.lock; untagged files that use the ClickHouse events store
#                              (clickhouse_events_store) also run in job 1 under ch.lock when ClickHouse answers.
#                              -j N splits the other files round-robin over $ORACLE_DB, ${ORACLE_DB}_2..N (cloned).
#                              -r FILE is passed to rspec as --require (e.g. a vector recorder). Prints one JSON
#                              summary line + "FAILED <file:line>" lines; per-job logs under $STATE/runs/.
#   oracle.sh adapter          exec the oracle adapter (stdin/stdout JSON lines) — use as
#                              kitrun.py --impl-cmd "<path>/oracle.sh adapter"
#   oracle.sh env              print the exports used for rspec/adapter: eval "$(oracle.sh env)"
#   oracle.sh status           what exists / is running
#   oracle.sh stop             stop the Redis and ClickHouse this script started
#
# Environment (K7_* names of the original recipe are honoured as fallbacks):
#   LAGO_SKILLS_CACHE      cache root (default ~/.cache/lago-skills)
#   ORACLE_DB              Postgres test database (default lago_api_test_oracle). Use ONE DATABASE PER PERSON/AGENT:
#                          the spec suite deletes every row of its database before it starts.
#   ORACLE_API_RO          pinned read-only checkout (default $LAGO_SKILLS_CACHE/lago-api@591ae9005110)
#   ORACLE_APP             writable copy (default $LAGO_SKILLS_CACHE/lago-api-run@591ae90)
#   ORACLE_REDIS_PORT      (default 6391)   ORACLE_PG_ADMIN_URL (default postgres://lago:lago@localhost:5432/lago)
#   ORACLE_CLICKHOUSE=0    never run ClickHouse-tagged files      ORACLE_CH_BIN / ORACLE_LIBCLANG_PATH overrides
#   ORACLE_OPS_DIR         directory of op modules for the adapter (default <this dir>/oracle-adapter/ops)
#
# Exit codes: 0 ok; 1 rspec reported failures / usage; 2 setup error (missing tool, service did not start).
#
# Writes ONLY to $LAGO_SKILLS_CACHE (tools/, micromamba-root/, rubies/ruby-4.0.6-conda, the writable copy, k7-state/)
# plus the Postgres databases named above and the ClickHouse `default` database of the server it starts.
# Never touches the pinned checkout or the umbrella repository.
#
# Gotchas (each hit while building the recipe; see reference/maintainer-oracle.md):
#  G1 cache.ruby-lang.org / GitHub archives refused by the egress proxy -> Ruby 4.0.6 comes from conda-forge.
#  G2 Bundler ignores HTTPS_PROXY; it needs HTTP_PROXY=<same URL> during bundle install only.
#  G3 lago-expression (Rust, bindgen) needs a libclang WITH resource headers: LIBCLANG_PATH=/usr/lib/llvm-18/lib.
#  G4 spec_helper connects to ClickHouse when ANY loaded example has :clickhouse metadata -> drop such files when
#     no server runs.
#  G5 structure.sql creates the pg_partman extension (not installed) -> load it without that one line.
#  G6 Shared Postgres (max_connections 100): "too many clients already" is transient; rerun. Keep -j small.
#  G7 rails tasks in test env need ANNOTATERB_SKIP_ON_DB_TASKS=1.   G8 LANG/LC_ALL unset -> export C.UTF-8.
#  G9 Never run bundle install concurrently in the shared copy (bundle.lock); ClickHouse-tagged suites wipe CH
#     tables (ch.lock).
set -euo pipefail

C=${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}
PIN=591ae9005110
API_RO=${ORACLE_API_RO:-${K7_API_RO:-$C/lago-api@$PIN}}
APP=${ORACLE_APP:-${K7_APP:-$C/lago-api-run@591ae90}}
RUBY_PREFIX=$C/rubies/ruby-4.0.6-conda
MAMBA=$C/tools/micromamba-2.9.0/bin/micromamba
STATE=$C/k7-state
REDIS_PORT=${ORACLE_REDIS_PORT:-${K7_REDIS_PORT:-6391}}
PGURL_ADMIN=${ORACLE_PG_ADMIN_URL:-${K7_PG_ADMIN_URL:-postgres://lago:lago@localhost:5432/lago}}
PGBASE=${PGURL_ADMIN%/*}
DB=${ORACLE_DB:-${K7_DB:-lago_api_test_oracle}}
CA=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}   # set SSL_CERT_FILE when HTTPS goes through an intercepting proxy
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OPS_DIR=${ORACLE_OPS_DIR:-$HERE/oracle-adapter/ops}
CH_RE='(^|[^_a-z])clickhouse: (true|\{)|, :clickhouse([^_a-z]|$)'
CHW_RE='clickhouse_events_store'   # untagged specs whose scenarios write ClickHouse rows (no wipe): lock, never drop
LOC_RE='^(.+_spec\.rb)((:[0-9]+)+|\[[0-9:,]+\])$'   # rspec location suffix: file:line[:line...] or file[ids]

log() { printf '[oracle %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

case "$DB" in *[!a-z0-9_]*|"") die "ORACLE_DB must match [a-z0-9_]+ (got '$DB')" ;; esac

base_env() {
  export PATH=$RUBY_PREFIX/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
  export LIBCLANG_PATH=${ORACLE_LIBCLANG_PATH:-${K7_LIBCLANG_PATH:-/usr/lib/llvm-18/lib}}
  export BUNDLE_GEMFILE=$APP/Gemfile BUNDLE_SSL_CA_CERT=$CA
  unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH
}

# Mirrors the env block of the reference CI workflow (minus knapsack), pointed at local services.
test_env_lines() {
  cat <<EOF
export PATH=$RUBY_PREFIX/bin:\$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
export BUNDLE_GEMFILE=$APP/Gemfile
unset HTTP_PROXY http_proxy RUBYOPT RUBYLIB GEM_HOME GEM_PATH
export RAILS_ENV=test
export DATABASE_URL=$PGBASE/$DB
export LAGO_REDIS_CACHE_URL=redis://localhost:$REDIS_PORT
export LAGO_REDIS_STORE_URL=localhost:$REDIS_PORT
export REDIS_URL=redis://localhost:$REDIS_PORT
export SECRET_KEY_BASE=oracle-test-secret-key-base-not-secret
export LAGO_API_URL=https://api.lago.dev
export LAGO_PDF_URL=https://pdf.lago.dev
export LAGO_DATA_API_URL=http://data_api
export LAGO_FROM_EMAIL=noreply@getlago.com
export LAGO_CLICKHOUSE_ENABLED=true
export LAGO_CLICKHOUSE_HOST=localhost
export LAGO_CLICKHOUSE_DATABASE=default
export LAGO_CLICKHOUSE_USERNAME=default
export LAGO_CLICKHOUSE_PASSWORD=password
export LAGO_KAFKA_BOOTSTRAP_SERVERS=localhost:9092
export LAGO_KAFKA_ACTIVITY_LOGS_TOPIC=activity_logs
export LAGO_KAFKA_API_LOGS_TOPIC=api_logs
export LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC=events_charged_in_advance
export LAGO_KAFKA_SECURITY_LOGS_TOPIC=security_logs
export STRIPE_API_VERSION=2020-08-27
export ANNOTATERB_SKIP_ON_DB_TASKS=1
export LANG=C.UTF-8 LC_ALL=C.UTF-8
EOF
}

step_ruby() {
  if [ -x "$RUBY_PREFIX/bin/ruby" ] && "$RUBY_PREFIX/bin/ruby" -e 'exit(RUBY_VERSION == "4.0.6" ? 0 : 1)'; then
    log "ruby 4.0.6 present: $RUBY_PREFIX"; return
  fi
  if [ ! -x "$MAMBA" ]; then
    log "downloading micromamba 2.9.0 (conda-forge static binary)"
    mkdir -p "$C/tools/micromamba-2.9.0"
    curl -sSfL -o "$C/tools/micromamba-2.9.0/micromamba.tar.bz2" \
      https://conda.anaconda.org/conda-forge/linux-64/micromamba-2.9.0-0.tar.bz2
    tar -xjf "$C/tools/micromamba-2.9.0/micromamba.tar.bz2" -C "$C/tools/micromamba-2.9.0" bin/micromamba
  fi
  log "creating conda env ruby=4.0.6 libpq=16 + compilers (~1 min, ~1.5 GB)"
  MAMBA_ROOT_PREFIX=$C/micromamba-root "$MAMBA" create -y -p "$RUBY_PREFIX" -c conda-forge --override-channels \
    --ssl-verify "$CA" ruby=4.0.6 libpq=16 pkg-config c-compiler cxx-compiler make libclang >&2
  "$RUBY_PREFIX/bin/ruby" -v >&2
}

step_copy() {
  [ -d "$API_RO" ] || die "pinned checkout missing: $API_RO (research-methodology/scripts/pinned-checkout.sh api)"
  if [ ! -d "$APP" ]; then log "copying pinned checkout -> $APP"; cp -a "$API_RO" "$APP"; fi
}

step_gems() {
  base_env
  mkdir -p "$STATE"
  (
    flock 9
    cd "$APP"
    bundle config set --local path vendor/bundle >/dev/null
    bundle config set --local without 'development sidekiq-pro' >/dev/null
    bundle config set --local frozen true >/dev/null
    bundle config set --local jobs 4 >/dev/null
    if bundle check >/dev/null 2>&1; then log "gems already installed"; exit 0; fi
    command -v cargo >/dev/null || die "cargo not found (lago-expression is a Rust extension)"
    ls "$LIBCLANG_PATH"/clang/*/include/stddef.h >/dev/null 2>&1 ||
      log "WARN: no clang resource headers under $LIBCLANG_PATH/clang/*/include; bindgen may fail (G3)"
    log "bundle install (~2 min; lago-expression compiles Rust)"
    HTTP_PROXY=${HTTPS_PROXY:-${HTTP_PROXY:-}} bundle install >&2
  ) 9>"$STATE/bundle.lock"
}

step_keys() {
  mkdir -p "$APP/config/keys"
  if [ ! -f "$APP/config/keys/private.pem" ]; then
    openssl genpkey -algorithm RSA -out "$APP/config/keys/private.pem" 2>/dev/null
    openssl rsa -pubout -in "$APP/config/keys/private.pem" -out "$APP/config/keys/public.pem" 2>/dev/null
  fi
}

step_redis() {
  mkdir -p "$STATE/redis"
  if redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then log "redis up on :$REDIS_PORT"; return; fi
  redis-server --port "$REDIS_PORT" --bind 127.0.0.1 --daemonize yes --dir "$STATE/redis" \
    --pidfile "$STATE/redis/redis-$REDIS_PORT.pid" --logfile "$STATE/redis/redis-$REDIS_PORT.log" --save '' --appendonly no
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1 && return; sleep 0.3; done
  die "redis did not start on :$REDIS_PORT"
}

expected_versions() { grep -c "^('[0-9]\{14\}')" "$API_RO/db/structure.sql"; }
db_versions() { psql "$PGBASE/$1" -Atc "select count(*) from schema_migrations" 2>/dev/null || echo 0; }

step_db() { # $1 = --reset: drop and recreate even when the migration count is current
  pg_isready -h localhost -p 5432 >/dev/null 2>&1 || { log "starting postgres"; pg_ctlcluster 16 main start; }
  local want; want=$(expected_versions)
  if [ "${1:-}" != --reset ] && [ "$(db_versions "$DB")" = "$want" ]; then log "db $DB has $want migrations (ok)"; return; fi
  log "loading structure.sql into $DB (minus the pg_partman extension line)"
  psql "$PGURL_ADMIN" -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB OWNER lago" \
    -c "COMMENT ON DATABASE $DB IS 'lago-skills reimplementation-kit oracle'"
  mkdir -p "$STATE"
  local f; f=$(mktemp "$STATE/structure.nopartman.XXXXXX.sql")
  grep -v '^CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;$' "$API_RO/db/structure.sql" > "$f"
  psql "$PGBASE/$DB" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null
  rm -f "$f"
  psql "$PGBASE/$DB" -q -c "INSERT INTO ar_internal_metadata (key,value,created_at,updated_at)
    VALUES ('environment','test',now(),now()) ON CONFLICT (key) DO UPDATE SET value='test'"
}

clone_db() { # $1 = target db name, cloned from $DB (template; needs no open connection to $DB)
  [ "$(db_versions "$1")" = "$(expected_versions)" ] && return
  psql "$PGURL_ADMIN" -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $1" \
    -c "CREATE DATABASE $1 TEMPLATE $DB OWNER lago" -c "COMMENT ON DATABASE $1 IS 'lago-skills reimplementation-kit oracle'"
}

ch_up() { curl -s --max-time 2 http://127.0.0.1:8123/ping 2>/dev/null | grep -q Ok; }

cmd_clickhouse() {
  local bin=${ORACLE_CH_BIN:-${K7_CH_BIN:-$(ls -d "$C"/clickhouse/*/clickhouse 2>/dev/null | sort -V | tail -1)}}
  [ -x "$bin" ] || die "no ClickHouse binary; run diagnostics-and-tooling/scripts/ch-local.sh --path first"
  mkdir -p "$STATE"
  exec 8>"$STATE/ch.lock"; flock 8
  local d=$STATE/ch
  if ! ch_up; then
    mkdir -p "$d"/{data,tmp,user_files,access,format_schemas,log}
    cat > "$d/config.xml" <<EOF
<clickhouse>
  <logger><level>warning</level><log>$d/log/server.log</log><errorlog>$d/log/server.err.log</errorlog><size>100M</size><count>2</count></logger>
  <listen_host>127.0.0.1</listen_host><http_port>8123</http_port><tcp_port>9000</tcp_port>
  <path>$d/data/</path><tmp_path>$d/tmp/</tmp_path><user_files_path>$d/user_files/</user_files_path>
  <format_schema_path>$d/format_schemas/</format_schema_path>
  <mark_cache_size>268435456</mark_cache_size><max_server_memory_usage_to_ram_ratio>0.3</max_server_memory_usage_to_ram_ratio>
  <user_directories><users_xml><path>$d/users.xml</path></users_xml><local_directory><path>$d/access/</path></local_directory></user_directories>
  <default_profile>default</default_profile><default_database>default</default_database><mlock_executable>false</mlock_executable>
</clickhouse>
EOF
    cat > "$d/users.xml" <<'EOF'
<clickhouse>
  <profiles><default/></profiles><quotas><default/></quotas>
  <users><default><password>password</password><networks><ip>127.0.0.1</ip><ip>::1</ip></networks>
    <profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
</clickhouse>
EOF
    log "starting ClickHouse $("$bin" --version 2>/dev/null | head -1)"
    (cd "$d" && nohup "$bin" server --config-file="$d/config.xml" --pid-file="$d/ch.pid" > "$d/log/stdout.log" 2>&1 &)
    local i; for i in $(seq 1 60); do ch_up && break; sleep 1; done
    ch_up || die "ClickHouse did not start; see $d/log/"
  fi
  local n
  n=$(curl -s 'http://127.0.0.1:8123/?user=default&password=password' --data "select count() from system.tables where database='default' and name='events_enriched'")
  if [ "$n" != "1" ]; then
    log "rails db:migrate:clickhouse"
    ( eval "$(test_env_lines)"; export LAGO_CLICKHOUSE_MIGRATIONS_ENABLED=true; cd "$APP" && bundle exec rails db:migrate:clickhouse >&2 )
  fi
  log "ClickHouse ready on :8123 ($(curl -s 'http://127.0.0.1:8123/?user=default&password=password' --data "select count() from system.tables where database='default'") tables in default)"
}

cmd_setup() {
  local t0; t0=$(date +%s)
  step_ruby; step_copy; step_gems; step_keys; step_redis; step_db
  log "setup done in $(( $(date +%s) - t0 ))s (db $DB)"
}

list_files() { # $1 = mode (ch|chw|noch), rest = paths relative to $APP (files may carry an rspec location suffix)
  local mode=$1; shift
  local a base suffix f kind
  ( cd "$APP" && for a in "$@"; do
      base=$a suffix=""
      if [[ $a =~ $LOC_RE ]]; then base=${BASH_REMATCH[1]}; suffix=${BASH_REMATCH[2]}; fi
      { find "$base" -name '*_spec.rb' || true; } | while read -r f; do
        if grep -qE "$CH_RE" "$f"; then kind=ch; elif grep -qE "$CHW_RE" "$f"; then kind=chw; else kind=noch; fi
        if [ "$kind" = "$mode" ]; then echo "$f$suffix"; fi
      done
    done | sort -u )
}

cmd_run() {
  local jobs=1 reqs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -j) jobs=$2; shift 2 ;;
      -r) [ -f "$2" ] || die "require file not found: $2"; reqs+=(-r "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
      --) shift; break ;;
      -*) echo "unknown option $1" >&2; exit 1 ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || { echo "usage: run [-j N] [-r FILE]... <spec paths...>" >&2; exit 1; }
  case "$jobs" in ''|*[!0-9]*|0) die "-j needs a positive integer" ;; esac
  step_redis
  [ "$(db_versions "$DB")" = "$(expected_versions)" ] || die "database $DB missing or stale: run '$0 setup' (or '$0 db') first"
  local with_ch=0
  if [ "${ORACLE_CLICKHOUSE:-${K7_CLICKHOUSE:-1}}" != 0 ] && ch_up; then with_ch=1; fi
  local chf=() chw=() other=()
  mapfile -t other < <(list_files noch "$@")
  mapfile -t chw < <(list_files chw "$@")
  mapfile -t chf < <(list_files ch "$@")
  if [ "$with_ch" = 0 ] && [ ${#chf[@]} -gt 0 ]; then
    log "ClickHouse not running: dropping ${#chf[@]} ClickHouse-tagged file(s) (run '$0 clickhouse' to include them)"
    chf=()
  fi
  if [ "$with_ch" = 1 ]; then chf+=("${chw[@]}"); else other+=("${chw[@]}"); fi
  [ $(( ${#chf[@]} + ${#other[@]} )) -gt 0 ] || die "no runnable spec files"
  mkdir -p "$STATE/runs"
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)-$DB
  log "$(( ${#chf[@]} + ${#other[@]} )) files (${#chf[@]} ClickHouse), $jobs job(s), db $DB; logs: $STATE/runs/$stamp-*"
  local i k pids=()
  for ((i = 1; i <= jobs; i++)); do
    local dbn=$DB chunk=() lock=()
    [ "$i" -gt 1 ] && dbn=${DB}_$i && clone_db "$dbn"
    if [ "$i" = 1 ] && [ ${#chf[@]} -gt 0 ]; then chunk+=("${chf[@]}"); lock=(flock "$STATE/ch.lock"); fi
    for ((k = i - 1; k < ${#other[@]}; k += jobs)); do chunk+=("${other[$k]}"); done
    [ ${#chunk[@]} -gt 0 ] || continue
    (
      eval "$(test_env_lines)"
      export DATABASE_URL=$PGBASE/$dbn
      cd "$APP"
      "${lock[@]}" bundle exec rspec "${reqs[@]}" "${chunk[@]}" --format progress --format json \
        --out "$STATE/runs/$stamp-$i.json" > "$STATE/runs/$stamp-$i.txt" 2>&1
    ) &
    pids+=($!)
  done
  local rc=0 p; for p in "${pids[@]}"; do wait "$p" || rc=1; done
  "$RUBY_PREFIX/bin/ruby" -rjson -e '
    tot = Hash.new(0); fails = []
    ARGV.each do |f|
      next unless File.exist?(f) && File.size(f) > 0
      d = JSON.parse(File.read(f, encoding: "UTF-8")); s = d["summary"]
      %w[example_count failure_count pending_count errors_outside_of_examples_count].each { |k| tot[k] += s[k] }
      tot["duration_max_s"] = [tot["duration_max_s"], s["duration"].round(1)].max
      d["examples"].each { |e| fails << "#{e["file_path"]}:#{e["line_number"]}" if e["status"] == "failed" }
    end
    puts tot.to_h.to_json; fails.each { |x| puts "FAILED #{x}" }' "$STATE"/runs/"$stamp"-*.json
  return $rc
}

cmd_adapter() {
  [ -x "$RUBY_PREFIX/bin/ruby" ] || die "oracle toolchain missing: run '$0 setup' first"
  [ "$(db_versions "$DB")" = "$(expected_versions)" ] || die "database $DB missing or stale: run '$0 setup' (or '$0 db') first"
  eval "$(test_env_lines)"
  export ORACLE_OPS_DIR=$OPS_DIR ORACLE_PIN=$PIN
  cd "$APP"
  exec bundle exec rails runner "$HERE/oracle-adapter/oracle_adapter.rb"
}

cmd_status() {
  echo "pin:        $PIN"
  echo "ruby:       $("$RUBY_PREFIX/bin/ruby" -v 2>/dev/null || echo missing)"
  echo "copy:       $([ -d "$APP" ] && echo "$APP" || echo missing)"
  echo "gems:       $( (base_env; cd "$APP" 2>/dev/null && bundle check 2>/dev/null | tail -1) || echo missing)"
  echo "redis:      $(redis-cli -p "$REDIS_PORT" ping 2>/dev/null || echo down) (:$REDIS_PORT)"
  echo "db:         $DB migrations=$(db_versions "$DB") want=$(expected_versions)"
  echo "clickhouse: $(ch_up && echo up || echo down) (:8123)"
  echo "ops dir:    $OPS_DIR ($(ls "$OPS_DIR"/*.rb 2>/dev/null | wc -l) module(s))"
}

cmd_stop() {
  local f
  for f in "$STATE"/redis/redis-*.pid "$STATE/redis/redis.pid"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null && log "redis stopped ($f)"
  done
  [ -f "$STATE/ch/ch.pid" ] && kill "$(cat "$STATE/ch/ch.pid")" 2>/dev/null && log "clickhouse stopped"
  true
}

case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  db) shift; case "${1:-}" in ""|--reset) step_db "${1:-}" ;; *) echo "usage: db [--reset]" >&2; exit 1 ;; esac ;;
  clickhouse) shift; cmd_clickhouse ;;
  run) shift; cmd_run "$@" ;;
  adapter) shift; cmd_adapter ;;
  env) test_env_lines ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  -h|--help|help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; exit 0 ;;
  *) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0" >&2; exit 1 ;;
esac
