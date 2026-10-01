#!/usr/bin/env bash
# secret-defaults-scan.sh - counts and locations of insecure secret defaults (never values).
#
# Usage (from anywhere inside the repo):
#   secret-defaults-scan.sh                 # tree: placeholders + published ports + redis auth
#   secret-defaults-scan.sh --history       # + full-history scan of env-style files (*.default,
#                                           #   *.example, *.dist, .env*) for secret-ish KEY=value adds
#   secret-defaults-scan.sh --history-wide  # + every path, KEY=value and KEY: value, LITERAL rows only
#   Options: --repo DIR  --history-dir DIR (bare full-history clone; default: history-setup.sh)
#            --verbose (history: also EMPTY/INTERPOLATION/PLACEHOLDER rows)  --fail-on-findings
#
# What it prints (one finding per line, tab-separated):
#   PH    <plane> <file:line> <KEY> <label>     label = id from the PLACEHOLDERS table below
#   PORT  <plane> <file:line> svc=<s> host=<p> ctr=<p> bind=<ALL|LOOPBACK> <what> [SENSITIVE]
#   REDIS <plane> <file:line> svc=<s> requirepass=<NO|CONDITIONAL|YES>
#   HIST  <sha> <file> <KEY> <EMPTY|INTERPOLATION|PLACEHOLDER|LITERAL> <context>
#   SUMMARY ...
# SAFETY (change-control N11): the script never prints text taken from a value position.
#   Tree rows print the KEY name and a label from this script's own table. History rows print the
#   KEY name and a CLASS computed in awk; the value itself is discarded.
# Read-only: no writes to the repo or the history clone (git log/show only).
# Exit codes: 0 scan done; 1 --fail-on-findings and a SELFHOST placeholder, an ALL-interfaces
#   SENSITIVE self-host port, or a LITERAL history row was found; 2 usage; 3 history clone unavailable.
set -euo pipefail

REPO=""; HIST_MODE=""; HDIR=""; VERBOSE=0; FAIL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --history) HIST_MODE="env"; shift ;;
    --history-wide) HIST_MODE="wide"; shift ;;
    --history-dir) HDIR="${2:?}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --fail-on-findings) FAIL=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo; use --repo" >&2; exit 2; }
cd "$REPO"

# label|ERE (labels are the public placeholder ids; the ERE is matched, never echoed)
PLACEHOLDERS='changeme|changeme
your-secret-key-base|your-secret-key-base
your-encryption-key|your-encr(yp|py)tion-
azerty123456|azerty123456
acme-example-email|your_email@example\.com
clickhouse-default-password|<password>default</password>
literal-password|PASSWORD"?[=:][[:space:]]*"?password"?[[:space:]]*$'

plane_of() {
  case "$1" in
    *.md|docs/*) echo DOCS ;;
    docker-compose.dev.yml|.env.development.default|traefik/*|extra/clickhouse/*|extra/debezium_config.json|extra/redis/*|scripts/*) echo DEV ;;
    docker-compose.yml|deploy/*|docker/*|extra/*) echo SELFHOST ;;
    .github/*) echo CI ;;
    examples/*) echo EXAMPLE ;;
    *) echo OTHER ;;
  esac
}

mapfile -t FILES < <(git ls-files -- 'docker-compose*.yml' 'deploy/*.yml' 'deploy/.env.*' '.env.development.default' \
  'docker/runner.sh' 'examples/*' 'extra/*.xml' 'extra/*.json' 'extra/*.sh' 'extra/*.conf' 'extra/**/*.xml' \
  'extra/**/*.conf' 'traefik/*' 'connectors/*.yml' 'scripts/*' '.github/workflows/*' 'README.md' 'deploy/README.md' \
  'docs/*.md' | grep -v '\.jar$' | sort -u)

echo "== 1. Known placeholder secrets in tracked config (KEY + label only) =="
PH_TOTAL=0; PH_SELF=0
declare -A PH_BY_LABEL=()
while IFS='|' read -r label ere; do
  [ -n "$label" ] || continue
  for f in "${FILES[@]}"; do
    while IFS=: read -r ln rest; do
      [ -n "$ln" ] || continue
      key=$(printf '%s\n' "$rest" | awk '{
        s=$0; sub(/^[ \t]*(-[ \t]+)?/,"",s);
        if (s ~ /^<[A-Za-z_]+>/) { t=s; sub(/^</,"",t); sub(/>.*/,"",t); print t "(xml)"; exit }
        gsub(/"/,"",s); k=s; sub(/[=:].*/,"",k); gsub(/[^A-Za-z0-9_.-]/,"",k);
        if (k=="") k="-"; print k }')
      p=$(plane_of "$f")
      printf 'PH\t%s\t%s:%s\t%s\t%s\n' "$p" "$f" "$ln" "$key" "$label"
      PH_TOTAL=$((PH_TOTAL+1)); PH_BY_LABEL[$label]=$(( ${PH_BY_LABEL[$label]:-0} + 1 ))
      [ "$p" = SELFHOST ] && PH_SELF=$((PH_SELF+1))
    done < <(grep -n -E -- "$ere" "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' || true)
  done
done <<< "$PLACEHOLDERS"
for l in "${!PH_BY_LABEL[@]}"; do echo "count label=$l ${PH_BY_LABEL[$l]}"; done | sort

echo
echo "== 2. Published ports (compose ports: entries; defaults resolved) =="
mapfile -t COMPOSE < <(git ls-files -- 'docker-compose*.yml' 'deploy/docker-compose*.yml' 'examples/*/compose.yml' | sort)
PORT_SENS=0; PORT_SENS_SELF=0
for f in "${COMPOSE[@]}"; do
  p=$(plane_of "$f")
  while IFS=$'\t' read -r ln svc entry; do
    [ -n "$ln" ] || continue
    # resolve ${VAR:-default} / ${VAR} -> default (or VAR name)
    res=$(printf '%s' "$entry" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g; s/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/<\1>/g; s/["'\'' ]//g; s#/tcp##; s#/udp##')
    IFS=: read -r a b c <<< "$res"
    if [ -n "${c:-}" ]; then bind="$a"; host="$b"; ctr="$c"; elif [ -n "${b:-}" ]; then bind=""; host="$a"; ctr="$b"; else bind=""; host="(ephemeral)"; ctr="$a"; fi
    case "$bind" in 127.*|localhost|::1) bnd=LOOPBACK ;; *) bnd=ALL ;; esac
    what="other"; sens=""
    case "$ctr" in
      5432) what="postgres"; sens=SENSITIVE ;;
      6379) what="redis"; sens=SENSITIVE ;;
      8080) if [[ "$svc" == traefik* ]]; then what="traefik-dashboard(api.insecure)"; sens=SENSITIVE; else what="http"; fi ;;
      9000) what="clickhouse-native"; sens=SENSITIVE ;;
      8123) what="clickhouse-http"; sens=SENSITIVE ;;
      8083) what="kafka-connect-rest"; sens=SENSITIVE ;;
      9092|19092) what="kafka"; sens=SENSITIVE ;;
      3000) what="api(/sidekiq,/metrics)"; sens=SENSITIVE ;;
      80|443) what="http(s)-entry" ;;
    esac
    [ "$bnd" = LOOPBACK ] && sens=""
    printf 'PORT\t%s\t%s:%s\tsvc=%s\thost=%s\tctr=%s\tbind=%s\t%s\t%s\n' "$p" "$f" "$ln" "$svc" "$host" "$ctr" "$bnd" "$what" "$sens"
    if [ -n "$sens" ]; then PORT_SENS=$((PORT_SENS+1)); [ "$p" = SELFHOST ] && PORT_SENS_SELF=$((PORT_SENS_SELF+1)); fi
  done < <(awk '
    /^services:[ \t]*$/ {insvc=1; next}
    /^[A-Za-z]/ && !/^services:/ {insvc=0}
    insvc && /^  [A-Za-z0-9_.-]+:[ \t]*$/ {svc=$1; sub(/:$/,"",svc); inports=0; next}
    insvc && /^    ports:[ \t]*$/ {inports=1; next}
    inports && /^[ \t]*-[ \t]/ {e=$0; sub(/^[ \t]*-[ \t]*/,"",e); sub(/[ \t]+#.*$/,"",e); print NR "\t" svc "\t" e; next}
    inports && /^[ \t]*#/ {next}
    inports {inports=0}
  ' "$f")
done

echo
echo "== 3. Bundled Redis authentication =="
REDIS_NOAUTH=0
for f in "${COMPOSE[@]}"; do
  p=$(plane_of "$f")
  while IFS=$'\t' read -r ln svc state; do
    [ -n "$ln" ] || continue
    printf 'REDIS\t%s\t%s:%s\tsvc=%s\trequirepass=%s\n' "$p" "$f" "$ln" "$svc" "$state"
    [ "$state" = NO ] && REDIS_NOAUTH=$((REDIS_NOAUTH+1))
  done < <(awk '
    function flush() { if (svc ~ /^redis($|-replica)/ && isredis) print start "\t" svc "\t" (rp=="" ? "NO" : rp) }
    /^services:[ \t]*$/ {insvc=1; next}
    insvc && /^  [A-Za-z0-9_.-]+:[ \t]*$/ {flush(); svc=$1; sub(/:$/,"",svc); start=NR; rp=""; isredis=0; next}
    insvc && /image:.*redis:/ {isredis=1}
    insvc && /<<: \*redis-image/ {isredis=1}
    insvc && /requirepass/ { if ($0 ~ /:\+/) rp="CONDITIONAL"; else rp="YES" }
    END {flush()}
  ' "$f")
done

HIST_LITERAL=0; HIST_ROWS=0; HIST_COMMITS=0
if [ -n "$HIST_MODE" ]; then
  echo
  if [ -z "$HDIR" ]; then
    HS="$REPO/.claude/skills/research-methodology/scripts/history-setup.sh"
    [ -x "$HS" ] || { echo "history-setup.sh not found; pass --history-dir" >&2; exit 3; }
    HDIR=$("$HS") || { echo "history-setup.sh failed" >&2; exit 3; }
  fi
  git -C "$HDIR" rev-parse --verify -q HEAD >/dev/null || { echo "no usable history clone at $HDIR" >&2; exit 3; }
  CLASSIFY='
    function ctx(f) { if (f ~ /^\.github\//) return "ci"; if (f ~ /^examples\//) return "example";
      if (f ~ /\.md$/) return "docs"; if (f ~ /(\.default|\.example|\.dist|(^|\/)\.env[^\/]*)$/) return "env-file"; return "other" }
    substr($0,1,4)=="@@C " {c=substr($0,5); next}
    substr($0,1,4)=="+++ " {f=substr($0,7); next}
    substr($0,1,4)=="--- " {next}
    substr($0,1,1)=="+" {
      l=substr($0,2); sub(/^[ \t]*(-[ \t]+)?(export[ \t]+)?/,"",l)
      if (l !~ /^"?[A-Za-z_][A-Za-z0-9_]*"?[ \t]*[=:]/) next
      if (mode=="env" && l !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      k=l; sub(/[ \t]*[=:].*/,"",k); gsub(/"/,"",k)
      v=l; sub(/^[^=:]*[=:][ \t]*/,"",v); gsub(/["\047 \t\r]/,"",v)
      K=toupper(k)
      if (K !~ /SECRET|PASSWORD|PASSWD|TOKEN|_LICENSE$|^LICENSE$|_KEY$|_KEY_|API_KEY|PRIVATE|SALT|CREDENTIAL/) next
      lv=tolower(v)
      if (v=="") cls="EMPTY"
      else if (substr(v,1,1)=="$" || substr(v,1,1)=="`") cls="INTERPOLATION"
      else if (lv ~ /changeme|your[-_]|example|password|azerty|xxx|placeholder|default|secret|foobar|^test$|^lago$|<|\{\{/) cls="PLACEHOLDER"
      else cls="LITERAL"
      v=""
      if (cls=="LITERAL" || verbose) print "HIST\t" c "\t" f "\t" k "\t" cls "\t" ctx(f)
    }'
  if [ "$HIST_MODE" = env ]; then
    echo "== 4. History: secret-ish KEY=value additions in env-style files (classes only, never values) =="
    HIST_COMMITS=$(git -C "$HDIR" log --format=%h --no-renames HEAD -- '*.default' '*.example' '*.dist' '.env*' '**/.env*' | wc -l)
    OUT=$(git -C "$HDIR" log --format='@@C %h' -p --no-renames --no-ext-diff HEAD -- '*.default' '*.example' '*.dist' '.env*' '**/.env*' \
      | awk -v mode=env -v verbose="$VERBOSE" "$CLASSIFY" | sort | uniq)
  else
    echo "== 4. History (wide): secret-ish KEY=value / KEY: value additions, all paths (LITERAL rows; never values) =="
    HIST_COMMITS=$(git -C "$HDIR" log --format=%h -E -G'(SECRET|PASSWORD|TOKEN|LICENSE|_KEY)[A-Z_]*"?[[:space:]]*[=:]' HEAD -- . ':!*.jar' ':!*go.sum' | wc -l)
    OUT=$(git -C "$HDIR" log --format='@@C %h' -p --no-renames --no-ext-diff -E -G'(SECRET|PASSWORD|TOKEN|LICENSE|_KEY)[A-Z_]*"?[[:space:]]*[=:]' HEAD -- . ':!*.jar' ':!*go.sum' \
      | awk -v mode=wide -v verbose="$VERBOSE" "$CLASSIFY" | sort | uniq)
  fi
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  HIST_ROWS=$(printf '%s' "$OUT" | grep -c . || true)
  HIST_LITERAL=$(printf '%s\n' "$OUT" | awk -F'\t' '$5=="LITERAL"' | grep -c . || true)
  echo "count history_commits_in_scope=$HIST_COMMITS rows=$HIST_ROWS literal=$HIST_LITERAL"
  echo "note: a LITERAL row is a lead, not a verdict. Read the commit yourself; report sha+file+KEY only (N11)."
fi

echo
echo "SUMMARY secret-defaults-scan: placeholders=$PH_TOTAL (selfhost=$PH_SELF) sensitive_ports=$PORT_SENS (selfhost=$PORT_SENS_SELF) redis_noauth=$REDIS_NOAUTH history_literal=${HIST_LITERAL}"
if [ "$FAIL" = 1 ] && { [ "$PH_SELF" -gt 0 ] || [ "$PORT_SENS_SELF" -gt 0 ] || [ "$HIST_LITERAL" -gt 0 ]; }; then exit 1; fi
exit 0
