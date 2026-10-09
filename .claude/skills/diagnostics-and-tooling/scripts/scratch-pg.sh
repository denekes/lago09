#!/usr/bin/env bash
# scratch-pg.sh — throwaway Postgres databases for probes (never touch the `lago` DB).
#
# Usage:
#   scratch-pg.sh create <name> [schema.sql ...]  # (re)create DB <name>, load each file, print its URL on stdout
#   scratch-pg.sh create --lenient <name> [file]  # same, but keep loading past SQL errors and report their count
#                                                 # (for the real lago-api db/structure.sql: pg_partman is absent)
#   scratch-pg.sh drop <name>                     # drop DB <name> (only if this script created it)
#   scratch-pg.sh url <name>                      # print the URL of DB <name>
#   scratch-pg.sh list                            # list databases this script created
#
# <name> must match ^[a-z][a-z0-9_]{0,62}$. Databases are tagged with
#   COMMENT ON DATABASE <name> IS 'lago-skills scratch'
# and `drop` / re-`create` refuse any database without that tag, so a typo can
# never drop `lago` or a real database. `create` on an existing scratch DB
# drops and recreates it (idempotent: same input, same end state).
#
# Admin connection: $DATABASE_URL (default postgres://lago:lago@localhost:5432/lago);
# its role needs CREATEDB (the sandbox `lago` role is SUPERUSER). Scratch URLs
# reuse its user/password/host/port and swap the database name.
#
# Exit codes: 0 ok; 1 usage error; 2 Postgres/psql unavailable or SQL error;
#             3 refused (name invalid, reserved, or DB not created by this script).
set -euo pipefail

TAG='lago-skills scratch'
ADMIN_URL="${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" >&2; exit 1; }
die() { echo "scratch-pg: $2" >&2; exit "$1"; }

command -v psql >/dev/null 2>&1 || die 2 "psql not found (install postgresql-client)"

# Split ADMIN_URL into base (scheme://user:pass@host:port), db and query string.
url_noq="${ADMIN_URL%%\?*}"
query=""; [ "$url_noq" != "$ADMIN_URL" ] && query="?${ADMIN_URL#*\?}"
base="${url_noq%/*}"
admin_db="${url_noq##*/}"

url_for() { printf '%s/%s%s\n' "$base" "$1" "$query"; }
psql_admin() { psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -At "$@"; }

check_name() {
  local n="$1"
  [[ "$n" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || die 3 "invalid name '$n' (want ^[a-z][a-z0-9_]{0,62}\$)"
  case "$n" in
    postgres|template0|template1|"$admin_db") die 3 "refusing reserved database '$n'" ;;
  esac
}

ensure_pg() {
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -q -d "$ADMIN_URL" || die 2 "Postgres not reachable at ${base#*@} (sandbox: pg_ctlcluster 16 main start)"
  fi
}

exists() { [ "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }
is_scratch() { [ "$(psql_admin -c "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = '$1'")" = "$TAG" ]; }

do_drop() {
  local n="$1"
  if exists "$n"; then
    is_scratch "$n" || die 3 "database '$n' exists but is not tagged '$TAG'; not dropping it"
    psql_admin -c "DROP DATABASE \"$n\" WITH (FORCE)" >/dev/null || die 2 "DROP DATABASE $n failed"
    echo "scratch-pg: dropped $n" >&2
  else
    echo "scratch-pg: $n does not exist (nothing to drop)" >&2
  fi
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
  create)
    lenient=0
    if [ "${1:-}" = --lenient ]; then lenient=1; shift; fi
    [ $# -ge 1 ] || usage
    name="$1"; shift
    check_name "$name"; ensure_pg
    for f in "$@"; do [ -r "$f" ] || die 1 "schema file not readable: $f"; done
    if exists "$name"; then do_drop "$name"; fi
    psql_admin -c "CREATE DATABASE \"$name\"" >/dev/null || die 2 "CREATE DATABASE $name failed"
    psql_admin -c "COMMENT ON DATABASE \"$name\" IS '$TAG'" >/dev/null
    for f in "$@"; do
      if [ "$lenient" = 1 ]; then
        errs="$(psql "$(url_for "$name")" -X -q -v ON_ERROR_STOP=0 -f "$f" 2>&1 >/dev/null | grep -c 'ERROR:' || true)"
        echo "scratch-pg: loaded $f (lenient: $errs SQL error(s) skipped)" >&2
      else
        psql "$(url_for "$name")" -X -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null || die 2 "loading $f into $name failed"
        echo "scratch-pg: loaded $f" >&2
      fi
    done
    echo "scratch-pg: created $name" >&2
    url_for "$name"
    ;;
  drop)
    [ $# -eq 1 ] || usage
    check_name "$1"; ensure_pg; do_drop "$1" ;;
  url)
    [ $# -eq 1 ] || usage
    check_name "$1"; url_for "$1" ;;
  list)
    ensure_pg
    psql_admin -c "SELECT datname FROM pg_database WHERE shobj_description(oid, 'pg_database') = '$TAG' ORDER BY 1" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
