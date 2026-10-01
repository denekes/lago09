#!/usr/bin/env bash
# vendored-jar-verify.sh - compare the committed Kafka Connect jars with their upstream artifacts.
#
# Usage: vendored-jar-verify.sh [--repo DIR] [--manifest]
#   default     network: Maven Central .sha1 for Debezium / PostgreSQL JDBC / protobuf jars,
#               GitHub release zip (sha256 of the inner jar) for the ClickHouse connector.
#   --manifest  offline: print "sha256  path" for every tracked *.jar (the content of a candidate
#               SHA256SUMS file; it records today's bytes, it does not prove provenance).
# Output: MATCH | MISMATCH | UNREACHABLE | UNKNOWN-SOURCE <path> <upstream>; then SUMMARY.
# Writes only to a mktemp -d directory that is removed on exit. Read-only on the repo.
# Exit codes: 0 every jar MATCH (or --manifest done); 1 at least one MISMATCH;
#   4 no mismatch but at least one UNREACHABLE / UNKNOWN-SOURCE; 2 usage.
set -euo pipefail

REPO=""; MANIFEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --manifest) MANIFEST=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo; use --repo" >&2; exit 2; }
cd "$REPO"
mapfile -t JARS < <(git ls-files -- '*.jar' | sort)

if [ "$MANIFEST" = 1 ]; then
  for j in "${JARS[@]}"; do sha256sum "$j"; done
  echo "SUMMARY vendored-jar-verify: manifest jars=${#JARS[@]}"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
M=0; X=0; U=0
for j in "${JARS[@]}"; do
  b=$(basename "$j"); src=""; kind=""
  if [[ "$b" =~ ^(debezium-[a-z-]+)-([0-9][0-9A-Za-z.]*Final)\.jar$ ]]; then
    src="https://repo1.maven.org/maven2/io/debezium/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/$b"; kind=maven
  elif [[ "$b" =~ ^postgresql-([0-9.]+)\.jar$ ]]; then
    src="https://repo1.maven.org/maven2/org/postgresql/postgresql/${BASH_REMATCH[1]}/$b"; kind=maven
  elif [[ "$b" =~ ^protobuf-java-([0-9.]+)\.jar$ ]]; then
    src="https://repo1.maven.org/maven2/com/google/protobuf/protobuf-java/${BASH_REMATCH[1]}/$b"; kind=maven
  elif [[ "$b" =~ ^clickhouse-kafka-connect-(v[0-9.]+)-confluent\.jar$ ]]; then
    v="${BASH_REMATCH[1]}"
    src="https://github.com/ClickHouse/clickhouse-kafka-connect/releases/download/$v/clickhouse-kafka-connect-$v.zip"; kind=zip
  fi
  if [ -z "$kind" ]; then printf 'UNKNOWN-SOURCE\t%s\t-\n' "$j"; U=$((U+1)); continue; fi
  if [ "$kind" = maven ]; then
    remote=""
    if curl -fsS --retry 3 --retry-all-errors --retry-delay 2 --max-time 30 -o "$TMP/sum" "$src.sha1" 2>/dev/null; then
      remote=$(tr -d ' \r\n' < "$TMP/sum" | cut -c1-40)
    fi
    local_sum=$(sha1sum "$j" | cut -c1-40)
  else
    if curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 --max-time 180 -o "$TMP/a.zip" "$src" 2>/dev/null && unzip -o -q "$TMP/a.zip" -d "$TMP/z" 2>/dev/null; then
      inner=$(find "$TMP/z" -name "$b" | head -1)
      remote=$([ -n "$inner" ] && sha256sum "$inner" | cut -c1-64 || true)
    else remote=""; fi
    local_sum=$(sha256sum "$j" | cut -c1-64)
    rm -rf "$TMP/a.zip" "$TMP/z"
  fi
  if [ -z "$remote" ]; then printf 'UNREACHABLE\t%s\t%s\n' "$j" "$src"; U=$((U+1))
  elif [ "$remote" = "$local_sum" ]; then printf 'MATCH\t%s\t%s\n' "$j" "$src"; M=$((M+1))
  else printf 'MISMATCH\t%s\t%s\n' "$j" "$src"; X=$((X+1)); fi
done
echo "SUMMARY vendored-jar-verify: jars=${#JARS[@]} match=$M mismatch=$X unreachable_or_unknown=$U"
[ "$X" -gt 0 ] && exit 1
[ "$U" -gt 0 ] && exit 4
exit 0
