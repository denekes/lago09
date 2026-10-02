#!/usr/bin/env python3.12
"""Kit adapter (JSON lines) for the areas webhooks, api and clock. Standard library only."""
import base64
import hashlib
import hmac
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal

IMPL = "crc-8-webhooks-api-clock"


class DomainError(Exception):
    def __init__(self, code, field=None, message=None):
        super().__init__(code)
        self.code, self.field, self.message = code, field, message


# ---------------------------------------------------------------- JSON encoding (BE-WH-12)

_ESC = {'"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f', '\n': '\\n', '\r': '\\r', '\t': '\\t',
        '<': '\\u003c', '>': '\\u003e', '&': '\\u0026', ' ': '\\u2028', ' ': '\\u2029'}


def enc_str(s):
    out = ['"']
    for ch in s:
        e = _ESC.get(ch)
        if e is not None:
            out.append(e)
        elif ch < ' ':
            out.append('\\u%04x' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def enc_float(x):
    if x == 0:
        return '-0.0' if str(x).startswith('-') else '0.0'
    sign, digits, exp = Decimal(repr(x)).as_tuple()
    ds = ''.join(map(str, digits))
    k = exp
    stripped = ds.rstrip('0')
    k += len(ds) - len(stripped)
    ds = stripped
    n = len(ds)
    e = k + n - 1
    neg = '-' if sign else ''
    if k >= 0 and abs(e) < 15:
        body = ds + '0' * k + '.0'
    elif k < 0 and (k > -7 or abs(e) < 10):
        m = -k
        s = ds.rjust(m + 1, '0')
        body = s[:-m] + '.' + s[-m:]
    else:
        body = ds[0] + ('.' + ds[1:] if n > 1 else '') + 'e' + ('+' if e >= 0 else '-') + str(abs(e))
    return neg + body


def encode(v):
    if v is None:
        return 'null'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return enc_float(v)
    if isinstance(v, str):
        return enc_str(v)
    if isinstance(v, (list, tuple)):
        return '[' + ','.join(encode(i) for i in v) + ']'
    if isinstance(v, dict):
        return '{' + ','.join(enc_str(k) + ':' + encode(i) for k, i in v.items()) + '}'
    raise TypeError(type(v))


def parse_json(text):
    return json.loads(text, parse_float=float, parse_int=int)


# ---------------------------------------------------------------- RSA (pure python, RS256)

def _der(buf, pos=0):
    tag = buf[pos]
    ln = buf[pos + 1]
    pos += 2
    if ln & 0x80:
        nb = ln & 0x7f
        ln = int.from_bytes(buf[pos:pos + nb], 'big')
        pos += nb
    return tag, buf[pos:pos + ln], pos + ln


def _seq(buf):
    items, pos = [], 0
    while pos < len(buf):
        tag, val, pos = _der(buf, pos)
        items.append((tag, val))
    return items


def _der_len(n):
    if n < 128:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b


def _tlv(tag, val):
    return bytes([tag]) + _der_len(len(val)) + val


def _der_int(n):
    b = n.to_bytes(n.bit_length() // 8 + 1, 'big')
    return _tlv(2, b)


def load_private_key(pem):
    lines = [l for l in pem.strip().splitlines() if not l.startswith('-----')]
    der = base64.b64decode(''.join(lines))
    _, body, _ = _der(der)
    items = _seq(body)
    if len(items) >= 3 and items[2][0] == 4:  # PKCS#8: version, algorithm, octet string
        _, inner, _ = _der(items[2][1])
        items = _seq(inner)
    ints = [int.from_bytes(v, 'big') for t, v in items[:9]]
    return ints[1], ints[2], ints[3]  # n, e, d


def spki_pem(n, e):
    rsa_pub = _tlv(0x30, _der_int(n) + _der_int(e))
    alg = _tlv(0x30, _tlv(6, bytes.fromhex('2a864886f70d010101')) + _tlv(5, b''))
    spki = _tlv(0x30, alg + _tlv(3, b'\x00' + rsa_pub))
    b64 = base64.b64encode(spki).decode()
    return '-----BEGIN PUBLIC KEY-----\n' + ''.join(b64[i:i + 64] + '\n' for i in range(0, len(b64), 64)) + \
        '-----END PUBLIC KEY-----\n'


_SHA256_PREFIX = bytes.fromhex('3031300d060960864801650304020105000420')


def rs256(n, d, data):
    k = (n.bit_length() + 7) // 8
    t = _SHA256_PREFIX + hashlib.sha256(data).digest()
    em = b'\x00\x01' + b'\xff' * (k - len(t) - 3) + b'\x00' + t
    return pow(int.from_bytes(em, 'big'), d, n).to_bytes(k, 'big')


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


def jwt_escape(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\b':
            out.append('\\b')
        elif ch == '\f':
            out.append('\\f')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif ch < ' ':
            out.append('\\u%04x' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


# ---------------------------------------------------------------- webhooks catalogue

_OBJ = {}


def _add(names, obj):
    for n in names.split():
        _OBJ[n] = obj


_add('billable_metric.created billable_metric.updated billable_metric.deleted', 'billable_metric')
_add('plan.created plan.updated plan.deleted', 'plan')
_add('customer.created customer.updated', 'customer')
_add('subscription.started subscription.updated subscription.terminated subscription.canceled '
     'subscription.incomplete subscription.trial_ended subscription.termination_alert '
     'subscription.usage_threshold_reached', 'subscription')
_add('invoice.drafted invoice.created invoice.one_off_created invoice.paid_credit_added '
     'invoice.ready_to_finalize invoice.voided invoice.deleted invoice.payment_status_updated '
     'invoice.payment_overdue invoice.generated invoice.payment_failure invoice.resynced', 'invoice')
_add('invoice.payment_dispute_lost', 'payment_dispute_lost')
_add('fee.created fee.tax_provider_error', 'fee')
_add('credit_note.created credit_note.generated', 'credit_note')
_add('credit_note.provider_refund_failure', 'credit_note_payment_provider_refund_error')
_add('wallet.created wallet.updated wallet.terminated wallet.depleted_ongoing_balance', 'wallet')
_add('wallet_transaction.created wallet_transaction.updated wallet_transaction.payment_failure',
     'wallet_transaction')
_add('alert.triggered', 'triggered_alert')
_add('events.errors', 'events_errors')
_add('event.error', 'event_error')
# out-of-scope names (interface only); the kit lists them with wildcards, expansion is a guess (KIT-GAPS)
for _p in ('accounting', 'crm', 'payment'):
    for _s in ('created', 'error'):
        _OBJ['customer.%s_provider_%s' % (_p, _s)] = 'payment_provider_customer_error' if _s == 'error' else 'customer'
_add('customer.checkout_url_generated customer.tax_provider_error customer.vies_check', 'customer')
_add('integration.provider_error', 'provider_error')
_add('payment_provider.error', 'payment_provider_error')
_add('payment.requires_action payment.dispute_lost', 'payment')
_add('payment_receipt.created payment_receipt.generated', 'payment_receipt')
_add('payment_request.created payment_request.payment_failure', 'payment_request')
_add('dunning_campaign.finished', 'dunning_campaign')
_add('feature.created feature.updated feature.deleted', 'feature')
_add('quote.created quote.updated quote.deleted', 'quote')
_add('order.created order.updated', 'order')
_add('order_form.created order_form.updated order_form.signed order_form.expired', 'order_form')

EMITTED_OVERRIDE = {'credit_note.provider_refund_failure': 'credit_note.refund_failure'}


def op_type_info(inp, profile):
    ev = inp['event']
    if ev not in _OBJ:
        raise DomainError('unknown_event_type', 'event')
    emitted = EMITTED_OVERRIDE.get(ev, ev) if profile != 'corrected' else ev
    return {'webhook_type': emitted, 'object_type': _OBJ[ev], 'configured': True}


def op_encode(inp, profile):
    return {'body': encode(parse_json(inp['payload_json'])), 'content_type': 'application/json'}


def op_payload_envelope(inp, profile):
    env = {'webhook_type': inp['webhook_type'], 'object_type': inp['object_type'],
           'organization_id': inp['organization_id']}
    env[inp['object_type']] = parse_json(inp['object_json'])
    return {'body': encode(env), 'webhook_type': inp['webhook_type'], 'status': 'pending'}


def op_sign(inp, profile):
    algo, body = inp['algorithm'], inp['body']
    uid = inp.get('webhook_id', '00000000-0000-4000-8000-000000000000')
    headers = {'Content-Type': 'application/json'}
    if algo == 'hmac':
        sig = base64.b64encode(hmac.new(inp['hmac_key'].encode(), body.encode(), hashlib.sha256).digest()).decode()
    else:
        n, _e, d = load_private_key(inp['rsa_private_key_pem'])
        iss = inp.get('iss', 'https://api.lago.dev')
        claims = '{"data":' + jwt_escape(body) + ',"iss":' + jwt_escape(iss) + '}'
        signing = b64u(b'{"alg":"RS256"}') + '.' + b64u(claims.encode())
        sig = signing + '.' + b64u(rs256(n, d, signing.encode()))
    headers['X-Lago-Signature'] = sig
    headers['X-Lago-Signature-Algorithm'] = algo
    headers['X-Lago-Unique-Key'] = uid
    return {'signature': sig, 'headers': headers, 'body': body}


def op_public_key(inp, profile):
    n, e, _d = load_private_key(inp['rsa_private_key_pem'])
    b64 = base64.b64encode(spki_pem(n, e).encode()).decode()
    text = ''.join(b64[i:i + 60] + '\n' for i in range(0, len(b64), 60))
    return {'text': text, 'json_body': encode({'webhook': {'public_key': text}}),
            'text_content_type': 'text/plain'}


def op_retry_step(inp, profile):
    before = inp['retries_before']
    attempts = inp.get('attempts', 3)
    out = inp['outcome']
    status = out.get('http_status')
    if status in (200, 201, 202, 204):
        return {'status': 'succeeded', 'retries': before, 'http_status': status,
                'retry_scheduled': False, 'wait_seconds': None}
    r = before + 1
    retrying = r < attempts
    res = {'status': 'retrying' if retrying else 'failed', 'retries': r, 'http_status': status,
           'retry_scheduled': retrying, 'wait_seconds': None}
    if retrying:
        r4 = r ** 4
        mx = Decimal(r4) * Decimal('1.15') + 2
        res['wait_seconds'] = {'min': str(r4 + 2), 'max': format(mx.normalize(), 'f')}
    return res


def _normalize_list(items):
    out = []
    for x in items:
        if x is None:
            continue
        if isinstance(x, bool):
            t = 'true' if x else 'false'
        elif isinstance(x, str):
            t = x
        else:
            t = encode(x)
        t = t.strip().lower()
        if t and t not in out:
            out.append(t)
    return out


def _pg_array(s):
    s = s.strip()
    if not (s.startswith('{') and s.endswith('}')):
        return []
    inner = s[1:-1]
    items, cur, q, i = [], '', False, 0
    while i < len(inner):
        c = inner[i]
        if q:
            if c == '\\' and i + 1 < len(inner):
                i += 1
                cur += inner[i]
            elif c == '"':
                q = False
            else:
                cur += c
        elif c == '"':
            q = True
        elif c == ',':
            items.append(cur.strip())
            cur = ''
        else:
            cur += c
        i += 1
    items.append(cur.strip())
    return [x for x in items if x != ''] if inner.strip() else []


def op_normalize_event_types(inp, profile):
    v = parse_json(inp['event_types_json'])
    if v is None:
        return {'valid': True, 'stored': None}
    if isinstance(v, bool) or isinstance(v, (int, float)):
        raise DomainError('server_error')
    if isinstance(v, str):
        items = _pg_array(v)
        if not items:
            return {'valid': False, 'errors': {'event_types': ['must_be_array']}}
        v = items
    if not isinstance(v, list):
        return {'valid': False, 'errors': {'event_types': ['must_be_array']}}
    norm = _normalize_list(v)
    if norm == ['*']:
        return {'valid': True, 'stored': None}
    bad = [x for x in norm if x not in _OBJ]
    if bad:
        msg = 'contains invalid types: [' + ', '.join(enc_str(x) for x in bad) + ']'
        return {'valid': False, 'errors': {'event_types': [msg]}}
    return {'valid': True, 'stored': norm}


def op_endpoint_receives(inp, profile):
    et = inp['event_types']
    return {'receives': True if et is None else inp['webhook_type'] in et}


# ---------------------------------------------------------------- api

def op_auth_token(inp, profile):
    parts = (inp.get('authorization') or '').split()
    if profile == 'corrected':
        return {'token': parts[1] if len(parts) >= 2 and parts[0] == 'Bearer' else None}
    return {'token': parts[1] if len(parts) >= 2 else None}


def op_authorize(inp, profile):
    mode = 'read' if inp['method'] == 'GET' else 'write'
    if inp.get('premium') and 'api_permissions' in (inp.get('premium_integrations') or []):
        perms = inp.get('permissions')
        if perms is not None and mode not in (perms.get(inp['resource']) or []):
            body = {'status': 403, 'error': 'Forbidden',
                    'code': '%s_action_not_allowed_for_%s' % (mode, inp['resource'])}
            return {'allowed': False, 'http_status': 403, 'body_json': encode(body)}
    return {'allowed': True}


_INVOICE_KEYS = ['amount_from', 'amount_to', 'currency', 'invoice_type', 'issuing_date_from', 'issuing_date_to',
                 'partially_paid', 'payment_dispute_lost', 'payment_overdue', 'payment_status',
                 'payment_statuses', 'per_page', 'purchase_order_number', 'search_term', 'self_billed',
                 'settlements', 'status', 'statuses']
_FEE_KEYS = ['fee_type', 'payment_status', 'external_subscription_id', 'external_customer_id',
             'billable_metric_code', 'currency', 'event_transaction_id', 'created_at_from', 'created_at_to',
             'failed_at_from', 'failed_at_to', 'succeeded_at_from', 'succeeded_at_to', 'refunded_at_from',
             'refunded_at_to', 'succeeded_at_from', 'refunded_at_to']


def _pairs(v):
    if isinstance(v, dict):
        return [[k, _pairs(v[k])] for k in sorted(v)]
    return v


def op_count_cache_key(inp, profile):
    query = inp.get('query') or {}
    kind = 'fees' if inp['index'] == 'fees' else 'invoices'
    params = {}
    if kind == 'invoices':
        for k in _INVOICE_KEYS:
            if k in query and not isinstance(query[k], (list, dict)):
                params[k] = query[k]
        if isinstance(query.get('metadata'), dict):
            params['metadata'] = query['metadata']
    else:
        for k in _FEE_KEYS:
            if k in query and not isinstance(query[k], (list, dict)):
                params[k] = query[k]
        params['per_page'] = query.get('per_page')
    params.pop('page', None)
    params['organization_id'] = inp['organization_id']
    pre = encode(_pairs(params))
    key = 'pagination_count/%s/%s' % (kind, hashlib.sha256(pre.encode()).hexdigest())
    return {'key': key, 'preimage': pre}


_LEN_INT = re.compile(r'^\s*([+-]?\d+(?:_\d+)*)')


def _to_i(v):
    m = _LEN_INT.match(str(v))
    return int(m.group(1).replace('_', '')) if m else 0


def op_pagination_meta(inp, profile):
    total = inp['total_count']
    page_raw, pp_raw = inp.get('page'), inp.get('per_page')
    page = _to_i(page_raw) if page_raw is not None else 1
    if page < 1:
        page = 1
    if pp_raw is None:
        per = 100
    else:
        s = str(pp_raw)
        per = _to_i(s) if s[:1].isdigit() else 25
    cached = inp.get('cached_count')
    if cached is not None:
        rp = _to_i(page_raw) if page_raw is not None else 1
        rpp = _to_i(pp_raw) if pp_raw is not None else 100
        if cached > rpp * rp:
            eff = cached
        else:
            eff = total
    else:
        eff = total
    if eff <= 0:
        return {'meta': {'current_page': 0, 'next_page': None, 'prev_page': None, 'total_pages': 0,
                         'total_count': eff}, 'items': 0}
    if per == 0:
        if profile == 'corrected':
            raise DomainError('value_is_invalid', 'per_page')
        raise DomainError('server_error')
    pages = -(-eff // per)
    meta = {'current_page': page, 'next_page': page + 1 if page < pages else None,
            'prev_page': page - 1 if page > 1 else None, 'total_pages': pages, 'total_count': eff}
    items = max(0, min(per, total - (page - 1) * per))
    return {'meta': meta, 'items': items}


def op_error_body(inp, profile):
    f = inp['failure']
    t = f['type']
    if t == 'not_found':
        st, body = 404, {'status': 404, 'error': 'Not Found', 'code': f['resource'] + '_not_found'}
    elif t == 'method_not_allowed':
        st, body = 405, {'status': 405, 'error': 'Method Not Allowed', 'code': f['code']}
    elif t == 'validation':
        st, body = 422, {'status': 422, 'error': 'Unprocessable Entity', 'code': 'validation_errors',
                         'error_details': f['messages']}
    elif t == 'single_validation':
        st, body = 422, {'status': 422, 'error': 'Unprocessable Entity', 'code': 'validation_errors',
                         'error_details': {f.get('field') or 'base': [f['code']]}}
    elif t == 'forbidden':
        st, body = 403, {'status': 403, 'error': 'Forbidden', 'code': f.get('code') or 'feature_unavailable'}
    elif t == 'unauthorized':
        st, body = 401, {'status': 401, 'error': f.get('message') or 'unauthorized'}
    elif t == 'lock_acquisition':
        st, body = 422, {'status': 422, 'error': 'Unprocessable Entity',
                         'code': f.get('code') or 'lock_acquisition_failed'}
    elif t == 'third_party':
        st, body = 422, {'status': 422, 'error': 'Unprocessable Entity', 'code': 'third_party_error',
                         'error_details': {'third_party': f['third_party'], 'thirdparty_error': f['message']}}
    elif t == 'too_many_provider_requests':
        st, body = 429, {'status': 429, 'error': 'Too Many Provider Requests',
                         'code': 'too_many_provider_requests',
                         'error_details': {'provider_name': f['provider_name'], 'message': f['message']}}
    elif t == 'missing_root':
        st, body = 400, {'status': 400, 'error':
                         'BadRequest: param is missing or the value is empty or invalid: ' + f['param']}
    elif t == 'unauthenticated':
        st, body = 401, {'status': 401, 'error': 'Unauthorized'}
    elif t == 'route_not_found':
        st, body = 404, {'status': 404, 'error': 'Not Found', 'code': 'resource_not_found'}
    elif t == 'service':
        raise DomainError('server_error')
    else:
        raise DomainError('bad_input')
    return {'http_status': st, 'body_json': encode(body)}


# ---------------------------------------------------------------- clock

def instant(s):
    d = datetime.fromisoformat(s.replace('Z', '+00:00'))
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(timezone.utc)


def op_idempotency_key(inp, profile):
    def txt(v):
        if v is None:
            return ''
        if v is True:
            return 'true'
        if v is False:
            return 'false'
        return str(v)
    parts = inp['parts']
    pre = 'v1|' + '|'.join(k + txt(parts[k]) for k in sorted(parts, key=lambda k: k.encode()))
    return {'preimage': pre, 'sha256_hex': hashlib.sha256(pre.encode()).hexdigest()}


def op_termination_alert_due(inp, profile):
    now = instant(inp['now'])
    days = inp.get('days') or [15, 45]
    targets = {(now + timedelta(days=d)).date() for d in days}
    sent = {a['subscription'] for a in inp.get('alerts_sent', [])
            if instant(a['created_at']).date() == now.date()}
    due = []
    for s in inp['subscriptions']:
        if s.get('status', 'active') != 'active' or not s.get('ending_at') or s['id'] in sent:
            continue
        if instant(s['ending_at']).date() in targets:
            due.append(s['id'])
    return {'due': due}


def _truthy(v):
    return v is not None and str(v).strip().lower() in ('true', '1', 'yes', 'on')


def _period(env, key, default):
    try:
        v = int(str(env.get(key, '')).strip())
        return v if v > 0 else default
    except ValueError:
        return default


_PINNED = [('terminate_ended_subscriptions', 5), ('post_validate_events', 5), ('bill_customers', 10),
           ('expire_incomplete_subscriptions', 20), ('finalize_invoices', 20),
           ('mark_invoices_as_payment_overdue', 25), ('retry_generating_subscription_invoices', 30),
           ('terminate_coupons', 30), ('bill_ended_trial_subscriptions', 35), ('terminate_wallets', 45),
           ('termination_alert', 50), ('terminate_expired_wallet_transaction_rules', 50),
           ('top_up_wallet_interval_credits', 55)]


def op_jobs_due(inp, profile):
    t0, t1 = instant(inp['from']), instant(inp['to'])
    env = inp.get('env') or {}
    span = (t1 - t0).total_seconds()
    intervals = {'activate_subscriptions': 300, 'refresh_draft_invoices': 300, 'retry_failed_invoices': 900,
                 'process_subscription_activity':
                     _period(env, 'LAGO_SUBSCRIPTION_ACTIVITY_PROCESSING_INTERVAL_SECONDS', 60)}
    if not _truthy(env.get('LAGO_DISABLE_LIFETIME_USAGE_REFRESH')):
        intervals['refresh_lifetime_usages'] = _period(env, 'LAGO_LIFETIME_USAGE_REFRESH_INTERVAL_SECONDS', 300)
    cache = bool(env.get('LAGO_MEMCACHE_SERVERS') or env.get('LAGO_REDIS_CACHE_URL'))
    if not _truthy(env.get('LAGO_DISABLE_WALLET_REFRESH')) and (cache or profile == 'corrected'):
        intervals['refresh_wallets_ongoing_balance'] = \
            _period(env, 'LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS', 300)
    if env.get('LAGO_REDIS_STORE_URL') and _truthy(env.get('LAGO_CLICKHOUSE_ENABLED')):
        intervals['refresh_flagged_subscriptions'] = 10
    runs = {}
    if span > 0:
        for name, p in intervals.items():
            runs[name] = -(-int(span * 1000) // (p * 1000))
    first_min = t0.replace(second=0, microsecond=0)
    first_hour = first_min.replace(minute=0)
    pinned = list(_PINNED)
    if _truthy(env.get('LAGO_DISABLE_EVENTS_VALIDATION')):
        pinned = [p for p in pinned if p[0] != 'post_validate_events']
    h = first_hour
    while h < t1:
        for name, m in pinned:
            slot = h + timedelta(minutes=m)
            if first_min <= slot < t1:
                runs[name] = runs.get(name, 0) + 1
        slot = h
        if h.hour == 1 and first_min <= slot < t1:
            runs['clean_webhooks'] = runs.get('clean_webhooks', 0) + 1
        h += timedelta(hours=1)
    return {'runs': {k: v for k, v in runs.items() if v > 0}}


OPS = {
    'webhooks.encode': op_encode, 'webhooks.payload_envelope': op_payload_envelope, 'webhooks.sign': op_sign,
    'webhooks.public_key': op_public_key, 'webhooks.retry_step': op_retry_step,
    'webhooks.normalize_event_types': op_normalize_event_types,
    'webhooks.endpoint_receives': op_endpoint_receives, 'webhooks.type_info': op_type_info,
    'api.auth_token': op_auth_token, 'api.authorize': op_authorize, 'api.count_cache_key': op_count_cache_key,
    'api.error_body': op_error_body, 'api.pagination_meta': op_pagination_meta,
    'clock.idempotency_key': op_idempotency_key, 'clock.jobs_due': op_jobs_due,
    'clock.termination_alert_due': op_termination_alert_due,
}


def handle(req):
    rid = req.get('id')
    fn = OPS.get('%s.%s' % (req.get('area'), req.get('op')))
    if fn is None:
        return {'type': 'result', 'id': rid, 'error': {'code': 'unsupported_op'}}
    try:
        return {'type': 'result', 'id': rid, 'output': fn(req.get('input') or {}, req.get('profile', 'compat'))}
    except DomainError as e:
        err = {'code': e.code}
        if e.field:
            err['field'] = e.field
        return {'type': 'result', 'id': rid, 'error': err}
    except (KeyError, TypeError, ValueError) as e:
        return {'type': 'result', 'id': rid, 'error': {'code': 'bad_input', 'message': repr(e)}}
    except Exception as e:  # noqa
        return {'type': 'result', 'id': rid, 'error': {'code': 'internal', 'message': repr(e)}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        t = req.get('type')
        if t == 'hello':
            out = {'type': 'hello', 'proto': 1, 'impl': IMPL, 'impl_version': '1.0.0',
                   'profiles': ['compat', 'corrected'], 'ops': ['webhooks.*', 'api.*', 'clock.*']}
        elif t == 'bye':
            return
        else:
            out = handle(req)
        sys.stdout.write(json.dumps(out, ensure_ascii=True) + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
