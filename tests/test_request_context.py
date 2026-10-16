import importlib.util
import datetime
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import sqlite3
import tracemalloc
spec=importlib.util.spec_from_file_location('context',Path(__file__).parents[1]/'backend/request-context.py')
context=importlib.util.module_from_spec(spec);spec.loader.exec_module(context)
ID='019f0000-1111-7000-8000-000000000001'
class ContextTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.home=Path(self.tmp.name)
  self.path=self.home/'sessions'/('rollout-'+ID+'.jsonl');self.path.parent.mkdir()
  self.rows=[]
 def tearDown(self):self.tmp.cleanup()
 def add(self,t,type,payload):
  self.rows.append(dict(timestamp=datetime.datetime.fromtimestamp(t,datetime.timezone.utc).isoformat(),type=type,payload=payload))
  self.path.write_text(''.join(json.dumps(r)+'\n' for r in self.rows))
 def message(self,t,text):self.add(t,'response_item',dict(role='user',content=[dict(type='input_text',text=text)]))
 def fixture(self):
  self.message(1000,'<environment_context>\nSYSTEM_ONLY\n</environment_context>')
  self.message(1001,'# Files mentioned by the user:\nSECRET_FILE\n## My request:\n帮我检查这个项目。后面的内容不用显示\n<image name="s">PRIVATE_IMAGE</image>')
  self.message(1010,'现在改一下按钮。第二句')
  return context.RequestContext(self.home)
 def test_first_sentence_ignores_attachment_metadata_and_environment(self):
  resolver=self.fixture()
  self.assertEqual(resolver.preview(ID,1009),'帮我检查这个项目。')
  self.assertEqual(resolver.preview(ID,1011),'现在改一下按钮。')
  self.assertIsNone(resolver.preview(ID,1000))
  self.assertLessEqual(len(context.sentence('长'*200)),80)
  self.assertEqual(context.sentence('用 gpt-6.1-sol 看一下。第二句'),'用 gpt-6.1-sol 看一下。')
 def test_history_association_does_not_retain_images_or_irrelevant_payloads(self):
  # Repeated image-bearing user records used to keep all decoded images alive
  # until the entire conversation had been parsed.
  blob='X'*(128*1024)
  with self.path.open('w') as stream:
   for index in range(80):
    row=dict(timestamp=datetime.datetime.fromtimestamp(100+index,datetime.timezone.utc).isoformat(),
     type='response_item',payload=dict(role='user',content=[dict(type='input_text',text='用户%d'%index),
      dict(type='input_image',image_url='data:image/png;base64,'+blob)]))
    stream.write(json.dumps(row)+'\n')
   row=dict(timestamp=datetime.datetime.fromtimestamp(900.5,datetime.timezone.utc).isoformat(),
    type='response_item',payload=dict(type='message',role='assistant',content=[dict(type='output_text',text='完成检查。')]))
   stream.write(json.dumps(row)+'\n')
  tracemalloc.start()
  try:
   info=context.RequestContext(self.home).call_contexts([self.sample('one',900,901)],'one')
   peak=tracemalloc.get_traced_memory()[1]
  finally:tracemalloc.stop()
  self.assertEqual(info['one']['message'],'用户79')
  self.assertEqual(info['one']['content'][0]['text'],'完成检查。')
  self.assertLess(peak,6*1024*1024)
 def test_incremental_reads_and_unknown_sessions(self):
  resolver=self.fixture();resolver.preview(ID,1009)
  self.message(1020,'新的要求')
  self.assertEqual(resolver.preview(ID,1021),'新的要求')
  self.assertIsNone(resolver.preview('unknown',1021))
 def test_full_message_preserves_paragraphs_and_uses_request_start(self):
  resolver=self.fixture()
  full='帮我检查这个项目。后面的内容需要完整显示\n\n第二段：'+('完整文本'*100)
  self.message(1020,'# Files mentioned by the user:\n附件元数据\n## My request:\n'+full+'\n<image name="s">图片元数据</image>')
  self.message(1040,'稍后提出的新要求')
  self.assertEqual(resolver.message(ID,1030),full)
  self.assertLessEqual(len(resolver.preview(ID,1030)),80)
  self.assertEqual(resolver.message(ID,1009),'帮我检查这个项目。后面的内容不用显示')
  self.assertIsNone(resolver.message('unknown',1030))
 def test_message_ignores_system_tools_and_incomplete_lines(self):
  resolver=self.fixture()
  self.add(1020,'response_item',dict(role='assistant',content=[dict(text='助手文字')]))
  self.add(1021,'response_item',dict(role='tool',content=[dict(text='工具文字')]))
  self.message(1022,'<environment_context>环境</environment_context>')
  with self.path.open('a') as f:f.write('{"timestamp":')
  self.assertEqual(resolver.message(ID,1030),'现在改一下按钮。第二句')
 def test_legacy_websocket_identity_backfill_preserves_numbers(self):
  resolver=self.fixture();start,end=1002.,1005.
  identity=hashlib.sha256(('%s:a:%.6f:%.6f'%(ID,start,end)).encode()).hexdigest()
  sample=dict(id=identity,model='a',completedAt=end,durationSeconds=2.,ttftSeconds=1.,inputTokens=100,outputTokens=200,timingSource='websocket')
  before=sample.copy();resolver.enrich([sample])
  self.assertEqual(sample['conversationID'],ID)
  self.assertEqual(sample['promptPreview'],'帮我检查这个项目。')
  self.assertTrue(all(sample[k]==v for k,v in before.items()))
 def test_sse_backfill_requires_unique_usage_match(self):
  resolver=self.fixture()
  self.add(1005.01,'event_msg',dict(type='token_count',info=dict(last_token_usage=dict(input_tokens=100,output_tokens=200))))
  sample=dict(id='sse',model='a',completedAt=1005.,durationSeconds=2.,ttftSeconds=1.,inputTokens=100,outputTokens=200,timingSource='sse')
  resolver.enrich([sample]);self.assertEqual(sample['promptPreview'],'帮我检查这个项目。')
  second=self.path.with_name('rollout-019f0000-1111-7000-8000-000000000002.jsonl');second.write_text(self.path.read_text())
  ambiguous=dict(id='other',model='a',completedAt=1005.,durationSeconds=2.,ttftSeconds=1.,inputTokens=100,outputTokens=200,timingSource='sse')
  resolver.enrich([ambiguous]);self.assertNotIn('conversationID',ambiguous);self.assertNotIn('promptPreview',ambiguous)
 def sample(self,id,start,end,conversation=ID):
  return dict(id=id,model='a',conversationID=conversation,startedAt=start,completedAt=end,
              durationSeconds=end-start-1,ttftSeconds=1,inputTokens=100,outputTokens=200)
 def assistant(self,t,text):
  self.add(t,'response_item',dict(type='message',role='assistant',content=[dict(type='output_text',text=text)]))
 def test_api_loop_groups_user_once_and_keeps_each_output(self):
  self.add(1000,'event_msg',dict(type='task_started',turn_id='turn-1'))
  self.add(1000.01,'event_msg',dict(type='user_message',message='检查手机'))
  self.message(1000.02,'检查手机')
  self.assistant(1005,'正在核对支持情况。更多内容')
  self.add(1006,'response_item',dict(type='custom_tool_call',name='exec',input='检查命令'))
  self.add(1007,'response_item',dict(type='custom_tool_call_output',output='工具结果，不是模型输出'))
  self.add(1010,'response_item',dict(type='function_call',name='web_search',arguments='{"query":"camera"}'))
  self.assistant(1015,'最终结果支持 60fps。')
  samples=[self.sample('one',1001,1006.1),self.sample('two',1007.1,1010.1),self.sample('three',1011,1015.1)]
  original=json.loads(json.dumps(samples));resolver=context.RequestContext(self.home)
  info=resolver.call_contexts(samples,'one')
  self.assertEqual(len({v['groupID'] for v in info.values()}),1)
  self.assertEqual(info['one']['message'],'检查手机')
  self.assertEqual(info['one']['outputPreview'],'正在核对支持情况。')
  self.assertEqual([v['kind'] for v in info['one']['content']],['output','tool'])
  self.assertEqual(info['two']['outputPreview'],'调用 web_search')
  self.assertEqual(info['three']['outputPreview'],'最终结果支持 60fps。')
  self.assertNotIn('content',info['three']);self.assertEqual(samples,original)
 def test_identical_text_in_new_turn_or_conversation_does_not_merge(self):
  self.add(1000,'event_msg',dict(type='task_started',turn_id='first'));self.message(1001,'继续')
  self.add(1005,'event_msg',dict(type='task_complete',turn_id='first'))
  self.add(1010,'event_msg',dict(type='task_started',turn_id='second'));self.message(1011,'继续')
  other='019f0000-1111-7000-8000-000000000002'
  self.path.with_name('rollout-'+other+'.jsonl').write_text(self.path.read_text())
  info=context.RequestContext(self.home).call_contexts([
   self.sample('a',1002,1004),self.sample('b',1012,1014),self.sample('c',1012,1014,other)])
  self.assertEqual(len({v['groupID'] for v in info.values()}),3)
 def test_steering_message_in_same_turn_creates_new_group(self):
  self.add(1000,'turn_context',dict(turn_id='turn'))
  self.message(1001,'原要求');self.message(1010,'追加要求')
  info=context.RequestContext(self.home).call_contexts([self.sample('a',1002,1004),self.sample('b',1011,1014)])
  self.assertNotEqual(info['a']['groupID'],info['b']['groupID'])
 def test_background_or_missing_conversation_never_borrows_previous_user(self):
  self.add(1000,'event_msg',dict(type='task_started',turn_id='first'));self.message(1001,'用户要求')
  self.add(1005,'event_msg',dict(type='task_complete',turn_id='first'))
  self.add(1010,'event_msg',dict(type='task_started',turn_id='background'))
  self.assistant(1015,'后台输出')
  info=context.RequestContext(self.home).call_contexts([
   self.sample('gap',1006,1008),self.sample('bg',1011,1015.1),self.sample('missing',1011,1015.1,'missing')],'bg')
  self.assertNotIn('gap',info);self.assertNotIn('missing',info)
  self.assertNotIn('groupID',info['bg']);self.assertNotIn('message',info['bg'])
  self.assertEqual(info['bg']['outputPreview'],'后台输出')
 def test_next_request_boundary_and_overlaps_prevent_wrong_output(self):
  self.message(1000,'要求')
  self.assistant(1005.08,'属于第二次')
  samples=[self.sample('a',1001,1005),self.sample('b',1005.02,1009)]
  info=context.RequestContext(self.home).call_contexts(samples,'a')
  self.assertEqual(info['a']['content'],[]);self.assertEqual(info['b']['outputPreview'],'属于第二次')
  samples[1]['startedAt']=1004
  info=context.RequestContext(self.home).call_contexts(samples,'a')
  self.assertNotIn('outputPreview',info['b']);self.assertEqual(info['a']['content'],[])
 def test_reasoning_and_system_messages_are_never_displayed(self):
  self.message(1000,'要求')
  self.add(1003,'response_item',dict(type='reasoning',summary=[dict(text='私有推理')]))
  self.add(1003.1,'event_msg',dict(type='agent_reasoning',text='私有推理'))
  self.add(1003.2,'response_item',dict(type='message',role='system',content=[dict(type='output_text',text='系统提示')]))
  self.assistant(1004,'可见输出')
  info=context.RequestContext(self.home).call_contexts([self.sample('a',1001,1005)],'a')['a']
  self.assertEqual([v['text'] for v in info['content']],['可见输出'])
 def logs(self, records, target='codex_core::stream_events_utils'):
  with sqlite3.connect(self.home/'logs_2.sqlite') as db:
   db.execute('create table if not exists logs (ts integer,ts_nanos integer,thread_id text,target text,feedback_log_body text)')
   for t,conversation,body in records:
    db.execute('insert into logs values (?,?,?,?,?)',(int(t),round((t-int(t))*1e9),conversation,target,body))
 def submission(self,text):
  return 'Submission sub=Submission { id: "submission", op: TurnInput { request: TurnInputRequest { input: UserInput { content: [Text { text: "'+text
 def test_ephemeral_suggestion_has_source_without_exporting_internal_prompt(self):
  hidden='This is an app-generated request for a suggested next user message. SECRET_INTERNAL_INSTRUCTIONS'
  self.logs([(1000,ID,self.submission(hidden))],target='codex_core::session::handlers')
  sample=self.sample('background',1001,1005);before=sample.copy()
  info=context.RequestContext(self.home).call_contexts([sample],'background')['background']
  self.assertEqual(info['sourceKind'],'suggestion')
  self.assertEqual(info['outputPreview'],'后台 · 消息建议')
  self.assertNotIn('message',info);self.assertNotIn('groupID',info)
  self.assertNotIn(hidden,json.dumps(info));self.assertNotIn('SECRET',json.dumps(info))
  self.assertEqual(sample,before)
 def test_suggestion_requires_current_actual_submission_and_exact_conversation(self):
  hidden='This is an app-generated request for a suggested next user message.'
  self.logs([(1000,ID,self.submission(hidden)),(1002,ID,self.submission('普通用户消息')),
             (1010,ID,self.submission(hidden))],target='codex_core::session::handlers')
  resolver=context.RequestContext(self.home)
  self.assertNotIn('normal',resolver.call_contexts([self.sample('normal',1003,1005)]))
  self.assertNotIn('other',resolver.call_contexts([self.sample('other',1001,1005,'other')]))
  # A future submission and a suggestion more than an hour old cannot identify this call.
  self.assertNotIn('future',resolver.call_contexts([self.sample('future',999,999.5)]))
  self.assertNotIn('stale',resolver.call_contexts([self.sample('stale',5000,5005)]))
 def test_suggestion_does_not_classify_quoted_text_wrong_target_or_ordinary_rollout(self):
  hidden='This is an app-generated request for a suggested next user message.'
  self.logs([(1000,ID,self.submission('请解释这段文字：'+hidden))],target='codex_core::session::handlers')
  sample=self.sample('call',1001,1005)
  self.assertNotIn('call',context.RequestContext(self.home).call_contexts([sample]))
  self.logs([(1000.5,ID,self.submission(hidden))])  # Wrong log source.
  self.assertNotIn('call',context.RequestContext(self.home).call_contexts([sample]))
  self.logs([(1000.6,ID,self.submission(hidden))],target='codex_core::session::handlers')
  self.message(1000,'真正的用户消息');self.assistant(1004,'普通回复')
  info=context.RequestContext(self.home).call_contexts([sample],'call')['call']
  self.assertNotIn('sourceKind',info);self.assertEqual(info['message'],'真正的用户消息')
 def compacted(self,response='resp_compact',**overrides):
  usage=dict(input_tokens=100,output_tokens=200,reasoning_output_tokens=0,cached_input_tokens=80)
  usage.update(overrides)
  return dict(compaction_response_id=response,latest_token_usage_record=dict(
      response_id=response,thread_id=ID,usage=usage),
      replacement_history=[dict(role='system',text='SECRET_REPLACEMENT_HISTORY')],
      retained_context=dict(text='SECRET_RETAINED_CONTEXT'),message='SECRET_COMPACTION_TEXT')
 def test_compaction_requires_response_identity_and_exact_usage_and_keeps_parent(self):
  self.message(1000,'提交代码')
  self.add(1005.005,'compacted',self.compacted())
  sample=dict(self.sample('compact',1001,1005),reasoningTokens=0,cachedTokens=80)
  before=sample.copy();info=context.RequestContext(self.home).call_contexts([sample],'compact')['compact']
  self.assertEqual(info['sourceKind'],'compaction');self.assertEqual(info['outputPreview'],'自动压缩上下文')
  self.assertEqual(info['message'],'提交代码');self.assertIn('groupID',info)
  self.assertEqual(info['content'],[]);self.assertNotIn('SECRET',json.dumps(info));self.assertEqual(sample,before)
 def test_compaction_does_not_guess_missing_wrong_or_boolean_counters(self):
  sample=dict(self.sample('compact',1001,1005),reasoningTokens=0,cachedTokens=80)
  for field in ['input_tokens','output_tokens','reasoning_output_tokens','cached_input_tokens']:
   for invalid in [None,True,-1,900]:
    with self.subTest(field=field,invalid=invalid):
     self.rows=[];self.add(1005.01,'compacted',self.compacted(**{field:invalid}))
     self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([sample]))
  self.rows=[];self.add(1005.01,'compacted',self.compacted())
  for field in ['reasoningTokens','cachedTokens']:
   partial=sample.copy();del partial[field]
   self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([partial]))
 def test_compaction_rejects_wrong_identity_future_ambiguous_and_overlapping_records(self):
  sample=dict(self.sample('compact',1001,1005),reasoningTokens=0,cachedTokens=80)
  for field,value in [('response_id','another'),('thread_id','another')]:
   payload=self.compacted();payload['latest_token_usage_record'][field]=value
   self.rows=[];self.add(1005.01,'compacted',payload)
   self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([sample]))
  self.rows=[];self.add(1005.16,'compacted',self.compacted())
  self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([sample]))
  self.rows=[];self.add(1005.01,'compacted',self.compacted());self.add(1005.02,'compacted',self.compacted('other'))
  self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([sample]))
  self.rows=[];self.add(1005.01,'compacted',self.compacted())
  peer=dict(sample,id='peer',startedAt=1004)
  self.assertNotIn('compact',context.RequestContext(self.home).call_contexts([sample,peer]))
 def added(self, kind, model='a'):
  return 'turn{model='+model+'}:handle_responses{from="output_item_added"}: Output item item_type="'+kind+'"'
 def test_output_timing_ignores_reasoning_and_done_events(self):
  self.logs([(1002,ID,self.added('reasoning')),(1010,ID,self.added('message')),
             (1011,ID,'turn{model=a}:handle_responses{from="output_item_done"}:handle_output_item_done: Output item item_type="message"')])
  sample=self.sample('a',1001,1012)
  before=sample.copy();timing=context.output_timings(self.home,[sample])
  self.assertEqual(timing,{'a':2});self.assertEqual(sample,before)
 def test_output_timing_accepts_current_codex_arrival_marker_without_added_span(self):
  self.logs([(1010,ID,'turn{model=a}:try_run_sampling_request{model=a}: Output item item_type="message" item_id="msg_x"'),
             (1011,ID,'turn{model=a}:receiving_stream:handle_responses{from="output_item_done"}:handle_output_item_done: Output item item_type="message" item_id="msg_x"')])
  self.assertEqual(context.output_timings(self.home,[self.sample('a',1001,1012)]),{'a':2})
 def test_output_timing_supports_tools_and_does_not_borrow_other_calls(self):
  self.logs([(1000,ID,self.added('message')),(1002,ID,self.added('custom_tool_call')),
             (1006,ID,self.added('function_call')),(1007,ID,self.added('message','other')),
             (1009,ID,self.added('message'))])
  samples=[self.sample('a',1001,1004),self.sample('b',1005,1008)]
  self.assertEqual(context.output_timings(self.home,samples),{'a':2,'b':2})
  self.assertEqual(context.output_timings(self.home,[self.sample('missing',1001,1004,'missing')]),{})
 def test_output_timing_is_unavailable_for_missing_ambiguous_or_untyped_logs(self):
  samples=[self.sample('a',1001,1004),self.sample('b',1003,1006)]
  self.assertEqual(context.output_timings(self.home,samples),{})
  self.logs([(1002,ID,self.added('message')),(1003.5,ID,self.added('message'))])
  self.assertEqual(context.output_timings(self.home,samples),{})
  with sqlite3.connect(self.home/'logs_2.sqlite') as db:db.execute('delete from logs')
  self.logs([(1002,ID,'Output item item_type="message"'),(1002.5,ID,self.added('reasoning'))])
  self.assertEqual(context.output_timings(self.home,[samples[0]]),{})
 def test_partial_or_unsupported_first_output_cannot_borrow_later_item(self):
  self.logs([(1002,ID,'turn{model=a}:handle_output_item_done: Output item item_type="message"'),
             (1003,ID,self.added('message'))])
  self.assertEqual(context.output_timings(self.home,[self.sample('a',1001,1004)]),{})
  with sqlite3.connect(self.home/'logs_2.sqlite') as db:db.execute('delete from logs')
  self.logs([(1002,ID,self.added('unsupported_future_tool')),(1003,ID,self.added('message'))])
  self.assertEqual(context.output_timings(self.home,[self.sample('a',1001,1004)]),{})
 def test_invalid_request_boundaries_do_not_poison_other_requests(self):
  self.logs([(1002,ID,self.added('message'))])
  samples=[self.sample('good',1001,1004),self.sample('nan',float('nan'),1004),
           self.sample('reversed',1004,1001),dict(self.sample('missing',1001,1004),startedAt=None)]
  self.assertEqual(context.output_timings(self.home,samples),{'good':2})
if __name__=='__main__':unittest.main()
