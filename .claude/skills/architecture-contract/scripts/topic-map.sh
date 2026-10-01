#!/usr/bin/env bash
set -euo pipefail
# topic-map.sh — where every Kafka topic / consumer group / Redis key of the events pipeline comes from.
#
# Usage (from anywhere inside the lago repo):
#   .claude/skills/architecture-contract/scripts/topic-map.sh [--api DIR | --no-api] [--strict]
#
#   --api DIR   lago-api checkout to scan for readers/writers (default: the pinned checkout printed by
#               .claude/skills/research-methodology/scripts/pinned-checkout.sh api, if it succeeds)
#   --no-api    skip the lago-api columns (fully offline, repo only)
#   --strict    exit 1 when any FLAG line is printed (orphans / drift); default exit 0
#
# Sections printed:
#   1. events-processor Kafka topics: env var | role (consume/produce) | EP file:line | dev value
#      (.env.development.default) | created by redpandacreatetopics (docker-compose.dev.yml) | key
#   2. derived names: raw-topic consumer group, CDC topics + groups (memory-cache mode), Redis ZSET
#   3. other LAGO_KAFKA_*_TOPIC vars and hard-coded topics in lago-api (with reader files)
#   FLAG lines: topics referenced somewhere but not created in dev, or env vars read by lago-api but
#   absent from .env.development.default (e.g. the removed events_enriched_expanded topic).
# Read-only. Exit codes: 0 ok (or flags without --strict), 1 flags with --strict, 2 setup error.

API=""; USE_API=1; STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="${2:?--api needs a directory}"; shift 2 ;;
    --no-api) USE_API=0; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside the lago git checkout" >&2; exit 2; }
cd "$REPO"
EP=events-processor
DEVENV=.env.development.default
DC=docker-compose.dev.yml
for f in "$EP/processors/main_processor.go" "$EP/config/kafka/consumer.go" "$DEVENV" "$DC" extra/debezium_config.json; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }
done

if [ "$USE_API" -eq 1 ] && [ -z "$API" ]; then
  API="$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api 2>/dev/null || true)"
  [ -n "$API" ] && [ -d "$API" ] || { echo "INFO lago-api checkout unavailable; continuing with --no-api" >&2; USE_API=0; }
fi
[ "$USE_API" -eq 0 ] || [ -d "$API" ] || { echo "--api $API is not a directory" >&2; exit 2; }

FLAGS=0
flag() { echo "FLAG $*"; FLAGS=$((FLAGS + 1)); }
devval() { sed -n "s/^$1=//p" "$DEVENV" | tail -n1; }
# topics created by the redpandacreatetopics one-shot service (its `command:` list)
CREATED="$(awk '/^  redpandacreatetopics:/ {s=1; next} s && /^  [a-z]/ {s=0} s && /command:/ {c=1; next} s && c && /^ *- / {sub(/^ *- */, ""); print; next} s && c {c=0}' "$DC" | tr '\n' ' ')"
created() { case " $CREATED " in *" $1 "*) echo yes ;; *) echo NO ;; esac; }
api_readers() { # env var or literal -> comma list of lago-api files (no specs)
  [ "$USE_API" -eq 1 ] || { echo "-"; return; }
  (cd "$API" && grep -rlF -- "$1" --include='*.rb' app config db lib karafka.rb clock.rb 2>/dev/null | grep -v '^spec/' | sort | tr '\n' ',' | sed 's/,$//') || true
}

echo "== 1. events-processor Kafka topics (as read from code; dev values from $DEVENV)"
printf '%-44s %-8s %-50s %-27s %-8s %s\n' "ENV VAR" "ROLE" "EP FILE:LINE" "DEV VALUE" "CREATED" "KEY"
MP="$EP/processors/main_processor.go"
# constants: envLagoKafkaXxxTopic = "LAGO_KAFKA_..._TOPIC"
grep -E '^\s+envLagoKafka[A-Za-z]+Topic\s+=' "$MP" | while read -r const _ var; do
  var="${var//\"/}"
  role="?"; loc="-"; key="-"
  if l="$(grep -n "initProducer(ctx, $const)" "$MP" | head -n1 | cut -d: -f1)" && [ -n "$l" ]; then
    role="produce"; loc="$MP:$l"
  elif l="$(grep -n "os.Getenv($const)" "$MP" | grep -v 'initProducer' | head -n1 | cut -d: -f1)" && [ -n "$l" ]; then
    role="consume"; loc="$MP:$l"
  fi
  case "$var" in
    LAGO_KAFKA_ENRICHED_EVENTS_TOPIC|LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC) key="<org_id>-<transaction_id>" ;;
    LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC) key="(none)" ;;
    LAGO_KAFKA_RAW_EVENTS_TOPIC) key="(none from Rails; connectors: <org>-<ext_sub>)" ;;
  esac
  v="$(devval "$var")"; c="$( [ -n "$v" ] && created "$v" || echo '-')"
  printf '%-44s %-8s %-50s %-27s %-8s %s\n' "$var" "$role" "$loc" "${v:-<unset>}" "$c" "$key"
  [ -n "$v" ] || echo "     ^ $var has no dev default"
  [ "$c" != "NO" ] || echo "     ^ $v is not in the redpandacreatetopics list"
  if [ "$USE_API" -eq 1 ]; then echo "     lago-api: $(api_readers "\"$var\"")"; fi
done
KEYLINE="$(grep -n 'msgKey := fmt.Sprintf' "$EP/processors/events_processor/event_producer_service.go" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
echo "   keys: $EP/processors/events_processor/event_producer_service.go:$KEYLINE ; DLQ record has no key (same file, ProduceToDeadLetterQueue)"

echo
echo "== 2. derived names"
CG="$(devval LAGO_KAFKA_CONSUMER_GROUP)"; RAW="$(devval LAGO_KAFKA_RAW_EVENTS_TOPIC)"
CGL="$(grep -n 'cgName := fmt.Sprintf' "$EP/config/kafka/consumer.go" | cut -d: -f1)"
echo "raw-topic consumer group = <LAGO_KAFKA_CONSUMER_GROUP>_<LAGO_KAFKA_RAW_EVENTS_TOPIC>   ($EP/config/kafka/consumer.go:$CGL)"
echo "   dev: ${CG:-<unset>}_${RAW:-<unset>}   (a NEW group id starts at the EARLIEST offset: renaming either part replays the retained raw topic)"
PREFIX="$(sed -n 's/.*"topic.prefix": *"\([^"]*\)".*/\1/p' extra/debezium_config.json)"
TABLES="$(sed -n 's/.*"table.include.list": *"\([^"]*\)".*/\1/p' extra/debezium_config.json | tr ',' ' ')"
DEVPFX="$(devval LAGO_DEBEZIUM_TOPIC_PREFIX)"
echo "memory-cache CDC topics = \$LAGO_DEBEZIUM_TOPIC_PREFIX + \".public.<table>\"  (only when LAGO_USE_MEMORY_CACHE=true; OD-1)"
echo "   dev LAGO_DEBEZIUM_TOPIC_PREFIX: ${DEVPFX:-<unset> (dev runs DB mode)} ; extra/debezium_config.json topic.prefix: ${PREFIX:-<unset>}"
for t in $(grep -ho 'Topic *= *"\.public\.[a-z_]*"' "$EP"/cache/*.go | sed 's/.*"\.public\.\([a-z_]*\)"/\1/' | sort); do
  f="$(grep -l "\"\.public\.$t\"" "$EP"/cache/*.go | head -n1)"; l="$(grep -n "\"\.public\.$t\"" "$f" | cut -d: -f1)"
  inconf=NO; case " $TABLES " in *" public.$t "*) inconf=yes ;; esac
  printf '   %-52s group lago_evp_%s_<uuid per start>   %s:%s   in debezium table.include.list: %s\n' "${PREFIX:-<prefix>}.public.$t" "$t" "$f" "$l" "$inconf"
  [ "$inconf" = yes ] || flag "CDC topic for $t is consumed by EP but $t is not in extra/debezium_config.json table.include.list"
done
ZL="$(grep -n 'initFlagStore(ctx, "' "$MP" | cut -d: -f1)"; ZK="$(sed -n "${ZL}p" "$MP" | sed 's/.*initFlagStore(ctx, "\([^"]*\)").*/\1/')"
BL="$(grep -n 'SUBSCRIPTION_BUCKET_DURATION int64 =' "$EP/models/stores.go" | cut -d: -f1)"
echo "Redis ZSET = $ZK ($MP:$ZL); member <org_id>:<subscription_id>|<floor(now/10)*10>, score = now (unix s) ($EP/models/stores.go:$BL,54-69)"
if [ "$USE_API" -eq 1 ]; then echo "   lago-api: $(api_readers "\"$ZK\"")"; fi

echo
echo "== 3. other topics in the pipeline's neighbourhood"
if [ "$USE_API" -eq 1 ]; then
  EPVARS=" $(grep -oE 'LAGO_KAFKA_[A-Z_]+_TOPIC' "$MP" | sort -u | tr '\n' ' ') "
  for var in $(cd "$API" && grep -rhoE 'ENV(\["|\.fetch\(")LAGO_KAFKA_[A-Z_]+_TOPIC' --include='*.rb' app config db lib karafka.rb 2>/dev/null | grep -oE 'LAGO_KAFKA_[A-Z_]+_TOPIC' | sort -u); do
    case "$EPVARS" in *" $var "*) continue ;; esac
    v="$(devval "$var")"
    printf '%-44s rails-only  dev=%-22s created=%-4s lago-api: %s\n' "$var" "${v:-<unset>}" "$( [ -n "$v" ] && created "$v" || echo '-')" "$(api_readers "\"$var\"")"
    [ -n "$v" ] || flag "$var is read by lago-api but has no value in $DEVENV (e.g. removed by d9c32b6 for events_enriched_expanded)"
  done
  for lit in $(cd "$API" && grep -rhoE 'dead_letter_queue\(topic: "[a-z_]+"' karafka.rb 2>/dev/null | sed 's/.*"\([a-z_]*\)"/\1/' | sort -u); do
    printf '%-44s rails-only  karafka dead_letter_queue topic   created=%s\n' "\"$lit\" (hard-coded)" "$(created "$lit")"
    [ "$(created "$lit")" = yes ] || flag "hard-coded Karafka DLQ topic \"$lit\" is not in the redpandacreatetopics list"
  done
else
  echo "(skipped: --no-api)"
fi
echo "raw-topic producers outside Rails: connectors/{http,sqs,kinesis}.yml write to \${KAFKA_TOPIC} (a different env var name)"

echo
echo "SUMMARY flags=$FLAGS"
[ "$STRICT" -eq 1 ] && [ "$FLAGS" -gt 0 ] && exit 1
exit 0
