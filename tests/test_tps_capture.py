import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import os
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error
from unittest import mock
import select

spec = importlib.util.spec_from_file_location('capture', Path(__file__).parents[1]/'backend/tps-capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)

def record(stamp, kind, model='a', conversation='local-test', **extra):
    defaults = dict(input_token_count=0, reasoning_token_count=0, cached_token_count=0) if kind == 'response.completed' else {}
    attrs = dict(model=model, **{'event.name':'codex.sse_event','event.kind':kind,
                 'event.timestamp':f'2026-10-09T10:00:{stamp:06.3f}Z','conversation.id':conversation}, **extra)
    for key,value in defaults.items():attrs.setdefault(key,value)
    return dict(attributes=[dict(key=k,value=dict(stringValue=str(v))) for k,v in attrs.items()])

def batch(*records): return dict(resourceLogs=[dict(scopeLogs=[dict(logRecords=list(records))])])

class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.path = self.root/'samples.json'
        self.capture = capture.Capture(self.path)
    def tearDown(self): self.tmp.cleanup()
    def test_wait_and_idle_do_not_reduce_speed_or_write_content(self):
        self.capture.ingest(batch(record(0,'response.created'),
            record(10,'response.output_item.added'),
            record(12,'response.completed',output_token_count=200,input_token_count=500,
                   ttft_ms=10000,prompt='PRIVATE_TEXT',tool_output='PRIVATE_OUTPUT')))
        self.assertEqual(len(self.capture.samples),1)
        s=self.capture.samples[0]
        self.assertEqual(s['outputTokens']/s['durationSeconds'],100)
        self.assertEqual(s['ttftSeconds'],10)
        self.assertNotIn('PRIVATE',self.path.read_text())
        self.assertEqual(self.path.stat().st_mode & 0o777,0o600)
    def test_duplicate_exports_and_receiver_restart_do_not_duplicate_samples(self):
        b=batch(record(0,'response.created'),record(1,'response.output_item.added'),
                record(3,'response.completed',output_token_count=200))
        self.capture.ingest(b);self.capture.ingest(b)
        again=capture.Capture(self.path);again.ingest(b)
        self.assertEqual(len(again.samples),1)
    def test_unrelated_and_duplicate_batches_do_not_rewrite_samples(self):
        irrelevant=batch({'attributes':[dict(key='event.name',value=dict(stringValue='codex.tool_result'))]})
        valid=batch(record(0,'response.created'),record(1,'response.output_item.added'),
                    record(3,'response.completed',output_token_count=100))
        with mock.patch.object(capture,'atomic',wraps=capture.atomic) as writes, \
             mock.patch.object(capture.time,'monotonic',return_value=0) as clock:
            self.capture.ingest(valid)
            original=self.path.read_bytes()
            writes.reset_mock()
            for _ in range(100):self.capture.ingest(irrelevant)
            self.capture.ingest(valid)
            self.assertEqual(writes.call_count,0)
            self.assertEqual(self.path.read_bytes(),original)
            clock.return_value=61
            self.capture.ingest(irrelevant)
            self.assertEqual([c.args[0].name for c in writes.call_args_list],['diagnostics.json'])
            self.capture.ingest(batch(record(4,'response.created'),record(5,'response.output_item.added'),
                                      record(7,'response.completed',output_token_count=200)))
            self.assertEqual([c.args[0].name for c in writes.call_args_list],['diagnostics.json','samples.json'])
            self.assertEqual(len(capture.load_samples(self.path)),2)
    def test_missing_counts_never_become_zero(self):
        for missing in ['input_token_count','reasoning_token_count','cached_token_count']:
            end=record(3,'response.completed',output_token_count=100)
            end['attributes']=[a for a in end['attributes'] if a['key']!=missing]
            cap=capture.Capture(self.root/(missing+'.json'))
            cap.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),end))
            self.assertEqual(cap.samples,[])
            self.assertEqual(cap.diagnostics['rejected'].get('missing_counts'),1)
    def test_invalid_counters_are_not_clamped_or_truncated(self):
        for index,extra in enumerate([{'reasoning_token_count':-1},{'reasoning_token_count':101},
                {'reasoning_token_count':1.5},{'input_token_count':2,'cached_token_count':3},
                {'output_token_count':100.5},{'cached_token_count':-1}]):
            cap=capture.Capture(self.root/('invalid-'+str(index)+'.json'))
            values=dict(output_token_count=100);values.update(extra)
            cap.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),
                             record(3,'response.completed',**values)))
            self.assertEqual(cap.samples,[])
    def test_failed_overlap_stays_untrusted_until_all_streams_end(self):
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),
            record(2,'response.created'),record(3,'response.failed'),record(4,'response.created'),
            record(5,'response.output_item.added'),record(6,'response.completed',output_token_count=999)))
        self.assertEqual(self.capture.samples,[])
        self.capture.ingest(batch(record(7,'response.completed',output_token_count=200)))
        self.assertEqual(self.capture.samples,[])
        self.capture.ingest(batch(record(8,'response.created'),record(9,'response.output_item.added'),
            record(10,'response.completed',output_token_count=100)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['outputTokens'],100)
    def test_completed_with_error_closes_disconnected_request_before_retry(self):
        failed=batch(record(0,'response.created'),record(1,'response.output_item.added'),
                     record(2,'response.completed',**{'error.message':'stream disconnected before completion'}))
        self.capture.ingest(failed)
        self.assertFalse(self.capture.samples)
        self.assertFalse(self.capture.pending)
        self.capture.ingest(batch(record(3,'response.created'),record(4,'response.output_item.added'),
                                 record(6,'response.completed',output_token_count=200)))
        self.assertEqual(len(self.capture.samples),1)
        sample=self.capture.samples[0]
        self.assertEqual(sample['durationSeconds'],2)
        self.assertEqual(sample['startedAt'],capture.datetime.datetime.fromisoformat('2026-10-09T10:00:03+00:00').timestamp())
        self.assertEqual(self.capture.diagnostics['rejected'].get('stream_error'),1)
        # Re-exporting the failed attempt must not invalidate the newer stream.
        self.capture.ingest(batch(record(7,'response.created'),record(8,'response.output_item.added')))
        self.capture.ingest(failed)
        self.capture.ingest(batch(record(10,'response.completed',output_token_count=300)))
        self.assertEqual(len(self.capture.samples),2)
        self.assertEqual(self.capture.samples[0]['outputTokens'],300)
        self.assertNotIn('stream disconnected',self.path.read_text())
    def test_completed_error_keeps_real_overlaps_untrusted_until_all_end(self):
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),
            record(2,'response.created'),record(3,'response.completed',**{'error.message':'disconnect'}),
            record(4,'response.created'),record(5,'response.output_item.added'),
            record(6,'response.completed',output_token_count=999)))
        self.assertEqual(self.capture.samples,[])
        self.capture.ingest(batch(record(7,'response.completed',output_token_count=200)))
        self.assertEqual(self.capture.samples,[])
        self.capture.ingest(batch(record(8,'response.created'),record(9,'response.output_item.added'),
            record(10,'response.completed',output_token_count=100)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['outputTokens'],100)
    def test_completed_with_error_is_never_a_valid_tps_even_if_usage_present(self):
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),
            record(2,'response.completed',output_token_count=200,**{'error.message':'failure'})))
        self.assertEqual(self.capture.samples,[])
        self.assertFalse(self.capture.pending)
        self.assertEqual(self.capture.diagnostics['rejected'].get('stream_error'),1)
    def test_generic_completed_marker_does_not_close_before_usage_completion(self):
        # SSE emits a generic marker followed by a usage-bearing completion.
        generic=record(2,'response.completed')
        generic['attributes']=[a for a in generic['attributes'] if a['key'] not in
                              ['input_token_count','reasoning_token_count','cached_token_count']]
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added'),generic,
                                 record(2,'response.completed',output_token_count=100)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['durationSeconds'],1)
    def test_old_export_retries_do_not_poison_current_request(self):
        old=batch(record(0,'response.created'),record(1,'response.output_item.added'),
                  record(3,'response.completed',output_token_count=100))
        self.capture.ingest(old)
        self.capture.ingest(batch(record(4,'response.created'),record(5,'response.output_item.added')))
        self.capture.ingest(old)
        self.capture.ingest(batch(record(6,'response.completed',output_token_count=200)))
        self.assertEqual(len(self.capture.samples),2)
        self.assertEqual(self.capture.samples[0]['outputTokens'],200)
    def test_out_of_order_completion_does_not_reopen_a_ghost_request(self):
        self.capture.ingest(batch(record(3,'response.completed',output_token_count=100)))
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.output_item.added')))
        self.capture.ingest(batch(record(4,'response.created'),record(5,'response.output_item.added'),
                                 record(6,'response.completed',output_token_count=200)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['outputTokens'],200)
    def test_expired_pending_is_evicted_before_new_start(self):
        attrs={'model':'a','conversation.id':'test','event.name':'codex.sse_event'}
        self.capture.event(0,dict(attrs,**{'event.kind':'response.created'}))
        self.capture.event(4000,dict(attrs,**{'event.kind':'response.created'}))
        self.capture.event(4001,dict(attrs,**{'event.kind':'response.output_item.added'}))
        self.capture.event(4002,dict(attrs,**{'event.kind':'response.completed'},output_token_count=100,
            input_token_count=0,reasoning_token_count=0,cached_token_count=0))
        self.assertEqual(len(self.capture.samples),1)
    def test_request_tier_survives_capture_and_restart_without_guessing(self):
        for i,tier in enumerate(['priority','fast','default',None,'PRIVATE_UNRECOGNIZED']):
            extra={} if tier is None else {'service_tier':tier}
            self.capture.ingest(batch(record(i*4,'response.created'),record(i*4+1,'response.output_item.added'),
                record(i*4+3,'response.completed',output_token_count=200,**extra)))
        samples=capture.Capture(self.path).samples
        self.assertEqual([s.get('serviceTier') for s in samples],[None,None,'default','fast','priority'])
        self.assertNotIn('PRIVATE_UNRECOGNIZED',self.path.read_text())
    def test_unfinished_failed_missing_and_overlapping_requests_are_excluded(self):
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.completed',output_token_count=100)))
        self.assertFalse(self.capture.samples)
        self.capture.ingest(batch(record(2,'response.created'),record(3,'response.output_item.added'),record(4,'response.failed')))
        self.assertFalse(self.capture.samples)
        self.capture.ingest(batch(record(5,'response.created'),record(6,'response.output_item.added'),
            record(7,'response.created'),record(8,'response.output_item.added'),
            record(9,'response.completed',output_token_count=100),record(10,'response.completed',output_token_count=100)))
        self.assertFalse(self.capture.samples)
    def test_parallel_sessions_remain_separate(self):
        self.capture.ingest(batch(record(0,'response.created'),record(1,'response.created',conversation='b'),
            record(2,'response.output_item.added'),record(3,'response.output_item.added',conversation='b'),
            record(4,'response.completed',output_token_count=200),
            record(5,'response.completed',conversation='b',output_token_count=100)))
        self.assertEqual([s['outputTokens']/s['durationSeconds'] for s in self.capture.samples],[50,100])
    def test_model_switch_pairs_stale_websocket_sender_with_actual_completion(self):
        # Observed with bundled app-server: after Astra -> Luna the websocket
        # sender continues exporting Astra, while completions correctly say Luna.
        for index,model in enumerate(['astra','luna','luna','astra']):
            start=record(index*4,'missing',model='astra',success='true')
            for attr in start['attributes']:
                if attr['key']=='event.name':attr['value']['stringValue']='codex.websocket_request'
            self.capture.ingest(batch(start))
            self.capture.ingest(batch(record(index*4+3,'response.completed',model=model,
                output_token_count=200+index,ttft_ms=1000)))
        self.assertEqual([s['model'] for s in self.capture.samples],['astra','luna','luna','astra'])
        self.assertEqual([s['outputTokens'] for s in self.capture.samples],[203,202,201,200])
        self.assertEqual([s['durationSeconds'] for s in self.capture.samples],[2,2,2,2])
        self.assertFalse(self.capture.pending)
    def test_model_switch_overlapping_streams_are_still_excluded(self):
        self.capture.ingest(batch(record(0,'response.created',model='a'),
            record(1,'response.output_item.added',model='a'),
            record(2,'response.created',model='b'),
            record(3,'response.output_item.added',model='b'),
            record(4,'response.completed',model='b',output_token_count=100),
            record(5,'response.completed',model='a',output_token_count=200)))
        self.assertFalse(self.capture.samples)
        self.assertFalse(self.capture.pending)
        self.capture.ingest(batch(record(6,'response.created',model='a'),
            record(7,'response.output_item.added',model='b'),
            record(8,'response.completed',model='b',output_token_count=300)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['model'],'b')
        self.assertEqual(self.capture.samples[0]['durationSeconds'],1)
    def test_model_switch_disconnect_and_delayed_exports_do_not_poison_retry(self):
        failed=batch(record(0,'response.created',model='a'),
            record(1,'response.completed',model='b',**{'error.message':'disconnected'}))
        self.capture.ingest(failed)
        self.capture.ingest(batch(record(2,'response.created',model='a'),
            record(3,'response.output_item.added',model='b')))
        self.capture.ingest(failed)
        self.capture.ingest(batch(record(4,'response.completed',model='b',output_token_count=100)))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['model'],'b')
        again=capture.Capture(self.path)
        again.ingest(batch(record(2,'response.created',model='a')))
        self.assertFalse(again.pending)
    def test_retention_keeps_one_hundred_per_model_not_global(self):
        values=[dict(id='a'+str(i),model='a',completedAt=i,outputTokens=1,durationSeconds=1) for i in range(150)]
        values += [dict(id='b'+str(i),model='b',completedAt=i,outputTokens=1,durationSeconds=1) for i in range(120)]
        kept=capture.retained_samples(values+values)
        self.assertEqual(len(kept),200)
        self.assertEqual(min(s['completedAt'] for s in kept if s['model']=='a'),50)
        self.assertEqual(min(s['completedAt'] for s in kept if s['model']=='b'),20)
        self.assertEqual(len({s['id'] for s in kept}),200)
    def test_managed_configuration_preserves_settings_and_refuses_conflicts(self):
        home=self.root/'home';home.mkdir()
        config=home/'config.toml';original='model = "test"\n[features]\ncustom = true\n'
        config.write_text(original)
        self.assertTrue(capture.configuration(home,self.root,True))
        self.assertIn(original,config.read_text())
        self.assertIn('127.0.0.1',config.read_text())
        self.assertIn('log_user_prompt = false',config.read_text())
        self.assertFalse(capture.configuration(home,self.root,False))
        self.assertEqual(config.read_text(),original)
        config.write_text('[otel]\nexporter="none"\n')
        with self.assertRaises(ValueError):capture.configuration(home,self.root,True)
        self.assertEqual(config.read_text(),'[otel]\nexporter="none"\n')
    def test_bundled_codex_mock_export_fixture_when_present(self):
        fixture=Path(__file__).parents[1]/'.build/otel-probe/otlp.json'
        if not fixture.exists():self.skipTest('Run probe-codex-otel.py for a bundled-runtime integration fixture')
        for b in json.loads(fixture.read_text()):self.capture.ingest(b)
        self.assertEqual(len(self.capture.samples),1)
        s=self.capture.samples[0]
        self.assertTrue(0.8 < s['durationSeconds'] < 2)
        self.assertTrue(s['ttftSeconds'] >= 0.4)

    def test_official_runtime_disconnect_retry_export_recovers_successful_call(self):
        fixture=Path(__file__).parent/'fixtures/official-runtime-websocket-disconnect.json'
        for b in json.loads(fixture.read_text()):self.capture.ingest(b)
        self.assertEqual(len(self.capture.samples),1)
        sample=self.capture.samples[0]
        self.assertEqual((sample['outputTokens'],sample['reasoningTokens'],sample['inputTokens'],sample['cachedTokens']),
                         (304,253,600,100))
        self.assertEqual(sample['startedAt'],capture.datetime.datetime.fromisoformat('2026-10-12T01:58:10.268+00:00').timestamp())
        self.assertAlmostEqual(sample['ttftSeconds'],1.508)
        self.assertEqual(self.capture.diagnostics['rejected'],{'stream_error':1})

    def test_official_runtime_model_switch_exports_keep_each_actual_model(self):
        fixture=Path(__file__).parent/'fixtures/official-runtime-model-switch.json'
        for b in json.loads(fixture.read_text()):self.capture.ingest(b)
        ordered=sorted(self.capture.samples,key=lambda s:s['completedAt'])
        self.assertEqual([s['model'] for s in ordered],['gpt-6-astra','gpt-6-luna','gpt-6-luna'])
        self.assertEqual([s['outputTokens'] for s in ordered],[304,304,304])
        self.assertTrue(all(s['reasoningTokens']==253 and s['inputTokens']==600 and s['cachedTokens']==100 for s in ordered))
        self.assertTrue(all(.2 < s['durationSeconds'] < .5 for s in ordered))
        self.assertFalse(self.capture.pending)

    def test_local_http_receiver_requires_token_and_persists_only_samples(self):
        with socket.socket() as s:
            s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        script=Path(__file__).parents[1]/'backend/tps-capture.py'
        proc=subprocess.Popen([sys.executable,str(script),'serve','--data',str(self.root),
                               '--home',str(self.root/'home'),
                               '--parent',str(os.getpid()),'--port',str(port)],stderr=subprocess.DEVNULL)
        try:
            for _ in range(200):
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=0.1):break
                except OSError:time.sleep(0.01)
            body=json.dumps(batch(record(0,'response.created'),record(10,'response.output_item.added'),
                record(12,'response.completed',output_token_count=200,prompt='PRIVATE'))).encode()
            url='http://127.0.0.1:%d/v1/logs'%port
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(urllib.request.Request(url,data=body),timeout=3)
            self.assertEqual(error.exception.code,403)
            self.assertFalse((self.root/'telemetry/samples.json').exists())
            token=(self.root/'tps-token').read_text()
            request=urllib.request.Request(url,data=body,headers={'x-codex-pilot-token':token,'Content-Type':'application/json'})
            with urllib.request.urlopen(request,timeout=3) as response:self.assertEqual(response.status,200)
            samples=capture.load_samples(self.root/'telemetry/samples.json')
            self.assertEqual(samples[0]['outputTokens']/samples[0]['durationSeconds'],100)
            self.assertNotIn('PRIVATE',(self.root/'telemetry/samples.json').read_text())
        finally:
            proc.terminate();proc.wait(timeout=3)

    @unittest.skipUnless(hasattr(select,'kqueue'),'macOS parent-exit notification')
    def test_idle_receiver_exits_promptly_when_parent_exits(self):
        parent=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])
        with socket.socket() as s:
            s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        proc=subprocess.Popen([sys.executable,str(Path(__file__).parents[1]/'backend/tps-capture.py'),
            'serve','--data',str(self.root),'--home',str(self.root/'home'),
            '--parent',str(parent.pid),'--port',str(port)],stderr=subprocess.PIPE)
        try:
            for _ in range(200):
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                except OSError:time.sleep(.01)
            parent.terminate();parent.wait(timeout=2)
            self.assertEqual(proc.wait(timeout=2),0)
        finally:
            for child in [proc,parent]:
                if child.poll() is None:child.terminate();child.wait(timeout=3)
            proc.stderr.close()

    def test_legacy_cache_moves_without_moving_credentials(self):
        legacy=self.root/'tps-samples.json'
        original=json.dumps({'samples':[]})
        legacy.write_text(original)
        target=capture.migrate_samples(self.root)
        self.assertFalse(legacy.exists())
        self.assertEqual(target.read_text(),original)
        self.assertEqual(target.stat().st_mode & 0o777,0o600)
        credentials='{"tokens":{"account_id":"synthetic"}}'
        legacy.write_text(credentials)
        capture.migrate_samples(self.root)
        self.assertEqual(legacy.read_text(),credentials)

    def test_websocket_send_and_completion_exclude_first_output_wait(self):
        start=record(0,'missing',success='true')
        for a in start['attributes']:
            if a['key']=='event.name':a['value']['stringValue']='codex.websocket_request'
        end=record(12,'response.completed',output_token_count=200,ttft_ms=10000)
        self.capture.ingest(batch(start))
        self.capture.ingest(batch(end))
        self.assertEqual(len(self.capture.samples),1)
        self.assertEqual(self.capture.samples[0]['durationSeconds'],2)
        self.assertEqual(self.capture.samples[0]['outputTokens']/self.capture.samples[0]['durationSeconds'],100)
        self.assertEqual(self.capture.samples[0]['timingSource'],'websocket')

    def test_websocket_missing_wait_or_impossible_duration_is_excluded(self):
        for extra in [{}, {'ttft_ms':20000}]:
            start=record(0,'missing',success='true')
            for a in start['attributes']:
                if a['key']=='event.name':a['value']['stringValue']='codex.websocket_request'
            self.capture.ingest(batch(start,record(12,'response.completed',output_token_count=200,**extra)))
        self.assertFalse(self.capture.samples)

if __name__=='__main__':unittest.main()
