"""Event ingestion (BE-EV): timestamps, validation, batches, raw message."""
import re
from datetime import datetime, timedelta, timezone
from fractions import Fraction

import expr as X

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
ABSENT = object()
WS = ' \t\n\r\f\v'
TS_RE = re.compile(r'^([+-]?)(?:(\d+(?:_\d+)*)(?:\.(\d+(?:_\d+)*)?)?|\.(\d+(?:_\d+)*))(?:[eE]([+-]?\d+))?_?$')
LIMIT = 253402300800  # seconds, year 10000 (datetime range)


class InvalidFormat(Exception):
    pass


def parse_instant(text):
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def to_seconds(dt):
    d = dt - EPOCH
    return Fraction(d.days * 86400 + d.seconds) + Fraction(d.microseconds, 10 ** 6)


def fmt_instant(secs, digits=None):
    """secs: Fraction. digits None -> up to 6, trailing zeros trimmed; int -> exactly that many."""
    us = (secs * 10 ** 6).__floor__()
    if digits is not None:
        us = us // 10 ** (6 - digits) * 10 ** (6 - digits)
    days, rem = divmod(us, 86400 * 10 ** 6)
    s, frac = divmod(rem, 10 ** 6)
    dt = EPOCH + timedelta(days=days, seconds=s)
    base = '%04d-%02d-%02dT%02d:%02d:%02d' % (dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
    fs = '%06d' % frac
    fs = fs[:digits] if digits is not None else fs.rstrip('0')
    return base + ('.' + fs if fs else '') + 'Z'


def ts_text(v):
    """Text of a scalar timestamp value, or None for invalid; ABSENT -> use reception time."""
    if v is None or v is False or v is ABSENT or isinstance(v, (dict, list)):
        return ABSENT
    if v is True:
        raise InvalidFormat
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return X.ruby_float_text(v)
    return v


def parse_seconds(text):
    t = text.strip(WS)
    m = TS_RE.match(t)
    if not m:
        raise InvalidFormat
    sign, ip, fp, fp2, ex = m.groups()
    if ip is None:
        ip, fp = '', fp2
    ip = (ip or '').replace('_', '')
    fp = (fp or '').replace('_', '')
    if ex and abs(int(ex)) > 1000:
        raise InvalidFormat
    val = Fraction(int((ip + fp) or '0'), 10 ** len(fp))
    if ex:
        val *= Fraction(10) ** int(ex)
    if sign == '-':
        val = -val
    if val >= LIMIT or val < -62135596800:
        raise InvalidFormat
    return val


def event_time(ts, received):
    t = ts_text(ts)
    if t is ABSENT:
        return received
    return parse_seconds(t)


def text_member(v):
    if v is None or isinstance(v, (dict, list)):
        return None
    if v is True:
        return 't'
    if v is False:
        return 'f'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return X.ruby_float_text(v)
    return v


PREC_RE = re.compile(r'^[ \t\n\r\f\v]*([+-]?(?:\d+(?:_\d+)*(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)')


def dec_round15(fr):
    scaled = fr * 10 ** 15
    q = abs(scaled).__floor__()
    if abs(scaled) - q >= Fraction(1, 2):
        q += 1
    return Fraction(-q if fr < 0 else q, 10 ** 15)


def precise(v):
    """-> Fraction or None."""
    if v is None or isinstance(v, (dict, list)):
        return None
    if v is True:
        return Fraction(1)
    if v is False:
        return Fraction(0)
    if isinstance(v, int):
        return dec_round15(Fraction(v))
    if isinstance(v, float):
        n = X.parse_num(X.ruby_float_text(v))
        return dec_round15(Fraction(n.c) * Fraction(10) ** (-n.s))
    if v == '':
        return None
    m = PREC_RE.match(v)
    if not m:
        return Fraction(0)
    n = X.parse_num(m.group(1).replace('_', ''))
    if n is None or abs(n.s) > 10000:
        return Fraction(0)
    return dec_round15(Fraction(n.c) * Fraction(10) ** (-n.s))


def fr_text(fr):
    """plain decimal text with >= 1 fractional digit (BE-EV-62)."""
    neg = fr < 0
    fr = abs(fr)
    ip = fr.__floor__()
    frac = fr - ip
    digits = ''
    while frac:
        frac *= 10
        d = frac.__floor__()
        digits += str(d)
        frac -= d
    return ('-' if neg and (ip or digits) else '') + str(ip) + '.' + (digits or '0')


class Rejected(Exception):
    def __init__(self, status, details=None):
        self.status = status
        self.details = details


def blank(v):
    return v is None or (isinstance(v, str) and v.strip() == '')


def find_metric(metrics, code):
    for m in metrics or []:
        if m.get('deleted'):
            continue
        if m.get('code') == code and (m.get('expression') or '').strip():
            return m
    return None


def prop_value(v):
    """JSON value -> expression value (rails surface)."""
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if v is None:
        return ''
    if isinstance(v, int):
        return X.Num(v, 0)
    if isinstance(v, float):
        return X.parse_num(X.ruby_float_text(v))
    if isinstance(v, str):
        return v
    return X.ruby_inspect(v)


def run_expression(expression, code, secs, props, profile):
    """Evaluate on the ingestion surface; returns the text for properties."""
    try:
        node = X.parse(expression)
    except X.ParseError:
        raise Rejected(422, 'expression_evaluation_failed: invalid expression')
    if secs < 0 and profile == 'compat':
        raise Rejected(500)
    if profile == 'corrected':
        ms = (secs * 1000).__floor__()
        ts = X.Num(ms, 3)
    else:
        ts = X.Num(secs.__floor__(), 0)
    ev = {'code': code if code is not None else '', 'timestamp': ts,
          'properties': {k: prop_value(v) for k, v in props.items()}}
    try:
        r = X.evaluate(node, ev, False)
    except X.DivZero as e:
        if profile == 'compat':
            raise Rejected(500)
        raise Rejected(422, 'expression_evaluation_failed: ' + str(e))
    except X.EvalError as e:
        raise Rejected(422, 'expression_evaluation_failed: ' + str(e))
    # strings from property conversion are converted lazily; results of properties stay as evaluated
    return r if isinstance(r, str) else X.stored_text(r)


def normalise(ev, received, metrics, profile):
    """Time + expression for one event. Returns dict with fields or raises Rejected.
    Rejected(422, {'timestamp': [...]}) for time errors; text for expression failures."""
    if not isinstance(ev, dict):
        ev = {}
    tid = text_member(ev.get('transaction_id'))
    code = text_member(ev.get('code'))
    sub = text_member(ev.get('external_subscription_id'))
    props = ev.get('properties')
    props = dict(props) if isinstance(props, dict) else {}
    try:
        secs = event_time(ev.get('timestamp', ABSENT), received)
    except InvalidFormat:
        raise Rejected(422, {'timestamp': ['invalid_format']})
    out = {'transaction_id': tid, 'code': code, 'external_subscription_id': sub, 'secs': secs,
           'properties': props, 'precise': precise(ev.get('precise_total_amount_cents'))}
    m = find_metric(metrics, code)
    if m:
        try:
            props[m.get('field_name') or 'value'] = run_expression(m['expression'], code, secs, props, profile)
        except Rejected as r:
            out['expr_error'] = r
    return out


def presence(o):
    d = {}
    if blank(o['transaction_id']):
        d['transaction_id'] = ['value_is_mandatory']
    if blank(o['code']):
        d['code'] = ['value_is_mandatory']
    return d


def stored(o):
    return {'transaction_id': o['transaction_id'], 'code': o['code'],
            'external_subscription_id': o['external_subscription_id'],
            'timestamp': fmt_instant(o['secs']), 'properties': o['properties'],
            'precise_total_amount_cents': None if o['precise'] is None else fr_text(o['precise'])}


def validates_ch(profile):
    return profile == 'corrected'


def validate(inp, profile):
    store, ev = inp['store'], inp.get('event')
    if not isinstance(ev, dict) or not ev:
        return {'ok': False, 'http_status': 400}
    received = to_seconds(parse_instant(inp['received_at']))
    try:
        o = normalise(ev, received, inp.get('metrics'), profile)
    except Rejected as r:
        return {'ok': False, 'http_status': r.status, 'error_details': r.details} if r.details is not None \
            else {'ok': False, 'http_status': r.status}
    if 'expr_error' in o:
        r = o['expr_error']
        res = {'ok': False, 'http_status': r.status}
        if r.details is not None:
            res['error_details'] = r.details
        return res
    if store == 'pg' or validates_ch(profile):
        p = presence(o)
        if p:
            return {'ok': False, 'http_status': 422, 'error_details': p}
        sub = o['external_subscription_id']
        if sub is not None:
            for e in inp.get('existing') or []:
                if e.get('external_subscription_id') == sub and e.get('transaction_id') == o['transaction_id']:
                    return {'ok': False, 'http_status': 422,
                            'error_details': {'transaction_id': ['value_already_exist']}}
    return {'ok': True, 'http_status': 200, 'persisted': store == 'pg', 'stored_event': stored(o),
            'echo_timestamp': fmt_instant(o['secs'], 3)}


def validate_batch(inp, profile):
    store = inp['store']
    evs = inp.get('events')
    if not isinstance(evs, list) or not evs:
        return {'ok': False, 'http_status': 422, 'error_details': {'events': ['no_events']}}
    if len(evs) > inp.get('max_length', 100):
        return {'ok': False, 'http_status': 422, 'error_details': {'events': ['too_many_events']}}
    received = to_seconds(parse_instant(inp['received_at']))
    errors, items = {}, []
    for i, ev in enumerate(evs):
        try:
            o = normalise(ev, received, inp.get('metrics'), profile)
        except Rejected as r:
            errors[str(i)] = r.details
            continue
        p = presence(o)
        if p:
            errors[str(i)] = p
        elif 'expr_error' in o:
            r = o['expr_error']
            if r.status == 500:
                return {'ok': False, 'http_status': 500}
            errors[str(i)] = r.details
        items.append(o)
    if errors:
        return {'ok': False, 'http_status': 422, 'error_details': errors}
    existing = inp.get('existing') or []
    if store == 'pg' and profile == 'compat':
        by_tx = {}
        for i, o in enumerate(items):
            by_tx.setdefault(o['transaction_id'], []).append(i)
        stored_tx = {e.get('transaction_id') for e in existing}
        for tx, idxs in by_tx.items():
            k = max(len(idxs) - 1, 1 if tx in stored_tx else 0)
            for i in idxs[len(idxs) - k:]:
                errors[str(i)] = {'transaction_id': ['value_already_exist']}
    elif store == 'pg' or profile == 'corrected':
        seen = {(e.get('external_subscription_id'), e.get('transaction_id'))
                for e in existing if e.get('external_subscription_id') is not None}
        for i, o in enumerate(items):
            sub = o['external_subscription_id']
            if sub is None:
                continue
            key = (sub, o['transaction_id'])
            if key in seen:
                errors[str(i)] = {'transaction_id': ['value_already_exist']}
            seen.add(key)
    if errors:
        errors = dict(sorted(errors.items(), key=lambda kv: int(kv[0])))
        return {'ok': False, 'http_status': 422, 'error_details': errors}
    return {'ok': True, 'http_status': 200, 'persisted': [store == 'pg'] * len(items),
            'stored_events': [stored(o) for o in items]}


def parse_timestamp(inp, profile):
    import json
    received = to_seconds(parse_instant(inp['received_at']))
    raw = inp.get('timestamp_json')
    v = ABSENT if raw is None else json.loads(raw)
    try:
        return {'timestamp': fmt_instant(event_time(v, received))}
    except InvalidFormat:
        return {'error': {'code': 'invalid_format', 'field': 'timestamp'}}


def raw_message(inp, profile):
    received = to_seconds(parse_instant(inp['ingested_at']))
    ev = inp.get('event')
    if not isinstance(ev, dict):
        ev = {}
    try:
        o = normalise(ev, received, inp.get('metrics'), profile)
    except Rejected:
        return {'error': {'code': 'invalid_format', 'field': 'timestamp'}}
    if 'expr_error' in o:
        return {'error': {'code': 'evaluation_error'}}
    ing = fmt_instant(received, 3)[:-1]
    msg = {'organization_id': inp['organization_id'], 'external_customer_id': None,
           'external_subscription_id': o['external_subscription_id'],
           'transaction_id': o['transaction_id'],
           'timestamp': X.ruby_float_text(float(o['secs'])),
           'code': o['code'],
           'precise_total_amount_cents': fr_text(o['precise'] if o['precise'] is not None else Fraction(0)),
           'properties': o['properties'], 'ingested_at': ing, 'source': 'http_ruby',
           'source_metadata': {'api_post_processed': inp['store'] == 'pg'}}
    return {'topic': 'events-raw', 'has_key': False, 'message': msg}


def duplicate_key(inp, profile):
    ev = inp.get('event') or {}
    sub = text_member(ev.get('external_subscription_id'))
    if sub is None or (inp['store'] == 'ch' and profile == 'compat'):
        return {'key_fields': None}
    return {'key_fields': ['external_subscription_id', 'transaction_id']}
