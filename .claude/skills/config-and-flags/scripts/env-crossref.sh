#!/usr/bin/env bash
# env-crossref.sh - cross-reference environment variable NAMES across every Lago configuration plane
# and print the gaps (drift) between them. Read-only: it only reads repo files and the pinned
# lago-api / lago-front checkouts (obtained through the research-methodology foundation script).
#
# Usage (from anywhere inside the repo):
#   .claude/skills/config-and-flags/scripts/env-crossref.sh [options]
#
# Options:
#   --api DIR       use this lago-api checkout (default: $API, else pinned-checkout.sh api)
#   --no-api        do not read lago-api (API column empty; gaps G3, G5, G6 skipped)
#   --with-front    also read lago-front .env.sh + vite.config.ts at the pinned SHA (FRT column)
#   --matrix-only   print only the matrix
#   --gaps-only     print only the gap report
#   --filter REGEX  only matrix rows whose NAME matches the (grep -E) REGEX
#   --tsv           machine-readable matrix (tab-separated, header line first)
#   -h | --help     this help
#
# Columns (one row per variable NAME):
#   EP    events-processor Go code:  R = read at runtime, d = declared as a const but never read
#   DEF   .env.development.default:  x = key present, r = key that another key interpolates (${NAME})
#   DEV   docker-compose.dev.yml      } S = set as a container env key (environment:/anchor mapping)
#   ROOT  docker-compose.yml          } i = only used as a ${NAME} interpolation input
#   LOC   deploy/...local.yml         } h = only used by a container-shell shim ($${NAME})
#   LIT   deploy/...light.yml         } a = only inside an x- anchor that is never merged (dead)
#                                     } c = only appears in a commented-out line
#   PRD   deploy/...production.yml    }
#   DEMO  examples/agentic-ai-demo/compose.yml (same letters)
#   RUN   docker/runner.sh (single image): x = default-map key or exported
#   API   number of non-spec lago-api files reading it via ENV[...] / ENV.fetch / ENV.key? / [ -v ]
#   FRT   lago-front start-up env (.env.sh / vite define): x (only with --with-front)
#
# Gap report:
#   G1 events-processor reads missing from .env.development.default
#   G2 events-processor env constants declared but never read (dead)
#   G3 .env.development.default keys with no consumer (EP, lago-api, front, compose interpolation, shim)
#   G4 root docker-compose.yml vs deploy/*.yml backend-variable drift (both directions)
#   G5 LAGO_* names read by lago-api but set in NO wrapper plane (api-only knobs)
#   G6 LAGO_*/SIDEKIQ_* names set in a wrapper plane that no reader consumes
#
# Exit codes: 0 = report printed (gaps are informational, not failures)
#             2 = usage error
#             3 = missing input (not inside the repo, or lago-api checkout unavailable without --no-api)
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

API_DIR="${API:-}"
USE_API=1
WITH_FRONT=0
SHOW_MATRIX=1
SHOW_GAPS=1
FILTER=""
TSV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --api) [ $# -ge 2 ] || { echo "--api needs a directory" >&2; exit 2; }; API_DIR="$2"; shift 2 ;;
    --no-api) USE_API=0; shift ;;
    --with-front) WITH_FRONT=1; shift ;;
    --matrix-only) SHOW_GAPS=0; shift ;;
    --gaps-only) SHOW_MATRIX=0; shift ;;
    --filter) [ $# -ge 2 ] || { echo "--filter needs a regex" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    --tsv) TSV=1; SHOW_GAPS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside the lago repo" >&2; exit 3; }
[ -f "$ROOT/.env.development.default" ] && [ -d "$ROOT/events-processor" ] || { echo "repo root $ROOT does not look like getlago/lago" >&2; exit 3; }
PINNED="$ROOT/.claude/skills/research-methodology/scripts/pinned-checkout.sh"

if [ "$USE_API" = 1 ] && [ -z "$API_DIR" ]; then
  API_DIR="$("$PINNED" api 2>/dev/null)" || { echo "cannot obtain the pinned lago-api checkout; pass --api DIR or --no-api" >&2; exit 3; }
fi
if [ "$USE_API" = 1 ] && [ ! -d "$API_DIR/app" ]; then echo "lago-api checkout not found at '$API_DIR'" >&2; exit 3; fi
FRONT_DIR=""
if [ "$WITH_FRONT" = 1 ]; then
  FRONT_DIR="$("$PINNED" front 2>/dev/null)" || { echo "cannot obtain the pinned lago-front checkout" >&2; exit 3; }
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NAME_RE='[A-Z][A-Z0-9_]*'

# ---- events-processor: literal reads + env* constants (R if referenced again in the same package) ----
EP="$ROOT/events-processor"
{
  grep -rhoE --include='*.go' --exclude='*_test.go' \
    "(os\.Getenv|os\.LookupEnv|GetEnvAsBool|GetEnvAsInt|GetEnvOrDefault)\(\"$NAME_RE\"" "$EP" \
    | sed -E 's/.*\("//; s/"$//; s/$/ R/'
  grep -rnE --include='*.go' --exclude='*_test.go' "^[[:space:]]*env[A-Za-z0-9]*[[:space:]]*=[[:space:]]*\"$NAME_RE\"" "$EP" \
    | sed -E 's#^([^:]+):[0-9]+:[[:space:]]*(env[A-Za-z0-9]*)[[:space:]]*=[[:space:]]*"([^"]+)".*#\1 \2 \3#' \
    | while read -r file ident val; do
        n=$(grep -rhow --include='*.go' --exclude='*_test.go' -e "$ident" "$(dirname "$file")" | wc -l)
        if [ "$n" -ge 2 ]; then echo "$val R"; else echo "$val d"; fi
      done
} | awk '{ if (!($1 in m) || $2 == "R") m[$1] = $2 } END { for (k in m) print k "\t" m[k] }' | sort > "$WORK/EP"

# ---- .env.development.default keys (r = key that another key interpolates, e.g. POSTGRES_USER) ----
grep -oE "\\\$\{$NAME_RE" "$ROOT/.env.development.default" | sed 's/^\${//' | sort -u > "$WORK/DEFREF"
grep -oE "^$NAME_RE=" "$ROOT/.env.development.default" | tr -d '=' | sort -u \
  | awk 'NR == FNR { ref[$1] = 1; next } { print $1 "\t" (($1 in ref) ? "r" : "x") }' "$WORK/DEFREF" - > "$WORK/DEF"

# ---- compose-style files: S / i / h / a / c markers ----
compose_names() { # $1 = file
  awk -v re="$NAME_RE" '
    function add(n, mk) { if (!(n in m) || rank[mk] > rank[m[n]]) m[n] = mk }
    BEGIN { rank["c"] = 1; rank["a"] = 2; rank["h"] = 3; rank["i"] = 4; rank["S"] = 5 }
    # pass 1: which YAML anchors are ever merged/referenced (*name)
    NR == FNR { if ($0 !~ /^[[:space:]]*#/) { l = $0; while (match(l, /\*[A-Za-z0-9_-]+/)) { used[substr(l, RSTART + 1, RLENGTH - 1)] = 1; l = substr(l, RSTART + RLENGTH) } } next }
    {
      line = $0
      if (line ~ /^[^[:space:]#]/) { anchor = ""; if (match(line, /^x-[^:]*:[[:space:]]*&[A-Za-z0-9_-]+/)) { anchor = substr(line, RSTART, RLENGTH); sub(/.*&/, "", anchor) } }
      commented = (line ~ /^[[:space:]]*#/)
      if (commented) { sub(/^[[:space:]]*#[[:space:]]*/, "  ", line) }
      # container env keys: mapping form  KEY: / "KEY":   and list form  - KEY=
      # (in commented lines only the unambiguous forms "KEY": and - KEY= count, so "# TODO: ..." is ignored)
      keyre = commented ? "^[[:space:]]+\"" re "\"[[:space:]]*:([[:space:]]|$)" : "^[[:space:]]+\"?" re "\"?[[:space:]]*:([[:space:]]|$)"
      if (match(line, keyre) || match(line, "^[[:space:]]+-[[:space:]]+\"?" re "=")) {
        s = substr(line, RSTART, RLENGTH); gsub(/^[[:space:]]+(-[[:space:]]+)?"?/, "", s); sub(/"?[[:space:]]*[:=].*$/, "", s)
        add(s, commented ? "c" : ((anchor != "" && !(anchor in used)) ? "a" : "S"))
      }
      # interpolation inputs ${NAME...} (not $${NAME}, which is a literal for the container shell)
      rest = line
      while (match(rest, "\\$+\\{" re)) {
        tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        dollars = tok; sub(/\{.*/, "", dollars); n = tok; sub(/^\$+\{/, "", n)
        if (commented) add(n, "c"); else if (length(dollars) % 2 == 0) add(n, "h"); else add(n, "i")
      }
    }
    END { for (k in m) print k "\t" m[k] }' "$1" "$1" | sort
}
compose_names "$ROOT/docker-compose.dev.yml" > "$WORK/DEV"
compose_names "$ROOT/docker-compose.yml" > "$WORK/ROOT"
compose_names "$ROOT/deploy/docker-compose.local.yml" > "$WORK/LOC"
compose_names "$ROOT/deploy/docker-compose.light.yml" > "$WORK/LIT"
compose_names "$ROOT/deploy/docker-compose.production.yml" > "$WORK/PRD"
compose_names "$ROOT/examples/agentic-ai-demo/compose.yml" > "$WORK/DEMO"

# ---- single image runner.sh: default-map keys and exports ----
{ grep -oE "\[$NAME_RE\]=" "$ROOT/docker/runner.sh" | tr -d '[]='; grep -oE "export $NAME_RE=" "$ROOT/docker/runner.sh" | sed -E 's/export //; s/=$//'; } \
  | sort -u | sed 's/$/\tx/' > "$WORK/RUN"

# ---- lago-api: file count per name (non-spec) ----
: > "$WORK/API"
if [ "$USE_API" = 1 ]; then
  {
    grep -rnoE --include='*.rb' --include='*.yml' --include='*.erb' --include='*.rake' --include='*.ru' \
      "ENV(\[|\.fetch\(|\.key\?\()[\"']$NAME_RE[\"']" "$API_DIR" 2>/dev/null \
      | sed -E "s#^$API_DIR/##; s#:[0-9]+:ENV(\[|\.fetch\(|\.key\?\()[\"']# #; s#[\"']\$##"
    grep -rnoE --include='*.sh' "\[ -v $NAME_RE \]" "$API_DIR/scripts" 2>/dev/null \
      | sed -E "s#^$API_DIR/##; s#:[0-9]+:\[ -v # #; s# \]\$##"
  } | grep -vE '^(spec|\.github)/' | sort -u | awk '{ c[$2]++ } END { for (k in c) print k "\t" c[k] }' | sort > "$WORK/API"
fi

# ---- lago-front (optional) ----
: > "$WORK/FRT"
if [ "$WITH_FRONT" = 1 ]; then
  { grep -oE "\\\$$NAME_RE" "$FRONT_DIR/.env.sh" | tr -d '$'
    grep -oE "env\.$NAME_RE" "$FRONT_DIR/vite.config.ts" | sed 's/^env\.//'; } | sort -u | sed 's/$/\tx/' > "$WORK/FRT"
fi

COLS="EP DEF DEV ROOT LOC LIT PRD DEMO RUN API FRT"
cat "$WORK"/EP "$WORK"/DEF "$WORK"/DEV "$WORK"/ROOT "$WORK"/LOC "$WORK"/LIT "$WORK"/PRD "$WORK"/DEMO "$WORK"/RUN "$WORK"/API "$WORK"/FRT \
  | cut -f1 | sort -u > "$WORK/ALL"

# Join everything into one TSV: NAME then one cell per column ("" when absent).
awk -F'\t' -v cols="$COLS" -v dir="$WORK" '
  BEGIN { nc = split(cols, C, " "); for (i = 1; i <= nc; i++) { f = dir "/" C[i]; while ((getline l < f) > 0) { split(l, p, "\t"); v[C[i], p[1]] = p[2] } } }
  { printf "%s", $1; for (i = 1; i <= nc; i++) printf "\t%s", ((C[i], $1) in v ? v[C[i], $1] : ""); printf "\n" }' "$WORK/ALL" > "$WORK/MATRIX"

if [ "$TSV" = 1 ]; then
  printf 'NAME\t%s\n' "$(echo $COLS | tr ' ' '\t')"
  if [ -n "$FILTER" ]; then awk -F'\t' -v re="$FILTER" '$1 ~ re' "$WORK/MATRIX"; else cat "$WORK/MATRIX"; fi
  exit 0
fi

if [ "$SHOW_MATRIX" = 1 ]; then
  echo "== env-crossref matrix (repo $(git -C "$ROOT" rev-parse --short HEAD); lago-api: ${API_DIR:-not read}) =="
  echo "   EP: R=read d=dead-const | DEF: x=key r=key+interpolated | RUN/FRT: x | compose: S=set i=interp h=shim a=dead-anchor c=commented | API: #files"
  printf '%-52s' NAME; for c in $COLS; do printf '%-5s' "$c"; done; printf '\n'
  awk -F'\t' -v re="$FILTER" 're == "" || $1 ~ re { printf "%-52s", $1; for (i = 2; i <= NF; i++) printf "%-5s", ($i == "" ? "." : $i); printf "\n" }' "$WORK/MATRIX"
  echo "rows: $(if [ -n "$FILTER" ]; then awk -F'\t' -v re="$FILTER" '$1 ~ re' "$WORK/MATRIX" | wc -l; else wc -l < "$WORK/MATRIX"; fi)"
fi

[ "$SHOW_GAPS" = 1 ] || exit 0
# column indexes in MATRIX: 1 NAME, 2 EP, 3 DEF, 4 DEV, 5 ROOT, 6 LOC, 7 LIT, 8 PRD, 9 DEMO, 10 RUN, 11 API, 12 FRT
gap() { # $1 title, $2 awk condition
  local out; out="$(awk -F'\t' "$2 { print \$1 }" "$WORK/MATRIX")"
  local n=0; [ -n "$out" ] && n=$(printf '%s\n' "$out" | wc -l)
  echo; echo "$1: $n"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  /' | paste -sd' ' | fold -s -w 110 | sed 's/^/  /'
  return 0
}
echo; echo "== gaps =="
gap "G1 events-processor reads missing from .env.development.default" '$2 == "R" && $3 == ""'
gap "G2 events-processor env constants declared but never read" '$2 == "d"'
if [ "$USE_API" = 1 ]; then
  gap "G3 .env.development.default keys with no consumer" '$3 == "x" && $2 != "R" && $11 == "" && $12 == "" && $4 != "i" && $4 != "h"'
else
  echo; echo "G3 skipped (--no-api: lago-api consumers unknown)"
fi
gap "G4a set in root docker-compose.yml but missing from >=1 deploy/*.yml" '$5 == "S" && $1 !~ /^(PGDATA|POSTGRES_(USER|PASSWORD|DB|PORT))$/ && ($6 != "S" || $7 != "S" || $8 != "S")'
gap "G4b set in every deploy/*.yml but not in root docker-compose.yml" '$6 == "S" && $7 == "S" && $8 == "S" && $5 != "S"'
if [ "$USE_API" = 1 ]; then
  gap "G5 LAGO_* read by lago-api but set in no wrapper plane" '$1 ~ /^LAGO_/ && $11 != "" && $3 == "" && $4 == "" && $5 == "" && $6 == "" && $7 == "" && $8 == "" && $9 == "" && $10 == ""'
  gap "G6 LAGO_*/SIDEKIQ_* set in a wrapper plane but read by nobody (EP/lago-api$( [ "$WITH_FRONT" = 1 ] && echo /front))" \
    '$1 ~ /^(LAGO_|SIDEKIQ_)/ && $2 != "R" && $11 == "" && $12 == "" && $4 != "h" && ($3 != "" || $4 == "S" || $5 == "S" || $6 == "S" || $7 == "S" || $8 == "S" || $9 == "S" || $10 == "x")'
fi
echo
echo "note: names, not values. Defaults per plane: reference/platform-env.md; read semantics: bool-semantics.sh <VAR>."
