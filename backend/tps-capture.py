#!/usr/bin/env python3
"""Local-only Codex OTLP receiver. Persist numeric samples, never raw telemetry."""
import argparse
from collections import deque
import datetime
import hashlib
import hmac
import http.server
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import sys
import tempfile
import threading
import time

PORT = 45417
HISTORY_PER_MODEL = 100
BEGIN = '# BEGIN CODEX PILOT TPS\n'
END = '# END CODEX PILOT TPS\n'
sys.dont_write_bytecode = True  # Keep the signed app bundle unchanged.
_context_spec = importlib.util.spec_from_file_location('pilot_request_context', Path(__file__).with_name('request-context.py'))
_context_module = importlib.util.module_from_spec(_context_spec)
_context_spec.loader.exec_module(_context_module)

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(value)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def configuration(home, data, enabled=None):
    config = home / 'config.toml'
    text = config.read_text() if config.exists() else ''
    managed = BEGIN in text and END in text
    if enabled is None:
        return managed
    if enabled and managed: return True
    if not enabled:
        if managed:
            start, end = max(0,text.index(BEGIN)-1), text.index(END) + len(END)
            atomic(config, text[:start] + text[end:])
        return False
    if re.search(r'^\s*(?:\[\[?otel(?:[.\]\s])|otel\s*[.=])', text, re.M):
        raise ValueError('已有自定义遥测配置，请先处理冲突；Pilot 未修改它。')
    data.mkdir(parents=True, exist_ok=True)
    token_path = data / 'tps-token'
    if not token_path.exists(): atomic(token_path, secrets.token_hex(32))
    token = token_path.read_text().strip()
    if config.exists():
        backup = data / 'backups' / ('config-before-tps-' + str(time.time_ns()) + '.toml')
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(config, backup)
        os.chmod(backup, 0o600)
    block = ('\n' + BEGIN + '[otel]\nlog_user_prompt = false\n'
             'exporter = { otlp-http = { endpoint = "http://127.0.0.1:%d/v1/logs", '
             'protocol = "json", headers = { "x-codex-pilot-token" = "%s" } } }\n' % (PORT, token) + END)
    atomic(config, text + block)
    return True

def load_samples(path):
    try:
        values = json.loads(path.read_text())['samples']
        return [s for s in values if s['outputTokens'] > 0 and s['durationSeconds'] > 0]
    except (OSError, ValueError, KeyError, TypeError): return []

def retained_samples(samples):
    counts, seen, result = {}, set(), []
    for sample in sorted(samples, key=lambda s:(s['completedAt'],s['id']), reverse=True):
        model = (sample['model'], sample.get('serviceTier') in ('fast', 'priority'))
        if sample['id'] in seen or counts.get(model,0) >= HISTORY_PER_MODEL: continue
        seen.add(sample['id'])
        counts[model] = counts.get(model,0)+1
        result.append(sample)
    return result

def migrate_samples(data):
    target = data / 'telemetry/samples.json'
    legacy = data / 'tps-samples.json'
    if not legacy.exists(): return target
    try:
        value = json.loads(legacy.read_text())
    except (OSError, ValueError): return target
    # A user may legitimately have a slot with this name. Never move credentials.
    if not isinstance(value, dict) or set(value) != {'samples'} or not isinstance(value['samples'],list):
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        legacy.rename(target)
        os.chmod(target,0o600)
    else:
        merged = {s['id']:s for s in load_samples(legacy)+load_samples(target)}
        samples=retained_samples(merged.values())
        atomic(target,json.dumps({'samples':samples},allow_nan=False))
        legacy.rename(target.parent / ('legacy-samples-'+str(time.time_ns())+'.json'))
    return target

class Capture:
    def __init__(self, path, home=None):
        self.path = path
        self.samples = load_samples(path)
        self.context = _context_module.RequestContext(home) if home is not None else None
        if self.context:
            previous = [dict(sample) for sample in self.samples]
            try: self.context.enrich(self.samples)
            except (OSError, ValueError, TypeError): pass  # Context is optional; preserve valid TPS.
            if self.samples != previous: atomic(self.path, json.dumps({'samples':self.samples},allow_nan=False))
        self.seen = {s['id'] for s in self.samples}
        self.pending = {}
        self.closed = {}
        for sample in self.samples:
            if sample.get('conversationID'):
                key = sample['conversationID']
                self.closed[key] = max(self.closed.get(key, -math.inf), sample['completedAt'])
        self.event_ids, self.event_order = set(), deque()
        self.diagnostics = {'batches':0,'events':{},'fields':{},'kinds':{},'paired':0,'rejected':{}}
        self.sample_revision = 0
        self.diagnostics_saved_at = None

    def reject(self, reason):
        counts = self.diagnostics['rejected']
        counts[reason] = counts.get(reason, 0) + 1

    def ingest(self, value):
        if not isinstance(value, dict): raise ValueError('Invalid OTLP object')
        self.diagnostics['batches'] += 1
        events = []
        for resource in value.get('resourceLogs', []):
            for scope in resource.get('scopeLogs', []):
                for record in scope.get('logRecords', []):
                    attrs = {}
                    for attr in record.get('attributes', []):
                        v = attr.get('value', {})
                        attrs[attr.get('key')] = next((v[k] for k in ['stringValue','intValue','doubleValue','boolValue'] if k in v), None)
                    name = attrs.get('event.name','unnamed')
                    if not isinstance(name,str) or not re.fullmatch(r'codex\.[a-zA-Z0-9_.]+',name):name='unnamed'
                    self.diagnostics['events'][name] = self.diagnostics['events'].get(name,0)+1
                    self.diagnostics['fields'][name] = sorted(set(self.diagnostics['fields'].get(name,[]))|set(k for k in attrs if isinstance(k,str)))
                    kind = attrs.get('event.kind','missing')
                    if isinstance(kind,str) and re.fullmatch(r'[a-zA-Z0-9_.:-]{1,100}',kind):
                        self.diagnostics['kinds'][kind] = self.diagnostics['kinds'].get(kind,0)+1
                    if attrs.get('event.name') not in ['codex.sse_event','codex.websocket_event','codex.websocket_request']: continue
                    try:
                        stamp = attrs.get('event.timestamp')
                        when = datetime.datetime.fromisoformat(stamp.replace('Z','+00:00')).timestamp() if stamp else int(record['timeUnixNano']) / 1e9
                        if not math.isfinite(when): continue
                        events.append((when, attrs))
                    except (KeyError, ValueError, TypeError, OverflowError, OSError): continue
        revision = self.sample_revision
        for when, attrs in sorted(events, key=lambda e:e[0]): self.event(when, attrs)
        # Raw telemetry prompts/tools never reach disk. Only a bounded local
        # user-message label is attached for identifying the request.
        if revision != self.sample_revision:
            atomic(self.path, json.dumps({'samples': self.samples}, allow_nan=False))
        self.diagnostics['paired'] = len(self.samples)
        now = time.monotonic()
        if self.diagnostics_saved_at is None or now - self.diagnostics_saved_at >= 60:
            atomic(self.path.parent/'diagnostics.json',json.dumps(self.diagnostics))
            self.diagnostics_saved_at = now

    def event(self, when, attrs):
        model, conversation = attrs.get('model'), attrs.get('conversation.id')
        if not isinstance(model, str) or not model.strip() or not isinstance(conversation, str) or not conversation: return
        if not math.isfinite(when): return
        # The runtime's websocket sender retains the session's initial model,
        # while response.completed reports the current turn's actual model.
        # Pair the stream by conversation; use completion metadata for the
        # sample's model. Without request IDs, concurrent streams within one
        # conversation remain ambiguous even when their model labels differ.
        key = conversation
        kind = attrs.get('event.kind')
        # The official runtime reports a disconnected/failed stream as
        # response.completed + error.message, without usage counters. It is a
        # terminal failure, not a successful completion missing usage.
        completion_error = (kind == 'response.completed' and
                            isinstance(attrs.get('error.message'), str) and
                            bool(attrs['error.message'].strip()))
        # Retry exports and records arriving after a later terminal event must
        # not reopen an old stream or invalidate a newer request.
        if when <= self.closed.get(key, -math.inf): return
        fingerprint = (key, model, when, attrs.get('event.name'), kind, completion_error,
                       *(str(attrs.get(k)) for k in ['success','output_token_count','input_token_count',
                                                    'reasoning_token_count','cached_token_count','ttft_ms']))
        if fingerprint in self.event_ids: return
        self.event_ids.add(fingerprint)
        self.event_order.append(fingerprint)
        if len(self.event_order) > 16384: self.event_ids.discard(self.event_order.popleft())
        # Evict before inspecting state: early-return branches otherwise leave
        # an abandoned request blocking this conversation indefinitely.
        self.pending = {k:v for k,v in self.pending.items() if when-v['start'] <= 3600}
        state = self.pending.get(key)
        if state and when < state['start']:
            state['invalid'] = True
            self.reject('out_of_order')
            return
        websocket_start = attrs.get('event.name') == 'codex.websocket_request' and str(attrs.get('success')).lower() == 'true'
        if kind == 'response.created' or websocket_start:
            if state and when == state['start']: return  # duplicate transport record
            if state:
                state['overlap'] += 1  # no request id: overlapping streams cannot be paired safely
                state['invalid'] = True
                return
            self.pending[key] = dict(start=when, first=None, overlap=0, invalid=False,
                                     transport='websocket' if websocket_start else 'sse')
        elif kind in ['response.output_item.added','response.output_text.delta',
                      'response.reasoning_text.delta','response.reasoning_summary_text.delta',
                      'response.function_call_arguments.delta','response.custom_tool_call_input.delta']:
            if state and state['first'] is None and when >= state['start']: state['first'] = when
        elif kind in ['response.failed','response.incomplete','error'] or completion_error:
            if completion_error: self.reject('stream_error')
            self.closed[key] = when
            if state and state['overlap']:
                state['overlap'] -= 1
                state['invalid'] = True
            else: self.pending.pop(key, None)
        elif kind == 'response.completed' and 'output_token_count' in attrs:
            self.closed[key] = when
            if state is None: return
            if state['overlap']:
                state['overlap'] -= 1
                self.reject('overlap')
                return
            self.pending.pop(key, None)
            if state['invalid']: return
            first = state['first']
            if first is None and state['transport'] == 'websocket':
                try:
                    ttft = float(attrs['ttft_ms']) / 1000
                    if not math.isfinite(ttft) or ttft < 0: return
                    first = state['start'] + ttft
                except (KeyError,ValueError,TypeError): return
            if first is None or when <= first: return
            try:
                # Missing reasoning usage is unknown, never evidence of zero.
                # Keep original integer counters; reject contradictions instead
                # of clamping or silently truncating them into believable data.
                def integer_count(name):
                    value = attrs[name]
                    if type(value) is int: count = value
                    elif isinstance(value, str) and re.fullmatch(r'[0-9]+', value): count = int(value)
                    else: raise ValueError('invalid token counter')
                    if not 0 <= count <= 2**63-1: raise ValueError('invalid token counter')
                    return count
                output = integer_count('output_token_count')
                input_count = integer_count('input_token_count')
                reasoning = integer_count('reasoning_token_count')
                cached = integer_count('cached_token_count')
                if reasoning > output or cached > input_count: raise ValueError('inconsistent token subsets')
                duration = when - first
                if output <= 0 or not 0.001 <= duration <= 3600: return
                identity = hashlib.sha256(('%s:%s:%.6f:%.6f' % (conversation,model,state['start'],when)).encode()).hexdigest()
                if identity in self.seen: return
                sample = dict(id=identity,model=model,completedAt=when,outputTokens=output,
                              durationSeconds=duration, inputTokens=input_count,
                              timingSource=state['transport'],
                              reasoningTokens=reasoning,
                              cachedTokens=cached,
                              ttftSeconds=max(0,float(attrs.get('ttft_ms',0))/1000))
                sample['conversationID'] = conversation
                sample['startedAt'] = state['start']
                if self.context:
                    try: preview = self.context.preview(conversation, state['start'])
                    except (OSError, ValueError, TypeError): preview = None
                    if preview: sample['promptPreview'] = preview
                if not math.isfinite(sample['ttftSeconds']): return
                # Request-selected tier only; absent metadata stays unknown.
                tier = attrs.get('service_tier')
                if isinstance(tier, str) and tier in {'priority', 'fast', 'default', 'flex', 'scale', 'ultrafast', 'auto'}:
                    sample['serviceTier'] = tier
            except KeyError:
                self.reject('missing_counts'); return
            except (ValueError, TypeError, OverflowError):
                self.reject('invalid_counts'); return
            self.samples.append(sample)
            self.samples = retained_samples(self.samples)
            self.seen = {s['id'] for s in self.samples}
            self.sample_revision += 1
        if len(self.closed) > 8192:
            self.closed = dict(sorted(self.closed.items(), key=lambda p:p[1], reverse=True)[:4096])

def serve(data, parent, port=PORT, home=None):
    token_path = data / 'tps-token'
    if not token_path.exists(): atomic(token_path, secrets.token_hex(32))
    token = token_path.read_text().strip()
    capture = Capture(migrate_samples(data), home=home)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_POST(self):
            if self.path != '/v1/logs': self.send_error(404); return
            if not hmac.compare_digest(self.headers.get('x-codex-pilot-token',''), token):
                self.send_error(403); return
            try:
                length = int(self.headers.get('Content-Length','0'))
                if not 0 < length <= 8*1024*1024: self.send_error(413); return
                self.connection.settimeout(5)
                raw = self.rfile.read(length)
                if len(raw) != length: self.send_error(400); return
                capture.ingest(json.loads(raw))
            except (ValueError, KeyError, TypeError, AttributeError, OSError): self.send_error(400); return
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length','2')
            self.end_headers()
            self.wfile.write(b'{}')
    server = http.server.HTTPServer(('127.0.0.1', port), Handler)
    if hasattr(select, 'kqueue'):
        # Sleep in the kernel until a batch arrives or the owning app exits.
        # No per-second parent polling on macOS.
        queue = select.kqueue()
        try:
            try:
                queue.control([
                    select.kevent(server.fileno(), filter=select.KQ_FILTER_READ, flags=select.KQ_EV_ADD),
                    select.kevent(parent, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)], 0)
            except ProcessLookupError:
                return
            while True:
                events = queue.control(None, 2, None)
                if any(event.filter == select.KQ_FILTER_PROC for event in events): break
                if any(event.filter == select.KQ_FILTER_READ for event in events): server.handle_request()
        finally:
            queue.close()
            server.server_close()
    else:
        server.timeout = 30
        try:
            while True:
                try: os.kill(parent, 0)
                except OSError: break
                server.handle_request()
        finally:
            server.server_close()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['serve','status','enable','disable'])
    p.add_argument('--parent', type=int, default=os.getppid())
    p.add_argument('--port', type=int, default=PORT)
    p.add_argument('--home',type=Path,default=Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex'))).expanduser())
    p.add_argument('--data',type=Path,default=Path.home()/'.codex-swap')
    a = p.parse_args()
    if a.command == 'serve': serve(a.data,a.parent,a.port,home=a.home); return
    try:
        enabled=configuration(a.home,a.data, None if a.command=='status' else a.command=='enable')
        print(json.dumps(dict(ok=True,enabled=enabled)))
    except (OSError,ValueError) as e:
        print(json.dumps(dict(ok=False,error=str(e))))
        raise SystemExit(1)

if __name__ == '__main__': main()
