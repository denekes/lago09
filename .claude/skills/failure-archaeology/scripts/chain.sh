#!/usr/bin/env bash
# chain.sh — reconstruct or replay a fix-after-fix chain from the FULL history (read-only).
#
# Usage:
#   chain.sh <path> [<ERE>] [--show]   commits touching <path> (rename-aware: events-processor/...
#                                      also searches events_processor/...); with <ERE>, only commits
#                                      whose diff adds/removes a line matching it (git log -G);
#                                      --show prints those matching +/- lines under each commit
#   chain.sh --follow <file> [<ERE>]   same, following renames/moves of ONE file (git log --follow)
#   chain.sh --func <name> <file>      history of one Go function body (git log -L :<name>:<file>)
#   chain.sh --list                    the curated chains (ID, title, status)
#   chain.sh --named <ID>              replay a curated chain: each step resolved in the history clone
#                                      (date, author, subject) plus what that step did
#   chain.sh --verify                  resolve every step of every curated chain; exit 1 if any is missing
#   chain.sh --for <path>              path -> chain lookup: curated chains whose steps touched <path>
#                                      (file or directory, rename-aware; "origin:" steps ignored), then the
#                                      last 10 commits on <path>. Run this BEFORE editing a file.
# Examples (from repo root):
#   .claude/skills/failure-archaeology/scripts/chain.sh --named A
#   .claude/skills/failure-archaeology/scripts/chain.sh events-processor/config/kafka/consumer.go \
#       'findMaxCommitableRecord|commitableRecords|CommitRecords|^[[:space:]]+return$'
#   .claude/skills/failure-archaeology/scripts/chain.sh --func findMaxCommitableRecord events-processor/config/kafka/consumer.go
# Curated chain IDs: A..N (events-processor), X1..X13 (infra/release/dev env); details in
# reference/chains.md. Output is oldest first.
# Env: LAGO_HISTORY=<path> skips history-setup.sh.
# Exit: 0 ok; 1 --verify found a missing step / unknown chain ID; 2 usage; 3 history clone unavailable.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; }

# ---- curated chains: "ID|sha|what this step did" ; "#ID|title|status" opens a chain ----------
chains() { cat <<'EOF'
#A|Kafka commit path (ING-15 segfault)|settled; residual skip-past semantics (OD-2)
A|4100da0|origin: consume() commits the last record of every batch; no retry semantics
A|cec0eb2|Retryable/12 h window + findMaxCommitableRecord; stray `return` exits consume() -> partition goroutine dies, poll() blocks on its unbuffered channel (inferred)
A|656c829|unparseable records counted as processed (committed, Sentry only, no DLQ)
A|600e195|extract processRecordsAndCommit: `return` now only skips the commit; ALSO makes poll() loop forever after client close
A|b604769|hotfix 3 days later: pollRecords returns bool so poll() exits on client close
A|b6d3616|graceful shutdown; removes the `return` -> CommitRecords([nil]) when the first record is unprocessed
A|9acd83e|(record, ok) + skip commit when no commitable prefix: "segfaulting the pod inside franz-go" (ING-15)
#B|SELECT * vs pgx cached plans (SQLSTATE 0A000)|settled for subscriptions; RESIDUAL billable_metrics
B|4100da0|origin: subscription lookup joins customers (explicit column list, pinned); FetchBillableMetric is gorm First = SELECT * (pinned) from day one
B|bd92069|drop customers join for DB load; gorm now emits SELECT * (test re-pinned to SELECT *)
B|9acd83e|subscriptions: column list from schema.Parse (ING-15, same PR as chain A)
B|8ceca4b|deleted-BM fix restores the BM test file fff5858 deleted; it still pins SELECT * FROM "billable_metrics"
B|3ac94a2|same column-pinning fix for the flat_filters view (ING-143)
B|d9c32b6|flat_filters removed; FetchBillableMetric still gorm First = SELECT * (residual)
#C|Soft-delete scope lost in a refactor|settled; class residual (no lint/guard)
C|4100da0|origin: models use gorm.DeletedAt -> gorm adds deleted_at IS NULL implicitly
C|fff5858|memory-cache PR swaps DeletedAt to utils.NullTime: implicit scope gone; 101 lines of BM tests deleted
C|8ceca4b|explicit deleted_at IS NULL; tests restored (18 days later)
#D|flat_filters per-event resolution saga|removed
D|3a6ed00|flat_filters view introduced to compute Rails charge-usage cache keys
D|f1d369a|pre-aggregation: per-charge fan-out with charge + filter ids
D|26e7c7c|grouped_by from pricing_group_keys
D|d7ee4c2|pay-in-advance derived from flat filters; models/charges.go deleted
D|3dae52f|events_enriched_expanded producer; topic env made mandatory (panic if unset)
D|36b1e23|fix same day: nil FlatFilter when no charge matched
D|0c46c8a|fix next day: grouped_by map nil / shared across fan-out copies
D|45b216d|fix flaky test (map iteration order in fan-out)
D|75b9cbc|pre-aggregation flow enabled for all events with a charge
D|2cf3864|target_wallet_code enrichment
D|2fec4db|fix: ToDefaultFilter dropped pricing group keys
D|6048999|reprocess pipeline (expanded events only)
D|9ef876a|fix: flat_filters query lacked organization_id (ING-123)
D|3ac94a2|fix: SELECT * on the view broke cached plans (ING-143)
D|0b56915|fix: Go chose a different filter than Rails on ties (ING-543)
D|d9c32b6|REMOVED: "the main database load coming from the service"; 2,610 lines deleted
#E|Pay-in-advance detection, full circle|settled
E|4100da0|origin: AnyInAdvanceCharge on the charges table
E|d7ee4c2|moved onto flat_filters (PayInAdvance per filter); charges model deleted
E|36b1e23|nil-pointer panic when no charge matched
E|d9c32b6|back to the charges table: HasPayInAdvanceCharge (Rails PostProcessService parity)
#F|Go-side expiry of Rails charge-usage cache keys|removed; residual dead code
F|3a6ed00|Go DELs Rails cache keys it computes itself
F|8d61fa7|next day: cache Redis TLS forced on in prod -> connection failed
F|4cd30f2|DEL ran before ClickHouse ingestion -> EXPIRE 5 s instead
F|3cd78f1|dev: EP on Redis DB 0, API on DB 3 -> cache never expired in dev (4.5 months)
F|42615c9|EXPIRE 15 s
F|fb6401d|EXPIRE 10 s
F|0b56915|wrong key expired: filter tie-break differed from Rails (ING-543)
F|02a4bc8|per-call ctx for ExpireKey
F|2fd8e8b|REMOVED: Go stops expiring; Rails lazy validation (lazy_charge_usage_cache)
#G|Subscription refresh flag (Redis ZSET contract with Rails)|settled; cross-repo contract
G|7421650|SADD subscription_refreshed; Redis mandatory; env typo LLAGO_REDIS_STORE_PASSWORD
G|69ec50d|same day: typo fixed, timeouts, TLS when ENV=production
G|fa5b45f|SubscriptionRefreshService extracted
G|42615c9|ZADD subscription_refreshed_v2, member org:sub|bucket, 15 s bucket
G|fb6401d|10 s bucket (Rails SUBSCRIPTION_BUCKET_DURATION = 10)
G|b4ad153|recurring BM: fall back to the subscription active now (backdated events)
G|02a4bc8|per-call ctx (no more context canceled on SIGTERM)
#H|Redis TLS configuration|settled; residual InsecureSkipVerify
H|69ec50d|TLS iff ENV=production, InsecureSkipVerify
H|3a6ed00|cache store TLS configured after construction
H|8d61fa7|cache store TLS off
H|a918f60|explicit LAGO_REDIS_STORE_TLS / LAGO_REDIS_CACHE_TLS; ENV=production kept as legacy fallback
#I|Timestamp parsing|settled; residual precision/UTC gaps
I|4100da0|origin: numeric timestamps only
I|cec0eb2|CustomTime for ingested_at
I|d7d76be|ingested_at as unix-timestamp string accepted
I|76c1b3b|RFC3339 timestamp accepted (was DLQ, non-retryable)
#J|Concurrency, shutdown and context scoping|settled
J|4100da0|origin: fire-and-forget `go produce` + WaitGroup
J|a15bd3b|errgroup: produce awaited before the record counts as processed
J|b6d3616|signals + cancelable root ctx (stores captured it -> canceled on SIGTERM)
J|02a4bc8|ctx passed per call; batches keep context.Background()
#K|Tracing provider|settled
K|222691f|OTel gated on endpoint instead of ENV=production
K|475761d|provider abstraction, dd-trace-go v1 (go.mod +235/-8 lines)
K|a9c9eb5|kafka loggers through provider; TODO(datadog)
K|1f2d36e|next day: dd-trace-go v2 + Kafka hooks
#L|Toolchain and lago-expression pins|settled; rule enforced by review only
L|07d1d4d|unpinned lago-expression clone broke tests -> pin v0.1.4 (Rust 1.85 in dev)
L|d589940|air@latest needed Go 1.25 -> pin air/dlv
L|5077151|lago-expression v0.2.0 in 3 files
L|e8bbd60|same day: prod build needs rust:1.85 (was 1.82)
L|d4e3665|6 days later: git clone --tags (cached clone missed the tag; inferred)
L|932c06c|dependabot otel/sdk bump raises go.mod to `go 1.25.0`
L|50015b0|50 min later: CI and Dockerfiles moved to Go 1.25
#M|Env-var contract churn in events-processor|settled; residual stale README
M|f277b44|MAX_CONNEXIONS (typo) env added; parse error sets 0
M|7421650|silently renamed to MAX_CONNECTIONS; LLAGO_ typo added
M|69ec50d|LLAGO_ typo fixed
M|3dae52f|LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC made mandatory for everyone
M|27169be|LAGO_KAFKA_TLS=1 was ignored (== "true") -> GetEnvAsBool
M|f6852c0|3.7 months later: dev compose finally creates that topic
M|d9c32b6|topic and env removed
#N|Property values stringified with %v|OPEN (event-accounting-campaign W2; OD-3)
N|4100da0|origin: value = fmt.Sprintf("%v", properties[field]): nil -> "<nil>", 1000000 -> "1e+06"
N|26e7c7c|grouped_by built with the same %v
N|3dae52f|count aggregation value becomes "1"; every other type still %v
N|2fec4db|fix: nil grouped_by property -> "" (the value path was NOT fixed)
N|d9c32b6|grouped_by removed; value %v remains at enrichment_service.go:114
#X1|All-in-one image breaks on release day|each break settled; CLASS RESIDUAL
X1|52ab3b3|single image + release workflow created
X1|023bfe1|6 min later: wrong needs: job id
X1|c91af2b|13 min later: checkout without submodules
X1|e07e182|Ruby 3.3.6 -> 3.4.3 to match lago-api
X1|d0099a9|Ruby 3.4 needs libyaml-dev
X1|9eb8c3b|packages.redis.io `redis` pkg -> Debian redis-server; docker/redis.conf orphaned
X1|92b1af2|runner.sh must generate LAGO_ENCRYPTION_* keys
X1|b6b98c8|base rolled to Debian trixie: postgresql-15 / software-properties-common gone (inferred)
X1|18b26d0|v1.35.0: pnpm@latest TTY abort; prune removed, .dockerignore added
X1|c6abc1e|v1.37.0 image 2 days late: self-hosted runner labels -> ubuntu-latest
X1|fd77a74|signup seed needs roles:seed_predefined first
X1|57508c2|Ruby 4.0.2 + Bundler 4.0.4 (latent break: --without removed)
X1|558814a|v1.45.0: bundle config set without (20 min after the bump)
X1|ba292b6|v1.53.0 bump
X1|b267320|+33 min: Node 20 -> 24
X1|f719ef1|+49 min: Ruby 4.0.2 -> 4.0.6
#X2|2022 deploy-preview workflows iterated on main|removed
X2|4aaa93b|deploy-preview.yml added
X2|f097644|first of ~40 follow-ups the next days (indentation, typos, helm, redis)
X2|0d4d18f|last helm/redis fix
X2|42d40cd|workflows deleted: "remove deployments from public repo"
#X3|deploy/deploy.sh installer|function-order bug settled; OTHER BUGS RESIDUAL
X3|8a6ce39|installer added (bare emoji line executed as a command)
X3|cd9f0fa|production profile: check_domain_dns called before it is defined
X3|d54c463|local env file download removed
X3|2453945|15.5 months later: function moved, $pid quoted, echo added (#762)
#X4|Dev compose startup and init|settled for fixed edges; residual list-form depends_on
X4|2747b04|lago_test init script mounted from a wrong path (never ran)
X4|c80a7b5|random dev start failures: health conditions added
X4|5477e39|next day: rpk topic create made idempotent
X4|e5392e9|25 months later: init-script path fixed, unused bootstrap.sh removed
X4|fc70e75|same day: events-processor dev depends_on conditions + air send_interrupt
#X5|One env source of truth for dev|settled
X5|688e4e7|raw topic env added per service (events-raw)
X5|0ca6cdf|"Fix dev events_raw topic" sets api-worker to events_raw: services now disagree
X5|16c8b68|env moved to one file (events-raw everywhere) [same file carried a real licence value]
X5|84b6eef|file renamed .env.development.default
X5|6dd7e56|licence value removed after 43 days (rotation: OD-9)
X5|3cd78f1|LAGO_REDIS_CACHE_DB aligned (EP 0 vs API 3)
#X6|Submodule pointers moved outside release PRs|instance reverted; CLASS RESIDUAL (15 since 2025)
X6|f145388|pins re-aligned to the release tag
X6|12b8101|Traefik label fix also moved api/front pins
X6|647de3e|same day: pins reverted (#620)
X6|7251947|most recent non-release pin move (ClickHouse upgrade PR)
#X7|Image build workflows rewritten|settled; residual unused inputs
X7|9d40e82|release-processors-image.yml
X7|6ff3a2f|duplicate release-processor-image.yaml
X7|ca4a4fb|3 min later: duplicate removed
X7|b61044f|reusable docker-build-multi-arch.yaml (has push input)
X7|c6abc1e|runner labels -> ubuntu-latest
X7|fdfeb91|refactor: push input removed
X7|4955f79|EP ECR build moved to reusable workflow (arm64)
X7|5070e24|push input re-added (no in-repo caller uses false)
X7|5ee8e98|OIDC role-to-assume (no caller)
#X8|Connectors image pipeline|settled; residual anonymous Docker Hub pulls
X8|6a595fb|pin redpanda connect version
X8|76159bd|repository_dispatch to lago-deploy
X8|2146a18|13 min later: replaced by direct reusable-workflow call
X8|986f29b|429 Too Many Requests: pull docker.io directly
#X9|Redis custom port|root compose settled; deploy/ RESIDUAL
X9|ed6f687|--port ${REDIS_PORT} added, healthcheck still default port
X9|b1e40bd|26 months later: healthcheck uses -p (root compose only)
#X10|Dev services added then removed|removed
X10|22a1685|docker-compose.arm64.yml added
X10|81a0df4|7 months / 38 commits later: removed
X10|0e5937e|Meilisearch dev service
X10|f0bb135|Meilisearch worker
X10|4230f1f|7 weeks later: Meilisearch removed
#X11|Lost work and stray material in history|recovered/removed; blobs stay in history
X11|c8f4133|269 files incl. 133 Zone.Identifier + connector jars committed
X11|1035ffa|18 days later: removed
X11|5308258|PR #800 force-pushed onto main, unrecoverable; rebuilt from lago-deploy#3331
#X12|GraphQL codegen split reverted|settled
X12|15961be|CODEGEN_API split into two endpoints
X12|84013d6|next day: reverted
X12|dfb7b73|CODEGEN_API -> http://api:3000/graphql
#X13|Compose env interpolation/default mistakes (2022-2024)|settled
X13|d07887a|CORS fix adds LAGO_FRONT_URL with a quote instead of `=` in the root compose
X13|9ca67f7|2 days later: line corrected
X13|1a9bea1|HOTFIX: `={VAR:-x}` missing `$` (6 lines)
X13|d2cadc7|LAGO_DISABLE_SEGMENT default removed
X13|f6581fb|empty-var warnings
X13|bfb4d5f|LAGO_DISABLE_SIGNUP default
X13|a791efb|missing LAGO_FROM_EMAIL
X13|bf02b8d|NANGO_SECRET_KEY warning
EOF
}

mode=path; target=""; regex=""; show=0; func=""
case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  --list) mode=list ;;
  --verify) mode=verify ;;
  --for) mode=for; fa_need "$1" "${2:-}"; target="$2" ;;
  --named) mode=named; fa_need "$1" "${2:-}"; target="$2" ;;
  --func) mode=func; fa_need "$1" "${2:-}"; fa_need "--func <name>" "${3:-}"; func="$2"; target="$3" ;;
  --follow) mode=follow; fa_need "$1" "${2:-}"; target="$2"; regex="${3:-}" ;;
  -*) fa_die "unknown option: $1 (see --help)" ;;
  *) target="$1"; regex="${2:-}"; [ "$regex" = "--show" ] && { regex=""; show=1; } ;;
esac
for a in "$@"; do [ "$a" = "--show" ] && show=1; done
[ "$regex" = "--show" ] && regex=""

if [ "$mode" = list ]; then
  chains | awk -F'|' '/^#/ { id = substr($1, 2); printf "%-4s %-55s %s\n", id, $2, $3 }'
  exit 0
fi

fa_init
declare -A title=() steps=()

resolve() {  # $1 = chain id; prints resolved steps; returns 1 if any sha missing
  local id="$1" missing=0 sha role line found=0
  while IFS='|' read -r cid sha role; do
    if [ "${cid:0:1}" = "#" ]; then
      if [ "${cid:1}" = "$id" ]; then found=1; printf 'Chain %s: %s  [status: %s]\n' "$id" "$sha" "$role"; fi
      continue
    fi
    [ "$cid" = "$id" ] || continue
    if line="$(G show -s --no-color --date=short --format='%h %ad %an | %s' "$sha" 2>/dev/null)"; then
      printf '  %s\n      -> %s\n' "$line" "$role"
    else
      printf '  %s  MISSING from history clone\n      -> %s\n' "$sha" "$role"; missing=1
    fi
  done < <(chains)
  [ "$found" = 1 ] || { echo "chain.sh: unknown chain ID: $id (try --list)" >&2; return 1; }
  return "$missing"
}

case "$mode" in
named)
  resolve "$target" ;;
for)
  specs=(); while IFS= read -r s; do specs+=("$s"); done < <(fa_expand_path "$target")
  echo "Curated chains whose steps touched ${target} (rename-aware):"
  hits=0
  while IFS='|' read -r cid sha role; do
    if [ "${cid:0:1}" = "#" ]; then title["${cid:1}"]="$sha | $role"; continue; fi
    case "$role" in origin:*) continue ;; esac
    files="$(G show --no-color --name-only --format= "$sha" 2>/dev/null || true)"
    for sp in "${specs[@]}"; do
      if printf '%s\n' "$files" | grep -qxF -e "$sp" || printf '%s\n' "$files" | grep -q "^${sp//./\\.}/"; then
        steps["$cid"]="${steps[$cid]:-} $sha"; hits=1; break
      fi
    done
  done < <(chains)
  if [ "$hits" = 0 ]; then echo "  (none) -- no curated chain; still read the commits below"; fi
  for id in $(chains | awk -F'|' '/^#/ { print substr($1, 2) }'); do
    [ -n "${steps[$id]:-}" ] && printf '  %-4s %s\n       steps:%s\n' "$id" "${title[$id]}" "${steps[$id]}"
  done
  echo "Last 10 commits on ${target}:"
  G log --no-color -n 10 --date=short --format='  %h %ad %an | %s' -- "${specs[@]}" ;;
verify)
  rc=0; total=0
  for id in $(chains | awk -F'|' '/^#/ { print substr($1, 2) }'); do
    n=$(chains | awk -F'|' -v id="$id" '$1 == id' | wc -l | tr -d ' ')
    if resolve "$id" >/dev/null; then echo "OK   $id ($n steps)"; else echo "FAIL $id"; rc=1; fi
    total=$((total + n))
  done
  echo "verified $total steps"; exit "$rc" ;;
func)
  G log --no-color --reverse --date=short --format='%h %ad %an | %s' -s -L ":${func}:${target}" ;;
follow|path)
  # git log --follow ignores --reverse (prints one commit), so follow mode reverses in awk instead
  args=(log --no-color --date=short --format='%x1e%h %ad %an | %s')
  [ "$mode" = follow ] || args+=(--reverse)
  [ -n "$regex" ] && args+=(-E "-G$regex")
  [ "$show" = 1 ] && [ -n "$regex" ] && args+=(-p --unified=0)
  if [ "$mode" = follow ]; then
    args+=(--follow -- "$target")
  else
    specs=(); while IFS= read -r s; do specs+=("$s"); done < <(fa_expand_path "$target")
    args+=(-- "${specs[@]}")
  fi
  G "${args[@]}" | awk -v show="$show" -v re="$regex" -v rev="$([ "$mode" = follow ] && echo 1 || echo 0)" '
    BEGIN { RS = "\036"; FS = "\n"; n = 0 }
    NF == 0 { next }
    {
      out = $1
      if (show) for (i = 2; i <= NF; i++)
        if ($i ~ /^[-+]/ && $i !~ /^(\+\+\+|---) / && substr($i, 2) ~ re) out = out "\n      " $i
      if (rev) rec[++n] = out; else print out
    }
    END { if (rev) for (i = n; i >= 1; i--) print rec[i] }' ;;
esac
