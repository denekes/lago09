"""Lago events-processor re-implementation (DB mode, corrected delivery profile).

One ordered worker: every record reaches a durable disposition (enriched [+ in-advance + refresh flag],
or dead letter) before its offset is committed; failing dependencies block the partition and are retried
with backoff instead of being skipped.
"""
import logging
import os
import random
import re
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone

import ep_core as core
import expr

log = logging.getLogger("ep")

INPLACE_ATTEMPTS = int(os.environ.get("EP_INPLACE_ATTEMPTS", "3"))
INPLACE_BASE_S = float(os.environ.get("EP_INPLACE_BASE_S", "0.1"))
BACKOFF_BASE_S = float(os.environ.get("EP_BACKOFF_BASE_S", "0.25"))
BACKOFF_MAX_S = float(os.environ.get("EP_BACKOFF_MAX_S", "2"))
MAX_AGE_S = float(os.environ.get("EP_RETRY_MAX_AGE_S", str(12 * 3600)))
PRODUCE_TIMEOUT_S = float(os.environ.get("EP_PRODUCE_TIMEOUT_S", "30"))
BATCH = int(os.environ.get("EP_BATCH", "500"))
REFRESH_SET = "subscription_refreshed_v2"
PROFILE = os.environ.get("EP_PROFILE", "corrected")  # "compat" reproduces the reference (migration testing)
COMPAT = PROFILE == "compat"

stop = threading.Event()


class Fatal(Exception):
    pass


class Shutdown(Exception):
    pass


class Transient(Exception):
    pass


class Permanent(Exception):
    pass


class ProduceRejected(Exception):
    pass


# ------------------------------------------------------------------ configuration

def parse_bool(v):
    return (v or "").strip() in ("1", "t", "T", "true", "TRUE", "True")


class Config:
    def __init__(self, env=os.environ):
        g = env.get
        self.brokers = [b.strip() for b in (g("LAGO_KAFKA_BOOTSTRAP_SERVERS") or "").split(",") if b.strip()]
        if not self.brokers:
            raise Fatal("LAGO_KAFKA_BOOTSTRAP_SERVERS is empty")
        self.raw_topic = g("LAGO_KAFKA_RAW_EVENTS_TOPIC") or ""
        self.enriched_topic = g("LAGO_KAFKA_ENRICHED_EVENTS_TOPIC") or ""
        self.advance_topic = g("LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC") or ""
        self.dlq_topic = g("LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC") or ""
        for name, v in (("LAGO_KAFKA_RAW_EVENTS_TOPIC", self.raw_topic),
                        ("LAGO_KAFKA_ENRICHED_EVENTS_TOPIC", self.enriched_topic),
                        ("LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC", self.advance_topic),
                        ("LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC", self.dlq_topic)):
            if not v:
                raise Fatal("%s is empty" % name)
        self.group = "%s_%s" % (g("LAGO_KAFKA_CONSUMER_GROUP") or "", self.raw_topic)
        self.scram = g("LAGO_KAFKA_SCRAM_ALGORITHM") or ""
        if self.scram and self.scram not in ("SCRAM-SHA-256", "SCRAM-SHA-512"):
            raise Fatal("unsupported LAGO_KAFKA_SCRAM_ALGORITHM %r" % self.scram)
        self.kafka_user = g("LAGO_KAFKA_USERNAME") or ""
        self.kafka_password = g("LAGO_KAFKA_PASSWORD") or ""
        self.kafka_tls = parse_bool(g("LAGO_KAFKA_TLS"))
        self.database_url = g("DATABASE_URL") or ""
        if not self.database_url:
            raise Fatal("DATABASE_URL is empty")
        mc = g("LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS")
        if mc not in (None, ""):
            try:
                self.max_connections = int(mc)
            except ValueError:
                raise Fatal("LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS is not an integer")
        else:
            self.max_connections = 200
        url = g("LAGO_REDIS_STORE_URL") or ""
        for pre in ("rediss://", "redis://"):
            if url.startswith(pre):
                url = url[len(pre):]
        if not url:
            raise Fatal("LAGO_REDIS_STORE_URL is empty")
        self.redis_addr = url
        try:
            self.redis_db = int(g("LAGO_REDIS_STORE_DB") or 0)
        except ValueError:
            raise Fatal("LAGO_REDIS_STORE_DB is not an integer")
        self.redis_password = g("LAGO_REDIS_STORE_PASSWORD") or None
        tls = g("LAGO_REDIS_STORE_TLS")
        self.redis_tls = parse_bool(tls) if tls not in (None, "") else (g("ENV") == "production")


# ------------------------------------------------------------------ dependencies

class Catalog:
    """Postgres catalog reads (DB mode). One autocommit connection, reconnected on failure."""

    def __init__(self, dsn):
        import psycopg2

        self.psycopg2 = psycopg2
        self.dsn = dsn
        self.conn = None
        self.connect()

    def connect(self):
        self.close()
        self.conn = self.psycopg2.connect(self.dsn, connect_timeout=10,
                                          options="-c statement_timeout=15000")
        self.conn.autocommit = True

    def close(self):
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:
            pass
        self.conn = None

    def query_one(self, sql, params):
        pg = self.psycopg2
        try:
            if self.conn is None or self.conn.closed:
                self.connect()
            with self.conn.cursor() as cur:
                cur.execute(sql, params)
                return cur.fetchone()
        except (pg.DataError, ValueError) as e:
            raise Permanent(str(e))
        except pg.Error as e:
            if self.conn is None or self.conn.closed or isinstance(e, (pg.OperationalError, pg.InterfaceError)):
                self.close()
            raise Transient(str(e).strip())
        except OSError as e:
            self.close()
            raise Transient(str(e))

    def metric(self, org, code):
        if not valid_uuid(org):
            if COMPAT:
                # EP-E4 reference: the database type error is a retryable lookup failure
                raise Transient('invalid input syntax for type uuid: "%s"' % org)
            return None
        return self.query_one(
            "SELECT id, aggregation_type, recurring, field_name, expression FROM billable_metrics "
            "WHERE organization_id = %s AND code = %s AND deleted_at IS NULL LIMIT 1", (org, code))

    def subscription(self, org, ext_id, t_us):
        if not valid_uuid(org):
            return None
        try:
            ts = datetime(1970, 1, 1) + timedelta(microseconds=t_us)
        except OverflowError:
            return None
        return self.query_one(
            "SELECT id, plan_id FROM subscriptions WHERE organization_id = %s AND external_id = %s "
            "AND date_trunc('milliseconds', started_at) <= %s "
            "AND (terminated_at IS NULL OR date_trunc('milliseconds', terminated_at) >= %s) "
            "ORDER BY (terminated_at IS NULL) DESC, terminated_at DESC, started_at DESC LIMIT 1",
            (org, ext_id, ts, ts))

    def has_advance_charge(self, org, plan_id, metric_id):
        return self.query_one(
            "SELECT 1 FROM charges WHERE organization_id = %s AND plan_id = %s AND billable_metric_id = %s "
            "AND pay_in_advance AND deleted_at IS NULL LIMIT 1", (org, plan_id, metric_id)) is not None


def valid_uuid(s):
    try:
        uuid.UUID(s)
        return True
    except (ValueError, AttributeError, TypeError):
        return False


class Flag:
    def __init__(self, cfg):
        import redis

        self.redis = redis
        host, _, port = cfg.redis_addr.rpartition(":")
        if not host:
            host, port = cfg.redis_addr, "6379"
        self.cl = redis.Redis(host=host, port=int(port), db=cfg.redis_db, password=cfg.redis_password,
                              ssl=cfg.redis_tls, socket_timeout=5, socket_connect_timeout=5)

    def ping(self):
        self.cl.ping()

    def write(self, org, sub_id):
        member, score = core.refresh_member(org, sub_id, time.time())
        try:
            self.cl.zadd(REFRESH_SET, {member: score})
        except (self.redis.RedisError, OSError) as e:
            raise Transient(str(e))


class Out:
    """Synchronous, acknowledged producer (acks=all, idempotent)."""

    PERMANENT = None

    def __init__(self, cfg):
        from confluent_kafka import KafkaError, Producer

        self.KafkaError = KafkaError
        Out.PERMANENT = {KafkaError.INVALID_RECORD, KafkaError.MSG_SIZE_TOO_LARGE}
        conf = kafka_conf(cfg)
        idem = os.environ.get("EP_IDEMPOTENT", "0") not in ("0", "false")
        conf.update({"acks": "all", "enable.idempotence": idem, "message.timeout.ms": int(PRODUCE_TIMEOUT_S * 1000),
                     "linger.ms": 0})
        if not idem:
            conf.update({"max.in.flight.requests.per.connection": 1, "retries": 1000000})
        self.p = Producer(conf)

    def check(self, timeout=15):
        try:
            self.p.list_topics(timeout=timeout)
        except Exception as e:
            raise Fatal("broker check failed: %s" % e)

    def send(self, topic, key, value):
        res = {}

        def cb(err, msg):
            res["err"] = err
            res["done"] = True

        try:
            self.p.produce(topic, value=value, key=key, on_delivery=cb)
        except BufferError:
            self.p.poll(0.5)
            raise Transient("producer queue full")
        except Exception as e:
            raise Transient("produce failed: %s" % e)
        deadline = time.time() + PRODUCE_TIMEOUT_S + 10
        while not res.get("done") and time.time() < deadline:
            self.p.poll(0.1)
        if not res.get("done"):
            raise Transient("produce not acknowledged")
        err = res["err"]
        if err is not None:
            if err.code() in Out.PERMANENT:
                raise ProduceRejected("failed to push to %s topic: %s" % (topic, err))
            raise Transient("failed to push to %s topic: %s" % (topic, err))


def kafka_conf(cfg):
    conf = {"bootstrap.servers": ",".join(cfg.brokers), "client.id": "ep-crc9"}
    if cfg.scram:
        conf.update({"security.protocol": "SASL_SSL" if cfg.kafka_tls else "SASL_PLAINTEXT",
                     "sasl.mechanism": cfg.scram, "sasl.username": cfg.kafka_user,
                     "sasl.password": cfg.kafka_password})
    elif cfg.kafka_tls:
        conf["security.protocol"] = "SSL"
    return conf


# ------------------------------------------------------------------ the processor

def now_utc_ns():
    return int(time.time() * 1e9)


class Processor:
    def __init__(self, cfg, catalog, out, flag):
        self.cfg, self.catalog, self.out, self.flag = cfg, catalog, out, flag
        self.stats = {"enriched": 0, "advance": 0, "dead": 0}

    # ---- retry machinery

    def sleep(self, secs):
        if stop.wait(secs):
            raise Shutdown()

    def step(self, fn, code, ingested_ns, rec_label=""):
        """Run one side-effect step. Transient failures are retried in place, then the partition is blocked
        with backoff until the dependency answers; Permanent errors propagate. After the in-place budget a
        record older than the retry horizon is dead-lettered (RetryExhausted).
        Compat profile: one attempt, a failure is reported as CompatFailure (reference behaviour)."""
        if COMPAT:
            try:
                return fn()
            except Transient as e:
                raise CompatFailure(code, str(e))
        attempt = 0
        backoff = BACKOFF_BASE_S
        while True:
            if stop.is_set():
                raise Shutdown()
            try:
                return fn()
            except Transient as e:
                attempt += 1
                last = str(e)
                if attempt <= INPLACE_ATTEMPTS:
                    self.sleep(INPLACE_BASE_S * (2 ** (attempt - 1)) * (0.75 + random.random() / 2))
                    continue
                if ingested_ns is not None and (time.time() - ingested_ns / 1e9) >= MAX_AGE_S:
                    raise RetryExhausted(code, last)
                log.warning("%s: %s failed (%s); blocking, retry in %.2fs", rec_label, code, last, backoff)
                self.sleep(backoff * (0.75 + random.random() / 2))
                backoff = min(BACKOFF_MAX_S, backoff * 2)

    def sys_step(self, fn):
        """A step with no age horizon (dead-letter produce, enriched produce): retried until it works."""
        return self.step(fn, "systemic", None)

    # ---- dead letter

    def dead_letter(self, ev, raw, code, message, initial, props=None):
        d = {"error_code": code, "error_message": message, "initial_error_message": initial,
             "failed_at": datetime.now(timezone.utc).isoformat(timespec="microseconds")}
        if ev is not None:
            copy = core.event_copy(ev)
            if props is not None:
                copy["properties"] = props
            d["event"] = copy
            if not ev["transaction_id"] and not COMPAT:
                d["raw_event"] = raw.decode("utf-8", errors="replace")
        else:
            d["raw_event"] = raw.decode("utf-8", errors="replace")
        payload = core.canon(d, PROFILE).encode("utf-8", errors="replace")
        if COMPAT:
            try:
                self.out.send(self.cfg.dlq_topic, None, payload)
                self.stats["dead"] += 1
            except (ProduceRejected, Transient) as e:
                log.error("dead-letter produce failed (compat: dropped): %s", e)
            return
        while True:
            try:
                self.sys_step(lambda: self.out.send(self.cfg.dlq_topic, None, payload))
                break
            except ProduceRejected as e:
                # dead-letter produce refused: SYSTEMIC, never skip the record
                log.error("dead-letter produce rejected (%s); blocking", e)
                self.sleep(BACKOFF_MAX_S)
        self.stats["dead"] += 1

    # ---- one record

    def process(self, raw):
        """Returns True when the record has a durable disposition, False when (compat only) it stays
        unprocessed."""
        try:
            ev = core.decode(raw, PROFILE)
        except core.Undecodable as e:
            if COMPAT:
                return True  # reference: nothing produced, committed
            self.dead_letter(None, raw, "decode_raw_event", "Error decoding raw event", str(e))
            return True
        try:
            t = core.parse_timestamp(ev["timestamp"], PROFILE)
        except core.NonFiniteTimestamp as e:
            if COMPAT:
                return True  # reference: nothing produced, committed
            self.dead_letter(ev, raw, "build_enriched_event", "Error while converting event to enriched event",
                             str(e))
            return True
        except core.InvalidTimestamp as e:
            self.dead_letter(ev, raw, "build_enriched_event", "Error while converting event to enriched event",
                             str(e))
            return True
        label = ev["transaction_id"]
        org, ext = ev["organization_id"], ev["external_subscription_id"]
        try:
            self.enrich(ev, raw, t, org, ext, label)
            return True
        except RetryExhausted as e:
            self.dead_letter(ev, raw, "retry_exhausted:" + e.code, "Retries exhausted for " + e.code, e.cause,
                             getattr(e, "props", None))
            return True
        except CompatFailure as e:
            ing = ev["ingested_ns"]
            if ing is not None and (time.time() - ing / 1e9) < MAX_AGE_S:
                return False
            self.dead_letter(ev, raw, e.code, ERROR_TEXT.get(e.code, ""), e.cause, getattr(e, "props", None))
            return True

    def sub_lookup(self, org, ext, t_ns):
        """Subscription at an instant. Corrected: ms (both bounds are truncated in SQL). Compat: the event
        time keeps its sub-millisecond digits (wall clock, EP-D4)."""
        us = t_ns // 1000 if COMPAT else t_ns // core.MS_NS * 1000
        return self.catalog.subscription(org, ext, us)

    def enrich(self, ev, raw, t, org, ext, label):
        ing = ev["ingested_ns"]
        try:
            m = self.step(lambda: self.catalog.metric(org, ev["code"]), "fetch_billable_metric", ing, label)
        except Permanent as e:
            self.dead_letter(ev, raw, "fetch_billable_metric", "Error fetching billable metric", str(e))
            return
        if m is None:
            self.dead_letter(ev, raw, "fetch_billable_metric", "Error fetching billable metric",
                             "record not found")
            return
        metric_id, agg, recurring, field, expression = m
        props = ev["properties"]
        if expression and expression.strip() and ev["source"] != "http_ruby":
            try:
                result = expr.evaluate(expression, ev["code"], t["emitted_text"], props, not COMPAT)
            except (expr.EvalError, expr.ParseError) as e:
                self.dead_letter(ev, raw, "evaluate_expression", "Error evaluating custom expression",
                                 "expression %r failed: %s" % (expression, e), props)
                return
            props = dict(props)
            props[field] = result
        value = core.value_text(agg, field, props, PROFILE)
        # subscription
        try:
            sub = self.step(lambda: self.sub_lookup(org, ext, t["wall_ns"] if COMPAT else t["match_ns"]),
                            "fetch_subscription", ing, label)
            if sub is None and recurring:
                now_ns = now_utc_ns()
                sub = self.step(lambda: self.sub_lookup(org, ext, now_ns), "fetch_subscription", ing, label)
        except Permanent as e:
            self.dead_letter(ev, raw, "fetch_subscription", "Error fetching subscription", str(e), props)
            return
        except (RetryExhausted, CompatFailure) as e:
            e.props = props
            raise
        sub_id, plan_id = (str(sub[0]), str(sub[1])) if sub else ("", "")
        enriched = {
            "organization_id": org, "external_subscription_id": ext, "subscription_id": sub_id,
            "plan_id": plan_id, "transaction_id": ev["transaction_id"], "code": ev["code"],
            "aggregation_type": core.label_of(agg), "properties": props,
            "precise_total_amount_cents": ev["precise_total_amount_cents"], "value": value,
            "timestamp": core.Raw(t["emitted_text"]),
        }
        if ev["source"]:
            enriched["source"] = ev["source"]
        payload = core.canon(enriched, PROFILE).encode("utf-8", errors="replace")
        key = ("%s-%s" % (org, ev["transaction_id"])).encode("utf-8", errors="replace")
        due_advance = bool(sub) and not (ev["source"] == "http_ruby" and ev["post_processed"])
        if COMPAT:
            return self.deliver_compat(ev, raw, props, org, sub_id, plan_id, metric_id, key, payload, due_advance,
                                       label)
        try:
            self.sys_step(lambda: self.out.send(self.cfg.enriched_topic, key, payload))
        except ProduceRejected as e:
            self.dead_letter(ev, raw, "produce_rejected", "Enriched record rejected by the broker", str(e), props)
            return
        self.stats["enriched"] += 1
        if not due_advance:
            return
        try:
            adv = self.step(lambda: self.catalog.has_advance_charge(org, plan_id, str(metric_id)),
                            "fetch_pay_in_advance_charge", ing, label)
            if adv:
                self.sys_step(lambda: self.send_advance(key, payload))
                self.stats["advance"] += 1
            self.step(lambda: self.flag.write(org, sub_id), "flag_subscription_refresh", ing, label)
        except Permanent as e:
            self.dead_letter(ev, raw, "fetch_pay_in_advance_charge", "Error fetching pay in advance charge",
                             str(e), props)
        except RetryExhausted as e:
            e.props = props
            raise

    def deliver_compat(self, ev, raw, props, org, sub_id, plan_id, metric_id, key, payload, due_advance, label):
        """Reference delivery: no retries; a rejected enriched produce gives a dead letter with an empty code
        and the in-advance record is still produced; a rejected in-advance produce gives enriched + dead letter."""
        ing = ev["ingested_ns"]
        enriched_ok = True
        try:
            self.out.send(self.cfg.enriched_topic, key, payload)
            self.stats["enriched"] += 1
        except (ProduceRejected, Transient) as e:
            enriched_ok = False
            self.dead_letter(ev, raw, "", "", "failed to push to %s topic" % self.cfg.enriched_topic, props)
        if not due_advance:
            return
        try:
            adv = self.step(lambda: self.catalog.has_advance_charge(org, plan_id, str(metric_id)),
                            "fetch_pay_in_advance_charge", ing, label)
        except Permanent as e:
            adv = False
        except CompatFailure as e:
            e.props = props
            raise
        if adv:
            try:
                self.out.send(self.cfg.advance_topic, key, payload)
                self.stats["advance"] += 1
            except (ProduceRejected, Transient) as e:
                self.dead_letter(ev, raw, "", "", "failed to push to %s topic" % self.cfg.advance_topic, props)
        try:
            self.step(lambda: self.flag.write(org, sub_id), "flag_subscription_refresh", ing, label)
        except CompatFailure as e:
            e.props = props
            raise

    def send_advance(self, key, payload):
        try:
            self.out.send(self.cfg.advance_topic, key, payload)
        except ProduceRejected as e:
            # never dead-letter an event whose enriched record exists: treat as systemic and retry
            raise Transient(str(e))


class RetryExhausted(Exception):
    def __init__(self, code, cause):
        super().__init__(code)
        self.code, self.cause = code, cause


class CompatFailure(Exception):
    def __init__(self, code, cause):
        super().__init__(code)
        self.code, self.cause = code, cause


ERROR_TEXT = {
    "fetch_billable_metric": "Error fetching billable metric",
    "fetch_subscription": "Error fetching subscription",
    "fetch_pay_in_advance_charge": "Error fetching pay in advance charge",
    "flag_subscription_refresh": "Error flagging subscription refresh",
}


# ------------------------------------------------------------------ main loop

def run():
    logging.basicConfig(level=logging.DEBUG if os.environ.get("ENV", "development") in ("", "development")
                        else logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")
    log.setLevel(logging.INFO)
    try:
        cfg = Config()
        log.info("starting events-processor (DB mode, corrected profile) group=%s", cfg.group)
        out = Out(cfg)
        out.check()
        catalog = Catalog(cfg.database_url)
        catalog.query_one("SELECT 1", ())
        flag = Flag(cfg)
        try:
            flag.ping()
        except Exception as e:
            raise Fatal("redis check failed: %s" % e)
    except Fatal as e:
        log.error("fatal: %s", e)
        return 2
    except Exception as e:
        log.error("fatal startup error: %s", e)
        return 2

    from confluent_kafka import Consumer, KafkaError, TopicPartition

    conf = kafka_conf(cfg)
    conf.update({"group.id": cfg.group, "enable.auto.commit": False, "auto.offset.reset": "earliest",
                 "max.poll.interval.ms": 3600000, "session.timeout.ms": 10000})
    consumer = Consumer(conf)
    consumer.subscribe([cfg.raw_topic])
    proc = Processor(cfg, catalog, out, flag)

    def on_signal(signum, frame):
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    def commit(progress):
        if not progress:
            return
        offs = [TopicPartition(t, p, o) for (t, p), o in progress.items()]
        for attempt in range(5):
            try:
                consumer.commit(offsets=offs, asynchronous=False)
                return
            except Exception as e:
                log.warning("commit failed: %s", e)
                time.sleep(0.2 * (attempt + 1))

    status = 0
    try:
        while not stop.is_set():
            msgs = consumer.consume(BATCH, 0.5)
            results = {}  # (topic, partition) -> [{"offset", "processed"}]
            try:
                for m in msgs:
                    if m.error():
                        if m.error().code() != KafkaError._PARTITION_EOF:
                            log.warning("consumer error: %s", m.error())
                        continue
                    if stop.is_set():
                        break
                    ok = proc.process(m.value() or b"")
                    results.setdefault((m.topic(), m.partition()), []).append(
                        {"offset": m.offset(), "processed": ok})
            except Shutdown:
                pass
            progress = {}
            for tp, recs in results.items():
                off = core.commit_offset(recs, None, PROFILE)
                if off is not None:
                    progress[tp] = off
            commit(progress)
    except Exception:
        log.exception("unexpected failure")
        status = 1
    finally:
        try:
            consumer.close()
        except Exception:
            pass
        catalog.close()
    log.info("stopped: %s", proc.stats)
    return status


if __name__ == "__main__":
    sys.exit(run())
