#!/usr/bin/env python3
# MAINTAINER-ONLY: self-test implementation of the events-processor suite (a worked corrected-profile IUT); excluded from clean-room packs.
"""selftest-iut.py - a deliberately small events-processor in Python, written from the
behaviour rules of this skill only, used to prove that the conformance runner is
language-agnostic (librdkafka consumer group against kfake, redis-py against miniredis,
psycopg2 against the scratch database). Not a reference implementation: it is excluded
from clean-room packs so implementers derive their own design from the spec.

Usage (Python >= 3.10 with confluent-kafka, redis, psycopg2-binary):
  run-suite.sh --impl-cmd "<venv>/bin/python <this file>" --profile both --loose-errors

It implements the CORRECTED profile on purpose (not the reference quirks):
  * value: plain decimal (integers exact, non-integers shortest round-trip float, missing/null -> "0")
  * timestamps: "<sec>.<frac>" parsed without floats; RFC3339 normalised to UTC; ms truncation
  * undecodable records -> DLQ error_code "decode_event" (never committed silently)
  * retryable failures (DB, Redis, Kafka produce) are retried in place, blocking the partition
    (one of the OD-2 delivery options), so nothing is committed past an unprocessed record
  * startup contract: missing configuration or an unreachable dependency -> exit 2 before
    joining the consumer group
KNOWN DEVIATION (kept on purpose, the suite must catch it): a broker rejection of the
enriched produce is retried in place instead of being dead-lettered (EPC-18 corrected FAIL).
NOT implemented: custom expressions (DLQ "evaluate_expression"), memory-cache mode, SASL/TLS.
Configuration: the same environment variables as the reference.
"""
import json, os, signal, sys, time
from datetime import datetime, timezone
from decimal import Decimal

import psycopg2
import redis
from confluent_kafka import Consumer, Producer, KafkaException

ENV = os.environ
REQUIRED = ["LAGO_KAFKA_BOOTSTRAP_SERVERS", "LAGO_KAFKA_RAW_EVENTS_TOPIC", "LAGO_KAFKA_ENRICHED_EVENTS_TOPIC",
            "LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC", "LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC",
            "LAGO_KAFKA_CONSUMER_GROUP", "LAGO_REDIS_STORE_URL", "DATABASE_URL"]
_missing = [k for k in REQUIRED if not ENV.get(k, "").strip()]
if _missing:
    print(json.dumps({"level": "ERROR", "msg": "missing configuration", "variables": _missing}), flush=True)
    sys.exit(2)
RAW = ENV["LAGO_KAFKA_RAW_EVENTS_TOPIC"]
T_ENR = ENV["LAGO_KAFKA_ENRICHED_EVENTS_TOPIC"]
T_ADV = ENV["LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC"]
T_DLQ = ENV["LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC"]
GROUP = ENV["LAGO_KAFKA_CONSUMER_GROUP"] + "_" + RAW
BROKERS = ",".join(b.strip() for b in ENV["LAGO_KAFKA_BOOTSTRAP_SERVERS"].split(",") if b.strip())
AGG = {0: "count", 1: "sum", 2: "max", 3: "unique_count", 5: "weighted_sum", 6: "latest", 7: "custom"}

stop = False
def _stop(*_):
    global stop
    stop = True
signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


class Retryable(Exception):
    pass


class Fail(Exception):
    def __init__(self, code, message, initial):
        super().__init__(initial)
        self.code, self.message, self.initial = code, message, initial


def connect_all():
    host, _, port = ENV["LAGO_REDIS_STORE_URL"].split("://")[-1].rpartition(":")
    r = redis.Redis(host=host or "localhost", port=int(port), db=int(ENV.get("LAGO_REDIS_STORE_DB", "0") or 0))
    r.ping()
    db = psycopg2.connect(ENV["DATABASE_URL"], connect_timeout=5)
    db.autocommit = True
    if not BROKERS:
        raise RuntimeError("empty broker list")
    prod = Producer({"bootstrap.servers": BROKERS, "enable.idempotence": False, "acks": "all",
                     "message.send.max.retries": 0})
    prod.list_topics(timeout=10)  # fail fast when no broker answers
    return r, db, prod


def to_utc_ms(ts):
    """Return (datetime UTC truncated to ms, emitted seconds as Decimal) or raise Fail."""
    bad = lambda m: Fail("build_enriched_event", "Error while converting event to enriched event", m)
    if isinstance(ts, bool) or ts is None or isinstance(ts, (dict, list)):
        raise bad("Unsupported timestamp type: %s" % type(ts).__name__)
    if isinstance(ts, (int, Decimal)):
        ts = str(ts)
    s = ts
    try:
        d = Decimal(s)
        if not d.is_finite():
            raise ValueError
        sec = int(d // 1)
        ms = int(((d - sec) * 1000) // 1)
        dt = datetime.fromtimestamp(sec, tz=timezone.utc).replace(microsecond=ms * 1000)
        return dt, Decimal(sec) + Decimal(ms) / 1000
    except Exception:
        pass
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            raise ValueError
        dt = dt.astimezone(timezone.utc)
        dt = dt.replace(microsecond=(dt.microsecond // 1000) * 1000)
        return dt, Decimal(int(dt.timestamp() // 1)) + Decimal(dt.microsecond // 1000) / 1000
    except Exception:
        raise bad("unparsable timestamp %r" % s)


def plain(v):
    if v is None:
        return "0"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, Decimal):  # JSON non-integer: shortest round-trip float, plain notation
        f = Decimal(repr(float(v)))
        t = format(f, "f")
        if "." in t:
            t = t.rstrip("0").rstrip(".")
        return t
    if isinstance(v, str):
        return v
    return json.dumps(v, separators=(",", ":"))


def jnum(d):
    """Decimal -> JSON number text without exponent."""
    t = format(d, "f")
    if "." in t:
        t = t.rstrip("0").rstrip(".")
    return t


def encode(obj):
    def walk(o):
        if isinstance(o, Decimal):
            return jnum(o)
        if isinstance(o, bool) or o is None or isinstance(o, (int, str)):
            return json.dumps(o, ensure_ascii=False)
        if isinstance(o, dict):
            return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + walk(v) for k, v in o.items()) + "}"
        if isinstance(o, list):
            return "[" + ",".join(walk(v) for v in o) + "]"
        return json.dumps(o)
    return walk(obj).encode()


def q(db, sql, args):
    try:
        with db.cursor() as c:
            c.execute(sql, args)
            return c.fetchall()
    except psycopg2.Error as e:
        raise Retryable("db: %s" % str(e).strip())


def enrich(db, ev):
    org, code = ev.get("organization_id", ""), ev.get("code", "")
    when, emitted = to_utc_ms(ev.get("timestamp"))
    rows = q(db, "SELECT id, aggregation_type, field_name, expression, recurring FROM billable_metrics "
                 "WHERE organization_id::text = %s AND code = %s AND deleted_at IS NULL ORDER BY id LIMIT 1", (org, code))
    if not rows:
        raise Fail("fetch_billable_metric", "Error fetching billable metric", "record not found")
    bm_id, agg, field, expr, recurring = rows[0]
    props = ev.get("properties")
    if expr and ev.get("source") != "http_ruby":
        raise Fail("evaluate_expression", "Error evaluating custom expression", "expressions not supported by selftest-iut")

    def sub_at(t):
        r = q(db, "SELECT id, plan_id FROM subscriptions WHERE organization_id::text = %s AND external_id = %s "
                  "AND date_trunc('millisecond', started_at) <= %s AND (terminated_at IS NULL OR "
                  "date_trunc('millisecond', terminated_at) >= %s) ORDER BY terminated_at DESC NULLS FIRST, "
                  "started_at DESC LIMIT 1",
              (org, ev.get("external_subscription_id", ""), t.replace(tzinfo=None), t.replace(tzinfo=None)))
        return r[0] if r else None
    sub = sub_at(when)
    if sub is None and recurring:
        sub = sub_at(datetime.now(timezone.utc))
    value = "1" if agg == 0 else plain((props or {}).get(field) if isinstance(props, dict) else None)
    ptac = ev.get("precise_total_amount_cents", "")
    out = {
        "organization_id": org, "external_subscription_id": ev.get("external_subscription_id", ""),
        "subscription_id": str(sub[0]) if sub else "", "plan_id": str(sub[1]) if sub else "",
        "transaction_id": ev.get("transaction_id", ""), "code": code, "aggregation_type": AGG.get(agg, ""),
        "properties": props if isinstance(props, dict) else {},
        "precise_total_amount_cents": plain(ptac) if ptac != "" else "",
        "value": value, "timestamp": emitted,
    }
    if ev.get("source"):
        out["source"] = ev["source"]
    return out, sub, bm_id


def produce(prod, topic, key, value):
    errs = []
    prod.produce(topic, value=value, key=key, on_delivery=lambda e, m: errs.append(e) if e else None)
    prod.flush(10)
    if errs:
        raise Retryable("produce %s: %s" % (topic, errs[0]))


DONE = {}  # (partition, offset) -> side effects already performed (retry only what failed)


def once(key, step, fn):
    steps = DONE.setdefault(key, set())
    if step not in steps:
        fn()
        steps.add(step)


def handle(r, db, prod, raw, key_po=None):
    """Process one record completely; raise Retryable to retry it (nothing committed).
    Side effects already done for this record are not repeated on retry."""
    try:
        ev = json.loads(raw, parse_float=Decimal)
        if not isinstance(ev, dict) or not isinstance(ev.get("properties", {}), (dict, type(None))):
            raise ValueError("event is not a JSON object with object properties")
        for k in ("transaction_id", "code", "organization_id", "external_subscription_id"):
            if k in ev and not isinstance(ev[k], str):
                raise ValueError("%s is not a string" % k)
    except Exception as e:  # undecodable: DLQ with the raw text, never a silent commit
        dl = {"event": {}, "raw_event": raw.decode("utf-8", "replace"), "error_code": "decode_event",
              "error_message": "Error decoding event", "initial_error_message": str(e),
              "failed_at": datetime.now(timezone.utc).isoformat()}
        produce(prod, T_DLQ, None, encode(dl))
        return
    try:
        out, sub, bm_id = enrich(db, ev)
    except Fail as f:
        dl = {"event": ev, "error_code": f.code, "error_message": f.message, "initial_error_message": f.initial,
              "failed_at": datetime.now(timezone.utc).isoformat()}
        produce(prod, T_DLQ, None, encode(dl))
        return
    key = ("%s-%s" % (out["organization_id"], out["transaction_id"])).encode()
    body = encode(out)
    post = ev.get("source") != "http_ruby" or not (ev.get("source_metadata") or {}).get("api_post_processed")
    in_adv = False
    flag = None
    if sub is not None and post:
        in_adv = bool(q(db, "SELECT 1 FROM charges WHERE organization_id::text = %s AND plan_id = %s AND "
                            "billable_metric_id = %s AND pay_in_advance IS TRUE AND deleted_at IS NULL LIMIT 1",
                        (out["organization_id"], sub[1], bm_id)))
        flag = "%s:%s" % (out["organization_id"], out["subscription_id"])
    # all reads done: emit; a retry repeats only the side effects that have not succeeded yet
    once(key_po, "enriched", lambda: produce(prod, T_ENR, key, body))
    if in_adv:
        once(key_po, "in_advance", lambda: produce(prod, T_ADV, key, body))
    if flag:
        def zadd():
            now = int(time.time())
            try:
                r.zadd("subscription_refreshed_v2", {"%s|%d" % (flag, now // 10 * 10): now})
            except redis.RedisError as e:
                raise Retryable("redis: %s" % e)
        once(key_po, "refresh", zadd)


def main():
    r, db, prod = connect_all()
    c = Consumer({"bootstrap.servers": BROKERS, "group.id": GROUP, "enable.auto.commit": False,
                  "auto.offset.reset": "earliest", "session.timeout.ms": 10000})
    c.subscribe([RAW])
    while not stop:
        m = c.poll(0.2)
        if m is None:
            continue
        if m.error():
            continue
        delay = 0.1
        while not stop:
            try:
                handle(r, db, prod, m.value() or b"", (m.partition(), m.offset()))
                c.commit(message=m, asynchronous=False)
                DONE.pop((m.partition(), m.offset()), None)
                break
            except Retryable as e:
                print(json.dumps({"level": "WARN", "msg": "retrying record", "offset": m.offset(), "error": str(e)}), flush=True)
                if "db:" in str(e):
                    try:
                        db.close()
                    except Exception:
                        pass
                    try:
                        db = psycopg2.connect(ENV["DATABASE_URL"]); db.autocommit = True
                    except psycopg2.Error:
                        pass
                time.sleep(delay)
                delay = min(delay * 2, 2.0)
    c.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"level": "ERROR", "msg": "startup or fatal error", "error": str(e)}), flush=True)
        sys.exit(2)
