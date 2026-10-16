#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_BUILD="$ROOT/.build/scroll-layout"
mkdir -p "$CHECK_BUILD/Checker.app/Contents/MacOS" "$CHECK_BUILD/Checker.app/Contents/Resources"
/usr/bin/python3 - "$CHECK_BUILD" <<'PY'
from pathlib import Path
import datetime, json, plistlib, sqlite3, sys
root = Path(sys.argv[1]); app = root / 'Checker.app'
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='local.wmy.ScrollLayoutCheck', CFBundleExecutable='Checker',
    CFBundleName='Scroll Layout Check', CFBundlePackageType='APPL', LSUIElement=True)))
(app / 'Contents/Resources/codex-swap.py').write_text(
    '''import json,time,sys
from pathlib import Path
now=time.time()
slots=[]
for name,plan,email,five,week,active in [('a','prolite','first@example.com',None,74,True),('b','pro','second@example.com',None,63,False),('c','team','third@example.com',100,90,False)]:
 slots.append(dict(name=name,plan=plan,email=email,active=active,five=five,week=week,five_reset_at=now+18000 if five is not None else None,week_reset_at=now+450000,fetched_at=now))
cache=Path(__file__).with_name('layout-slot-state.json')
if cache.exists():
 for row in slots:row.update(json.loads(cache.read_text()).get(row['name'],{}))
if 'quotas' in sys.argv:
 names=sys.argv[sys.argv.index('quotas')+1:]
 updates={name:dict(plan='free',five=100,week=None,five_window_seconds=2592000,week_window_seconds=None,five_reset_at=now+2592000,week_reset_at=None,fetched_at=now) for name in names}
 cache.write_text(json.dumps(updates))
 print(json.dumps(dict(ok=True,quotas=[dict(value,name=name,fresh=True) for name,value in updates.items()],failed=[])))
 raise SystemExit(0)
print(json.dumps(dict(ok=True,current='a',auth_exists=True,live=dict(plan='prolite',email='first@example.com'),warning=None,slots=slots)))
''')
(app / 'Contents/Resources/layout-slot-state.json').unlink(missing_ok=True)
(app / 'Contents/Resources/request-context.py').write_bytes((Path.cwd() / 'backend/request-context.py').read_bytes())
(app / 'Contents/Resources/tps-capture.py').write_bytes((Path.cwd() / 'backend/tps-capture.py').read_bytes())
sessions = root / 'fixtures/sessions'; sessions.mkdir(parents=True, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
lines = [dict(timestamp=now, type='session_meta', payload=dict(id='mock'))]
for index, model in enumerate(['codex-auto-review', 'gpt-6.1-sol']):
    lines.append(dict(timestamp=now, type='turn_context', payload=dict(model=model)))
    total = dict(input_tokens=(index+1)*1000, output_tokens=(index+1)*20, total_tokens=(index+1)*1020)
    last = dict(input_tokens=1000, output_tokens=20, total_tokens=1020)
    lines.append(dict(timestamp=now, type='event_msg', payload=dict(type='token_count',
                     info=dict(total_token_usage=total, last_token_usage=last))))
(sessions / 'mock.jsonl').write_text(''.join(json.dumps(line)+'\n' for line in lines))
stamp = datetime.datetime.now(datetime.timezone.utc).timestamp()
samples = [dict(id=str(index),model='gpt-6.1-sol',completedAt=stamp-index*20,
                outputTokens=rate*10+100,durationSeconds=10,nonReasoningDurationSeconds=10,inputTokens=10000,
                cachedTokens=8000,reasoningTokens=100,ttftSeconds=0.5)
           for index,rate in enumerate([80,70,65,55,40])]
samples.append(dict(id='review',model='codex-auto-review',completedAt=stamp-100,
                    outputTokens=260,durationSeconds=2,nonReasoningDurationSeconds=2,inputTokens=1000,
                    cachedTokens=800,reasoningTokens=20,ttftSeconds=0.3,
                    conversationID='019f0000-1111-7000-8000-000000000002',startedAt=stamp-103))
with sqlite3.connect(root / 'fixtures/logs_2.sqlite') as db:
    db.execute('create table if not exists logs (ts integer,ts_nanos integer,thread_id text,target text,feedback_log_body text)')
    db.execute('delete from logs')
    t = stamp - 104
    db.execute('insert into logs values (?,?,?,?,?)', (int(t),round((t-int(t))*1e9),
        samples[-1]['conversationID'],'codex_core::session::handlers',
        'Submission sub=Submission { id: "suggestion", op: TurnInput { request: TurnInputRequest { input: UserInput { content: [Text { text: "This is an app-generated request for a suggested next user message. PRIVATE_INSTRUCTIONS'))
samples[0]['serviceTier'] = 'priority'
samples[1]['serviceTier'] = 'fast'
samples[0]['promptPreview'] = '统计详情按钮小了一点，这个挺常用的'
samples[1]['promptPreview'] = '帮我检查这个项目。'
conversation = '019f0000-1111-7000-8000-000000000001'
for index in [0, 1, 2]:
    samples[index]['conversationID'] = conversation
    samples[index]['startedAt'] = samples[index]['completedAt'] - 11
messages = [
    (stamp-55, '这是一条长消息，请检查每项数字。\n\n'+''.join('第%d段：保留完整文本，并在文本区域内滚动查看。\n'%i for i in range(1,31))+'完整消息末尾'),
    (stamp-15, '统计详情按钮小了一点，这个挺常用的。\n\n退出按钮与上面的按钮对齐；模型下拉框对齐第二列。\n请展示完整发起消息，保留段落和后半部分内容，不要只显示第一句话。'),
]
context_lines = [dict(timestamp=datetime.datetime.fromtimestamp(t,datetime.timezone.utc).isoformat(),
    type='response_item',payload=dict(type='message',role='user',content=[dict(type='input_text',text=text)])) for t,text in messages]
for index, text in [(0,'已调整按钮和对齐。现在继续验证界面。'), (1,'正在核对项目中的原始数据。')]:
    context_lines.append(dict(timestamp=datetime.datetime.fromtimestamp(samples[index]['completedAt']-.2,datetime.timezone.utc).isoformat(),
        type='response_item',payload=dict(type='message',role='assistant',content=[dict(type='output_text',text=text)])))
context_lines.append(dict(timestamp=datetime.datetime.fromtimestamp(samples[2]['completedAt']-.2,datetime.timezone.utc).isoformat(),
    type='response_item',payload=dict(type='custom_tool_call',name='exec',input='运行项目检查')))
context_lines.sort(key=lambda row: row['timestamp'])
(sessions / ('rollout-'+conversation+'.jsonl')).write_text(''.join(json.dumps(row)+'\n' for row in context_lines))
samples += [dict(id=model,model=model,completedAt=stamp-200,
                 outputTokens=120,durationSeconds=2,nonReasoningDurationSeconds=2,inputTokens=1000,
                 cachedTokens=500,reasoningTokens=20,ttftSeconds=0.3)
            for model in ['gpt-5.6-terra','gpt-5.6-luna','gpt-6-luna']]
compact = next(s for s in samples if s['id'] == 'gpt-5.6-terra')
compact['conversationID'] = '019f0000-1111-7000-8000-000000000003'
compact['startedAt'] = compact['completedAt'] - 3
compact_lines = [dict(timestamp=datetime.datetime.fromtimestamp(compact['startedAt']-1,datetime.timezone.utc).isoformat(),
    type='response_item',payload=dict(role='user',content=[dict(type='input_text',text='继续检查项目')])),
    dict(timestamp=datetime.datetime.fromtimestamp(compact['completedAt']+.01,datetime.timezone.utc).isoformat(),
    type='compacted',payload=dict(compaction_response_id='response_compact',latest_token_usage_record=dict(
        response_id='response_compact',thread_id=compact['conversationID'],usage=dict(
            input_tokens=1000,output_tokens=120,reasoning_output_tokens=20,cached_input_tokens=500)),
        replacement_history=[dict(role='system',text='PRIVATE_CONTEXT')]))]
(sessions / ('rollout-'+compact['conversationID']+'.jsonl')).write_text(''.join(json.dumps(row)+'\n' for row in compact_lines))
samples += [dict(id=str(index),model='gpt-6.1-sol',completedAt=stamp-index*20,
                 outputTokens=index,durationSeconds=10,inputTokens=10000,
                 cachedTokens=1000,reasoningTokens=0,ttftSeconds=1.5)
            for index in range(5,120)]
(root / 'fixtures/speeds.json').write_text(json.dumps(dict(samples=samples)))
PY
SDK="$(xcrun --show-sdk-path)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
APP_SOURCES=()
for source in "$ROOT/app/"*.swift; do
    if [ "$(basename "$source")" != CodexSwapApp.swift ]; then APP_SOURCES+=("$source"); fi
done
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" \
    -module-cache-path "$CHECK_BUILD/ModuleCache" \
    "${APP_SOURCES[@]}" "$ROOT/app/Telemetry/"*.swift \
    "$ROOT/tests/scroll-layout-check.swift" -o "$CHECK_BUILD/Checker.app/Contents/MacOS/Checker"
"$CHECK_BUILD/Checker.app/Contents/MacOS/Checker" "$CHECK_BUILD"
