#!/usr/bin/env python3.12
"""JSON-lines adapter (kit protocol v1) for areas: events, expression."""
import json
import sys
import re
from fractions import Fraction

sys.set_int_max_str_digits(0)
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))

import expr as X
import events as E


def preview_text(v):
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if v is None:
        return ''
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return X.ruby_float_text(v)
    if isinstance(v, str):
        return v
    return X.ruby_inspect(v)


def result_ok(r, zero_keep, mode):
    if isinstance(r, str):
        return {'value': r, 'type': 'string', 'text': r}
    if mode == 'ep':
        return {'value': X.canonical(r), 'text': X.num_text(r, True)}
    return {'value': X.canonical(r), 'type': 'number', 'text': X.stored_text(r)}


def expression_evaluate(inp, profile):
    mode, text = inp['mode'], inp.get('expression')
    if mode == 'preview':
        if text is None or text.strip() == '':
            return {'error': {'code': 'value_is_mandatory', 'field': 'expression'}}
    try:
        node = X.parse(text)
    except X.ParseError as e:
        code = 'invalid_expression' if mode == 'preview' else 'parse_error'
        return {'error': {'code': code, 'field': 'expression', 'message': str(e)}}
    now = E.to_seconds(E.parse_instant(inp.get('now', '2026-01-01T00:00:00Z')))
    try:
        if mode == 'ep':
            ev = json.loads(inp['event_json'], parse_float=X.NumText, parse_int=X.NumText) \
                if 'event_json' in inp else inp['event']
            if not isinstance(ev, dict):
                raise X.EvalError('bad event')
            props = ev.get('properties', {})
            if not isinstance(props, dict):
                raise X.EvalError('properties')
            for v in props.values():
                if not isinstance(v, str):
                    raise X.EvalError('invalid property type')
            e2 = {'code': ev.get('code') if isinstance(ev.get('code'), str) else '', 'properties': props}
            if 'timestamp' in ev:
                e2['timestamp'] = ev['timestamp'] if isinstance(ev['timestamp'], str) else \
                    (_ for _ in ()).throw(X.EvalError('timestamp'))
            r = X.evaluate(node, e2, True)
        elif mode == 'rails':
            ev = inp.get('event') or {}
            props = ev.get('properties')
            props = props if isinstance(props, dict) else {}
            code = E.text_member(ev.get('code'))
            try:
                secs = E.event_time(ev.get('timestamp', E.ABSENT), now)
            except E.InvalidFormat:
                return {'error': {'code': 'invalid_format', 'field': 'timestamp'}}
            if profile == 'corrected':
                ts = X.Num((secs * 1000).__floor__(), 3)
            else:
                ts = X.Num(secs.__floor__(), 0)
            e2 = {'code': code if code is not None else '', 'timestamp': ts,
                  'properties': {k: E.prop_value(v) for k, v in props.items()}}
            r = X.evaluate(node, e2, False)
        else:
            ev = inp.get('event')
            ev = ev if isinstance(ev, dict) else {}
            props = ev.get('properties')
            props = props if isinstance(props, dict) else {}
            code = ev.get('code')
            ts = ev.get('timestamp', E.ABSENT)
            if ts is E.ABSENT or ts is None or isinstance(ts, (bool, dict, list)):
                tsn = now.__floor__()
            elif isinstance(ts, (int, float)):
                tsn = int(ts)
            else:
                m = re.match(r'\s*([+-]?\d+)', ts)
                tsn = int(m.group(1)) if m else 0
            e2 = {'code': E.text_member(code) or '' if code is not None else '',
                  'timestamp': X.Num(tsn, 0),
                  'properties': {k: preview_text(v) for k, v in props.items()}}
            r = X.evaluate(node, e2, False)
    except X.EvalError as e:
        if mode == 'preview':
            return {'error': {'code': 'invalid_event', 'field': 'event', 'message': str(e)}}
        return {'error': {'code': 'evaluation_error', 'message': str(e)}}
    except (ValueError, TypeError, KeyError) as e:
        if mode == 'preview':
            return {'error': {'code': 'invalid_event', 'field': 'event', 'message': str(e)}}
        return {'error': {'code': 'evaluation_error', 'message': str(e)}}
    return result_ok(r, mode == 'ep', mode)


OPS = {
    'events.validate': E.validate,
    'events.validate_batch': E.validate_batch,
    'events.parse_timestamp': E.parse_timestamp,
    'events.raw_message': E.raw_message,
    'events.duplicate_key': E.duplicate_key,
    'expression.evaluate': expression_evaluate,
}


def handle(req):
    key = '%s.%s' % (req['area'], req['op'])
    fn = OPS.get(key)
    if fn is None:
        return {'type': 'result', 'id': req['id'], 'error': {'code': 'unsupported_op', 'message': key}}
    try:
        out = fn(req['input'], req.get('profile', 'compat'))
    except Exception as e:  # noqa
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {'type': 'result', 'id': req['id'], 'error': {'code': 'internal', 'message': repr(e)}}
    if 'error' in out and len(out) == 1:
        return {'type': 'result', 'id': req['id'], 'error': out['error']}
    return {'type': 'result', 'id': req['id'], 'output': out}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        t = req.get('type')
        if t == 'hello':
            resp = {'type': 'hello', 'proto': 1, 'impl': 'crc-3-python', 'impl_version': '1.0.0',
                    'profiles': ['compat', 'corrected'], 'ops': ['events.*', 'expression.*']}
        elif t == 'bye':
            break
        else:
            resp = handle(req)
        sys.stdout.write(json.dumps(resp, ensure_ascii=False) + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
