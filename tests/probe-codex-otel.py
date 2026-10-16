"""Probe bundled Codex against a local mock Responses API; no real credentials/API."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT / '.build/otel-probe/home'
HOME.mkdir(parents=True, exist_ok=True)
records = []

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/v1/logs':
            value = json.loads(data)
            records.append(value)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'{}')
            return
        if self.path != '/v1/responses':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        response = dict(id='resp_pilot_mock', object='response', created_at=int(time.time()),
                        model='gpt-mock', status='in_progress', output=[])
        def emit(kind, **kw):
            event = dict(type=kind, **kw)
            self.wfile.write(('event: '+kind+'\ndata: '+json.dumps(event)+'\n\n').encode())
            self.wfile.flush()
        emit('response.created', response=response)
        time.sleep(0.5)  # TTFT must not become generation time.
        item = dict(id='msg_mock', type='message', role='assistant', status='in_progress', content=[])
        emit('response.output_item.added', output_index=0, item=item)
        emit('response.content_part.added', item_id='msg_mock', output_index=0, content_index=0,
             part=dict(type='output_text', text='', annotations=[]))
        for _ in range(10):
            emit('response.output_text.delta', item_id='msg_mock', output_index=0, content_index=0, delta='ok ')
            time.sleep(0.1)
        text = 'ok ' * 10
        emit('response.output_text.done', item_id='msg_mock', output_index=0, content_index=0, text=text)
        item.update(status='completed', content=[dict(type='output_text', text=text, annotations=[])])
        emit('response.output_item.done', output_index=0, item=item)
        response.update(status='completed', output=[item], usage=dict(input_tokens=100, output_tokens=100,
                        total_tokens=200, input_tokens_details=dict(cached_tokens=0),
                        output_tokens_details=dict(reasoning_tokens=0)))
        emit('response.completed', response=response)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
port = server.server_port
threading.Thread(target=server.serve_forever, daemon=True).start()
args = ['/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex', 'exec',
        '--skip-git-repo-check', '--sandbox', 'read-only', '-m', 'gpt-mock']
for c in [
    'model_provider="pilot_mock"',
    f'model_providers.pilot_mock={{name="Pilot mock",base_url="http://127.0.0.1:{port}/v1",wire_api="responses",env_key="PILOT_MOCK_API_KEY"}}',
    f'otel.exporter={{otlp-http={{endpoint="http://127.0.0.1:{port}/v1/logs",protocol="json"}}}}',
    'otel.log_user_prompt=false', 'otel.metrics_exporter="none"',
    'features.responses_websockets=false', 'features.responses_websockets_v2=false',
    'features.plugins=false', 'features.apps=false',
]:
    args += ['-c', c]
args += ['Say ok. Do not call tools.']
env = dict(os.environ, CODEX_HOME=str(HOME), PILOT_MOCK_API_KEY='local-mock-only')
for key in ['OPENAI_API_KEY','CODEX_API_KEY']:
    env.pop(key,None)
result = subprocess.run(args, cwd=HOME, env=env, capture_output=True, text=True, timeout=45)
print('Mock Codex exit:', result.returncode)
print('Mock Codex stderr:', result.stderr[-1600:])
print('OTLP batches:', len(records))
for batch in records:
    for resource in batch.get('resourceLogs', []):
        for scope in resource.get('scopeLogs', []):
            for r in scope.get('logRecords', []):
                attrs = {a['key']:a['value'] for a in r.get('attributes', [])}
                print('Record:', r.get('body'), sorted(attrs),
                      {k:v for k,v in attrs.items() if any(s in k for s in ['kind','duration','ttft','token','event'])})
(HOME.parent/'otlp.json').write_text(json.dumps(records))
server.shutdown()
if result.returncode:
    raise SystemExit(result.returncode)
