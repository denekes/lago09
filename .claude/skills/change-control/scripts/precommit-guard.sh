#!/usr/bin/env bash
# precommit-guard.sh — refuse the change classes that history shows cost the most:
# accidental api/front gitlink moves (change-control N1), secrets in tracked files (N11),
# drifting toolchain pins (N3), stray binaries/downloads, and dev-compose regressions (N12).
#
# Usage:
#   precommit-guard.sh                     # check the STAGED diff (git diff --cached) - default
#   precommit-guard.sh --range <A>..<B>    # check the tree diff A -> B (e.g. a PR:
#                                          #   --range "$(git merge-base origin/main HEAD)..HEAD")
#   precommit-guard.sh --commit <sha>      # check one commit against its first parent
# Options:
#   --release        this is a release bump PR: api/front gitlink moves are allowed (N1)
#   --allow <RULE>   downgrade one rule id to WARN (repeatable), e.g. --allow G3-expression-go
#   -C <dir>         run against another checkout
#   -q               print FAIL/WARN lines and the summary only
#
# Rules (FAIL unless noted):
#   G1-gitlink         api/front gitlink changed outside --release (12b8101 -> 647de3e)
#   G1-release-shape   (WARN, --release) files other than api, front, docker-compose.yml changed,
#                      or the docker-compose.yml api/front image tags were not bumped together
#   G1-gitmodules      (WARN) .gitmodules changed
#   G2-<kind>          added line looks like a real secret: private key block, AWS key id,
#                      GitHub/Slack token, live Stripe key, non-empty LAGO_LICENSE (16c8b68)
#   G2-assignment      (WARN) secret-named variable assigned a literal that is not a placeholder
#   G3-pins            the lago-expression / Rust / Go pin set disagrees after the change
#                      (runs pin-sync-check.sh on the post-change tree)
#   G3-latest          added "@latest" in a Dockerfile, workflow or shell script (d589940, 18b26d0)
#   G3-latest-image    (WARN) added ":latest" image reference
#   G3-expression-go   go.mod expression-go version changed (no expression-go/v0.2.0 tag exists)
#   G4-file            added file that must never be committed: *:Zone.Identifier, .env,
#                      .env.development, *.pem, *.key, *.so, *.out, event_processors (c8f4133)
#   G4-elf             added compiled ELF binary
#   G4-large           added file > 5 MiB (WARN for 1-5 MiB and for any other binary file)
#   G5-healthy         (WARN) NEW dev-compose edge to an infra service (db redis redis-replica
#                      redpanda clickhouse; override with CC_INFRA_SERVICES) without
#                      condition: service_healthy (c80a7b5)
#   G5-env-dup         (WARN) NEW key in a dev-compose `environment:` that duplicates
#                      .env.development.default (0ca6cdf, 16c8b68, 3cd78f1)
#   G5-topics          (WARN) added `rpk topic create` (not idempotent, 5477e39) or a changed
#                      LAGO_KAFKA_*_TOPIC value (ClickHouse bakes topic names at migrate time: C4)
# Secret values are NEVER printed: findings show file:line and the rule id only.
# Read-only. Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = usage or git error.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
# Resolve symlinks so the script also works when installed as .git/hooks/pre-commit (a symlink).
self="${BASH_SOURCE[0]}"; real="$(readlink -f "$self" 2>/dev/null || true)"; [ -n "$real" ] && self="$real"
here="$(cd "$(dirname "$self")" && pwd)"

mode=staged rangearg="" commit="" release=0 dir="" quiet=0
declare -a allow=()
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) mode=staged; shift ;;
    --range) mode=range; rangearg="${2:?--range needs A..B}"; shift 2 ;;
    --commit) mode=commit; commit="${2:?--commit needs a sha}"; shift 2 ;;
    --release) release=1; shift ;;
    --allow) allow+=("${2:?--allow needs a rule id}"); shift 2 ;;
    -C) dir="${2:?-C needs a directory}"; shift 2 ;;
    -q) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "precommit-guard: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

G=(git -c gc.auto=0 -c core.quotepath=off)
[ -n "$dir" ] && G+=(-C "$dir")
"${G[@]}" rev-parse --git-dir >/dev/null 2>&1 || { echo "precommit-guard: not a git repository: ${dir:-$PWD}" >&2; exit 2; }
EMPTY_TREE=$("${G[@]}" hash-object -t tree /dev/null)

case "$mode" in
  staged)
    base=HEAD; "${G[@]}" rev-parse -q --verify HEAD >/dev/null || base=$EMPTY_TREE
    DIFF=(diff --cached "$base"); post=(--index); label="staged changes" ;;
  range)
    a="${rangearg%%..*}"; b="${rangearg##*..}"
    [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "$rangearg" ] && { echo "precommit-guard: --range must be A..B" >&2; exit 2; }
    for r in "$a" "$b"; do "${G[@]}" rev-parse -q --verify "$r^{commit}" >/dev/null || { echo "precommit-guard: unknown revision $r" >&2; exit 2; }; done
    DIFF=(diff "$a" "$b"); post=(--rev "$b"); label="range $a..$b" ;;
  commit)
    "${G[@]}" rev-parse -q --verify "$commit^{commit}" >/dev/null || { echo "precommit-guard: unknown commit $commit" >&2; exit 2; }
    parent="$commit^"; "${G[@]}" rev-parse -q --verify "$parent" >/dev/null || parent=$EMPTY_TREE
    DIFF=(diff "$parent" "$commit"); post=(--rev "$commit"); label="commit $("${G[@]}" rev-parse --short "$commit")" ;;
esac
# Always see gitlinks, whatever the user's diff.ignoreSubmodules / submodule.<name>.ignore says.
DIFF+=(--ignore-submodules=none --no-ext-diff --no-color --no-renames)

fails=0 warns=0
allowed() { local r; for r in "${allow[@]+"${allow[@]}"}"; do [ "$r" = "$1" ] && return 0; done; return 1; }
report() { # level rule message
  local lvl="$1"
  if [ "$lvl" = FAIL ] && allowed "$2"; then lvl=WARN; fi
  case "$lvl" in FAIL) fails=$((fails+1)) ;; WARN) warns=$((warns+1)) ;; esac
  if [ "$quiet" = 0 ] || { [ "$lvl" != INFO ] && [ "$lvl" != OK ]; }; then printf '%-5s %-18s %s\n' "$lvl" "$2" "$3"; fi
}

blob_of() { # <path> -> blob sha in the post-change tree
  case "$mode" in
    staged) "${G[@]}" ls-files -s -- "$1" | awk '{print $2; exit}' ;;
    range) "${G[@]}" rev-parse -q --verify "$b:$1" 2>/dev/null || true ;;
    commit) "${G[@]}" rev-parse -q --verify "$commit:$1" 2>/dev/null || true ;;
  esac
}
showpost() { # <path> -> content after the change
  case "$mode" in
    staged) "${G[@]}" show ":$1" 2>/dev/null ;;
    range) "${G[@]}" show "$b:$1" 2>/dev/null ;;
    commit) "${G[@]}" show "$commit:$1" 2>/dev/null ;;
  esac
}
showpre() { # <path> -> content before the change
  case "$mode" in
    staged) "${G[@]}" show "$base:$1" 2>/dev/null ;;
    range) "${G[@]}" show "$a:$1" 2>/dev/null ;;
    commit) "${G[@]}" show "$parent:$1" 2>/dev/null ;;
  esac
}

mapfile -t changed < <("${G[@]}" "${DIFF[@]}" --name-status | awk -F'\t' '{print $1"\t"$NF}')
[ "$release" = 1 ] && label="$label, release mode"
[ "$quiet" = 0 ] && echo "INFO  precommit-guard on $label: ${#changed[@]} path(s) changed"
if [ "${#changed[@]}" -eq 0 ]; then echo "SUMMARY precommit-guard: 0 FAIL, 0 WARN (nothing to check)"; exit 0; fi
declare -A status=()
for l in "${changed[@]}"; do status["${l#*$'\t'}"]="${l%%$'\t'*}"; done
touched() { [ -n "${status[$1]+x}" ]; }

# ---- G1 gitlinks (N1) ----------------------------------------------------------------
gitlinks="$("${G[@]}" "${DIFF[@]}" --raw -- api front | awk '$1 ~ /160000/ || $2 ~ /160000/ {print $3" "$4" "$NF}')"
if [ -n "$gitlinks" ]; then
  while read -r old new path; do
    if [ "$release" = 1 ]; then
      report INFO G1-gitlink "$path gitlink ${old:0:7} -> ${new:0:7} (release mode: allowed; verify it is the vX.Y.Z tag commit, see release-and-images)"
    else
      if [ "$mode" = staged ]; then fix="Unstage: git restore --staged -- $path"
      else fix="Already committed: git restore --source=<base> --staged -- $path, then amend (unpushed) or a new commit (pushed); see change-control section 5"; fi
      report FAIL G1-gitlink "$path gitlink moved ${old:0:7} -> ${new:0:7} outside a release bump. $fix"
    fi
  done <<< "$gitlinks"
else
  report OK G1-gitlink "api/front gitlinks unchanged"
fi
if [ "$release" = 1 ]; then
  [ -z "$gitlinks" ] && report WARN G1-release-shape "release mode but api/front gitlinks did not move: the all-in-one image would bake the previous api/front (01cfbc6, v1.52.1)"
  for p in "${!status[@]}"; do
    case "$p" in api|front|docker-compose.yml) ;; *) report WARN G1-release-shape "$p is outside the release-bump set {api, front, docker-compose.yml}" ;; esac
  done
  tagdiff="$("${G[@]}" "${DIFF[@]}" -U0 -- docker-compose.yml | grep -E '^\+[[:space:]]*image:[[:space:]]*getlago/(api|front):' || true)"
  va="$(printf '%s\n' "$tagdiff" | sed -nE 's#.*getlago/api:([^[:space:]]+).*#\1#p' | head -n1)"
  vf="$(printf '%s\n' "$tagdiff" | sed -nE 's#.*getlago/front:([^[:space:]]+).*#\1#p' | head -n1)"
  if [ -z "$va" ] || [ -z "$vf" ] || [ "$va" != "$vf" ]; then
    report WARN G1-release-shape "docker-compose.yml api/front image tags not bumped together (api='${va:-unchanged}' front='${vf:-unchanged}')"
  else
    report INFO G1-release-shape "docker-compose.yml api/front image tags -> $va"
  fi
fi
touched .gitmodules && report WARN G1-gitmodules ".gitmodules changed: submodule URL/path changes are C5 + C7 (see change-control)"

# ---- added lines (file<TAB>line<TAB>text) ---------------------------------------------
added="$("${G[@]}" "${DIFF[@]}" -U0 | awk '
  /^\+\+\+ / { f=$0; sub(/^\+\+\+ (b\/)?/, "", f); next }
  /^@@ /     { split($3, a, ","); ln=substr(a[1], 2) + 0; next }
  /^\+/      { if (f != "/dev/null") print f "\t" ln "\t" substr($0, 2); ln++; next }
')"

# ---- G2 secrets (N11) ----------------------------------------------------------------
# Patterns are assembled from pieces so this file does not match itself.
dash5='-----'
re_pk="${dash5}BEGIN ([A-Z0-9]+ )*PRIVATE KEY${dash5}"
re_aws='(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)'
re_gh='(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})'
re_slack='xox[abprs]-[A-Za-z0-9]{6,}-[A-Za-z0-9-]{6,}'
re_stripe='(^|[^A-Za-z0-9])[sr]k_live_[A-Za-z0-9]{16,}'
re_lic='^[[:space:]"'"'"'-]*LAGO_LICENSE[[:space:]"'"'"']*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'$#{<*]'
re_assign='(^|[[:space:]"'"'"'{(,-])[A-Z0-9_]*(SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|ENCRYPTION|SALT|LICENSE)[A-Z0-9_]*["'"'"']?[[:space:]]*(=|:[[:space:]])[[:space:]]*["'"'"']?([^[:space:]"'"'"']+)'
re_placeholder='^(\$|<|\*|\{\{|changeme|change-me|your[-_]|example|placeholder|xxx|dummy|fake|test|lago|password|secret|redacted|null|nil|none|true|false|[0-9]{1,5}$|azerty)'
g2=0
if [ -n "$added" ]; then
  while IFS=$'\t' read -r f ln text; do
    kind=""
    if [[ "$text" =~ $re_pk ]]; then kind=private-key
    elif [[ "$text" =~ $re_aws ]]; then kind=aws-key-id
    elif [[ "$text" =~ $re_gh ]]; then kind=github-token
    elif [[ "$text" =~ $re_slack ]]; then kind=slack-token
    elif [[ "$text" =~ $re_stripe ]]; then kind=stripe-live-key
    elif [[ "$text" =~ $re_lic ]]; then kind=lago-license
    fi
    if [ -n "$kind" ]; then report FAIL "G2-$kind" "$f:$ln looks like a real secret (value not shown). Remove it; if it was ever pushed, rotate it (change-control N11)"; g2=$((g2+1)); continue; fi
    case "$f" in *_test.go|*/testdata/*|*.md) continue ;; esac
    if [[ "$text" =~ $re_assign ]]; then
      v="${BASH_REMATCH[4]}"; vl="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
      if ! [[ "$vl" =~ $re_placeholder ]] && [ "${#v}" -ge 8 ]; then
        report WARN G2-assignment "$f:$ln assigns a literal to a secret-named variable (value not shown): use a placeholder or \${VAR}"; g2=$((g2+1))
      fi
    fi
  done <<< "$added"
fi
[ "$g2" -eq 0 ] && report OK G2-secrets "no secret-looking added lines"

# ---- G3 pins (N3) ---------------------------------------------------------------------
pinfiles="events-processor/Dockerfile events-processor/Dockerfile.dev events-processor/Dockerfile.staging events-processor/go.mod events-processor/mise.toml .github/workflows/events-processor-tests.yml"
pin_touched=0; for p in $pinfiles; do touched "$p" && pin_touched=1; done
if [ "$pin_touched" = 1 ]; then
  pcargs=("${post[@]}" -q); [ -n "$dir" ] && pcargs+=(-C "$dir")
  rc=0; out="$("$here/pin-sync-check.sh" "${pcargs[@]}" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    report OK G3-pins "pin set consistent after the change ($(printf '%s' "$out" | tail -n1))"
  elif [ "$rc" -eq 1 ]; then
    report FAIL G3-pins "pin set inconsistent after the change:"
    printf '%s\n' "$out" | grep -E '^(FAIL|WARN)' | sed 's/^/        /' || true
  else
    report FAIL G3-pins "pin-sync-check.sh could not run (exit $rc): $(printf '%s' "$out" | tail -n1)"
  fi
fi
g3=0
if [ -n "$added" ]; then
  while IFS=$'\t' read -r f ln text; do
    case "$f" in .claude/skills/change-control/scripts/*) continue ;; esac   # these scripts contain the patterns
    case "$f" in
      *Dockerfile*|*.yml|*.yaml|*.sh)
        if [[ "$text" =~ @latest([^A-Za-z0-9_-]|$) ]] && [[ ! "$text" =~ ^[[:space:]]*# ]]; then
          report FAIL G3-latest "$f:$ln floating '@latest' tool version: pin an exact version (change-control N3)"; g3=$((g3+1))
        elif [[ "$text" =~ (image:|FROM|_IMAGE=)[^#]*:latest([^A-Za-z0-9_.-]|$) ]]; then
          report WARN G3-latest-image "$f:$ln floating ':latest' image: prefer an immutable tag or digest"; g3=$((g3+1))
        fi ;;
    esac
    if [ "$f" = events-processor/go.mod ] && [[ "$text" =~ lago-expression/expression-go ]]; then
      report FAIL G3-expression-go "$f:$ln expression-go version changed: v0.1.4 is intentional (no expression-go/v0.2.0 tag; ABI identical). Override only with owner sign-off: --allow G3-expression-go"; g3=$((g3+1))
    fi
  done <<< "$added"
fi
[ "$g3" -eq 0 ] && [ "$pin_touched" = 0 ] && report OK G3-pins "no pin files touched, no floating versions added"

# ---- G4 stray files and binaries ---------------------------------------------------------
g4=0
numstat="$("${G[@]}" "${DIFF[@]}" --numstat)"
for p in "${!status[@]}"; do
  st="${status[$p]}"; case "$st" in A*|M*|T*) ;; *) continue ;; esac
  case "$p" in api|front) continue ;; esac
  base_name="${p##*/}"
  if [[ "$base_name" == *:Zone.Identifier || "$base_name" == .env || "$base_name" == .env.development || \
        "$base_name" == *.pem || "$base_name" == *.key || "$base_name" == *.so || "$base_name" == *.out || \
        "$base_name" == event_processors ]]; then
    why="stray download, secret or build output"
    case "$base_name" in *:Zone.Identifier) why="Windows download marker (c8f4133 committed 133 of them)" ;; esac
    report FAIL G4-file "$p must never be committed: $why"; g4=$((g4+1)); continue
  fi
  blob="$(blob_of "$p")"; [ -z "$blob" ] && continue
  size="$("${G[@]}" cat-file -s "$blob" 2>/dev/null || echo 0)"
  isbin="$(printf '%s\n' "$numstat" | awk -F'\t' -v p="$p" '$3==p && $1=="-" {print 1; exit}')"
  if [ "$isbin" = 1 ] && [ "$("${G[@]}" cat-file blob "$blob" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
    report FAIL G4-elf "$p is a compiled ELF binary (build outputs go to \$TMPDIR, change-control N10)"; g4=$((g4+1))
  elif [ "$size" -gt 5242880 ]; then
    report FAIL G4-large "$p is $((size/1048576)) MiB (> 5 MiB)"; g4=$((g4+1))
  elif [ "$size" -gt 1048576 ] || [ "$isbin" = 1 ]; then
    report WARN G4-large "$p is a binary or > 1 MiB file ($size bytes): vendored binaries need owner approval and a checksum (security-and-supply-chain)"; g4=$((g4+1))
  fi
done
[ "$g4" -eq 0 ] && report OK G4-files "no stray downloads, keys, env files or binaries added"

# ---- G5 dev compose (N12) --------------------------------------------------------------
if touched docker-compose.dev.yml || touched .env.development.default; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    showpre docker-compose.dev.yml > "$tmp/pre.yml" || true
    showpost docker-compose.dev.yml > "$tmp/post.yml" || true
    showpost .env.development.default > "$tmp/env" || true
    export CC_INFRA_SERVICES="${CC_INFRA_SERVICES:-db redis redis-replica redpanda clickhouse}"
    g5out="$(python3 - "$tmp/pre.yml" "$tmp/post.yml" "$tmp/env" <<'PY'

import os, re, sys, yaml
infra = set(os.environ["CC_INFRA_SERVICES"].split())
def load(p):
    try:
        with open(p) as fh:
            return yaml.safe_load(fh) or {}
    except Exception:
        return {}
envkeys = set()
for line in open(sys.argv[3]):
    m = re.match(r'^([A-Z0-9_]+)=', line)
    if m: envkeys.add(m.group(1))
def analyse(doc):
    edges, dups = set(), set()
    for name, svc in (doc.get("services") or {}).items():
        dep = svc.get("depends_on") or {}
        if isinstance(dep, list):
            dep = {d: {"condition": "service_started"} for d in dep}
        for d, spec in dep.items():
            cond = (spec or {}).get("condition", "service_started")
            if d in infra and cond != "service_healthy":
                edges.add((name, d, cond))
        files = svc.get("env_file") or []
        files = files if isinstance(files, list) else [files]
        paths = [f if isinstance(f, str) else (f or {}).get("path", "") for f in files]
        if any(p.endswith(".env.development.default") for p in paths):
            env = svc.get("environment") or {}
            keys = [e.split("=", 1)[0] for e in env] if isinstance(env, list) else list(env)
            for k in keys:
                if k in envkeys:
                    dups.add((name, k))
    return edges, dups
pre_e, pre_d = analyse(load(sys.argv[1]))
post_e, post_d = analyse(load(sys.argv[2]))
for n, d, c in sorted(post_e - pre_e):
    print(f"WARN\tG5-healthy\tNEW edge {n} -> {d} uses {c}; infra dependencies need condition: service_healthy")
for n, d, c in sorted(post_e & pre_e):
    print(f"INFO\tG5-healthy\tpre-existing edge {n} -> {d} uses {c}")
for n, k in sorted(post_d - pre_d):
    print(f"WARN\tG5-env-dup\tNEW {n}.environment.{k} duplicates .env.development.default (one env source of truth)")
if not (post_e - pre_e) and not (post_d - pre_d):
    print("OK\tG5-compose\tno new unhealthy infra edges or duplicated env keys")
PY
)" || g5out="WARN	G5-compose	compose analysis failed"
    while IFS=$'\t' read -r lvl rule msg; do [ -n "$lvl" ] && report "$lvl" "$rule" "$msg"; done <<< "$g5out"
  else
    report INFO G5-compose "python3 with PyYAML not available: compose edge/env checks skipped"
  fi
  if [ -n "$added" ]; then
    while IFS=$'\t' read -r f ln text; do
      [ "$f" = docker-compose.dev.yml ] && [[ "$text" =~ rpk[[:space:]]+topic[[:space:]]+create ]] && \
        report WARN G5-topics "$f:$ln 'rpk topic create' is not idempotent: add the topic to the redpandacreatetopics command list, which scripts/create-topics.sh creates idempotently (5477e39)"
      [ "$f" = .env.development.default ] && [[ "$text" =~ ^LAGO_KAFKA_[A-Z_]*TOPIC= ]] && \
        report WARN G5-topics "$f:$ln topic name changed: ClickHouse queue tables bake topic names at migrate time and the EP group id embeds the topic (treat as C4)"
    done <<< "$added"
  fi
fi

echo "SUMMARY precommit-guard: $fails FAIL, $warns WARN"
[ "$fails" -eq 0 ]
