"""Resolve local initiating messages; previews are bounded, full text is read on demand."""
import datetime
from collections import OrderedDict
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import time

UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
RECORD_HEADER = re.compile(br'^\s*\{[^{}]*?"type"\s*:\s*"([^"\\]+)"\s*,\s*"payload"\s*:\s*\{')
IMAGE_DATA_START = re.compile(br'("image_url"\s*:\s*")data:image/')

def without_image_data(line):
    """Omit image-only JSON values before decoding; preserve all text fields."""
    parts, cursor = [], 0
    for match in IMAGE_DATA_START.finditer(line):
        end = line.find(b'"', match.end())
        if end < 0 or line.find(b'\\', match.end(1), end) >= 0: continue
        parts.append(line[cursor:match.end(1)])
        cursor = end
    return b''.join(parts + [line[cursor:]]) if parts else line

CALL_SOURCES = {
    'suggestion': ('后台 · 消息建议', 'Codex 自动生成输入框中的下一条消息建议。该后台调用没有保存可读取的普通回复文本。'),
    'compaction': ('自动压缩上下文', 'Codex 自动整理当前对话的历史上下文。结果以压缩记录保存，不作为普通聊天回复展示。'),
}
SUGGESTION_INPUT = re.compile(
    r'\bSubmission sub=Submission \{ id: "[^"\n]+", op: TurnInput \{ request: TurnInputRequest '
    r'\{ input: UserInput \{ content: \[Text \{ text: "'
    r'This is an app-generated request for a suggested next user message\.')

def source_context(kind):
    title, description = CALL_SOURCES[kind]
    return dict(sourceKind=kind, sourceTitle=title, sourceDescription=description,
                outputPreview=title, outputKind=kind)

def thread_metadata(home, conversations):
    """Read bounded, exact-ID display metadata. Never scan conversation text."""
    ids=sorted({id for id in conversations if isinstance(id,str) and id})
    candidates={}
    for database in sorted(Path(home).glob('state_*.sqlite')):
        try:
            with closing(sqlite3.connect(database.resolve().as_uri()+'?mode=ro',uri=True,timeout=.25)) as connection:
                columns={row[1] for row in connection.execute('pragma table_info(threads)')}
                title='title' if 'title' in columns else 'NULL'
                cwd='cwd' if 'cwd' in columns else 'NULL'
                for offset in range(0,len(ids),400):
                    batch=ids[offset:offset+400]
                    for id,name,project in connection.execute('select id,'+title+','+cwd+' from threads where id in ('+
                                                              ','.join('?' for _ in batch)+')',batch):
                        item={key:value for key,value in [('conversationTitle',name),('projectPath',project)]
                              if isinstance(value,str) and value.strip()}
                        if item:candidates.setdefault(id,[]).append(item)
        except (sqlite3.Error,OSError):continue
    return {id:{key:values[0][key] for key in ('conversationTitle','projectPath')
                if key in values[0] and all(value.get(key)==values[0][key] for value in values)}
            for id,values in candidates.items()}

def thread_lineage(home, ids):
    """Exact-ID source metadata; never infer ancestry from names or timestamps."""
    candidates = {}
    ids = sorted({x for x in ids if isinstance(x, str) and UUID.fullmatch(x)})
    for database in sorted(Path(home).glob('state_*.sqlite')):
        try:
            with closing(sqlite3.connect(database.resolve().as_uri()+'?mode=ro', uri=True, timeout=.25)) as db:
                columns = {r[1] for r in db.execute('pragma table_info(threads)')}
                fields = ['source','thread_source','agent_path','agent_nickname']
                selection = ','.join(f if f in columns else 'NULL' for f in fields)
                for offset in range(0,len(ids),400):
                    batch = ids[offset:offset+400]
                    for cid, raw, source, path, nickname in db.execute(
                        'select id,'+selection+' from threads where id in ('+','.join('?' for _ in batch)+')',batch):
                        try: value = json.loads(raw) if isinstance(raw,str) else None
                        except ValueError: value = None
                        agent = value.get('subagent') if isinstance(value,dict) else None
                        spawn = agent.get('thread_spawn',{}) if isinstance(agent,dict) else {}
                        if not isinstance(spawn,dict): spawn = {}
                        parent = spawn.get('parent_thread_id')
                        parent = parent if isinstance(parent,str) and UUID.fullmatch(parent) else None
                        agent_path = path or spawn.get('agent_path')
                        item = dict(subagent=source=='subagent' or bool(spawn), parent=parent,
                                    path=agent_path if isinstance(agent_path,str) else None,
                                    nickname=nickname if isinstance(nickname,str) else None)
                        candidates.setdefault(cid,[]).append(item)
        except (sqlite3.Error,OSError,TypeError): continue
    result = {}
    for cid, values in candidates.items():
        if all(x==values[0] for x in values): result[cid]=values[0]
        elif any(x['subagent'] for x in values): result[cid]=dict(subagent=True,parent=None,path=None,nickname=None)
    return result

USAGE_FIELDS = ('input_tokens','output_tokens','reasoning_output_tokens','cached_input_tokens')
SAMPLE_USAGE_FIELDS = ('inputTokens','outputTokens','reasoningTokens','cachedTokens')

def usage_identity(value, fields=USAGE_FIELDS):
    if not isinstance(value,dict): return None
    counts = tuple(value.get(k) for k in fields)
    if not all(type(n) is int and 0 <= n <= 2**63-1 for n in counts): return None
    if counts[2]>counts[1] or counts[3]>counts[0]: return None
    return counts

def suggestion_sources(home, samples):
    """Only called for conversations without rollouts; never export their internal prompts."""
    database = Path(home) / 'logs_2.sqlite'
    if not database.exists(): return {}
    by_conversation = {}
    for sample in samples:
        start = sample.get('startedAt')
        if (isinstance(sample.get('conversationID'), str) and sample['conversationID'] and
            type(start) in (int, float) and math.isfinite(start)):
            by_conversation.setdefault(sample['conversationID'], []).append(sample)
    result = {}
    try:
        with closing(sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True, timeout=.25)) as connection:
            for conversation, calls in by_conversation.items():
                low = int(min(call['startedAt'] for call in calls)) - 3600
                high = int(max(call['startedAt'] for call in calls)) + 1
                rows = connection.execute(
                    'select ts,ts_nanos,substr(feedback_log_body,1,4096) from logs '
                    'where thread_id=? and target=? and ts between ? and ? '
                    'and feedback_log_body like ? order by ts desc,ts_nanos desc',
                    (conversation, 'codex_core::session::handlers', low, high,
                     '%Submission sub=Submission%op: TurnInput%')).fetchall()
                for call in calls:
                    # The nearest submission establishes this call's purpose. Do not
                    # search older matching prompts past a newer ordinary submission.
                    eligible = [(ts + ns / 1e9, body) for ts, ns, body in rows
                                if call['startedAt'] - 3600 <= ts + ns / 1e9 <= call['startedAt']]
                    if not eligible: continue
                    when, body = eligible[0]
                    if sum(t == when for t, _ in eligible) != 1: continue
                    if isinstance(body, str) and SUGGESTION_INPUT.search(body):
                        result[call['id']] = source_context('suggestion')
    except (sqlite3.Error, OSError, ValueError, TypeError, KeyError):
        return {}  # Unknown or unavailable evidence remains explicitly unclassified.
    return result

def compaction_matches(payload, sample):
    """Require a response identity and all four explicit, exact API usage counters."""
    record = payload.get('latest_token_usage_record')
    response = payload.get('compaction_response_id')
    if not isinstance(record, dict) or not isinstance(response, str) or not response: return False
    if record.get('response_id') != response or record.get('thread_id') != sample.get('conversationID'): return False
    usage = record.get('usage')
    if not isinstance(usage, dict): return False
    for raw, field in [('input_tokens', 'inputTokens'), ('output_tokens', 'outputTokens'),
                       ('reasoning_output_tokens', 'reasoningTokens'), ('cached_input_tokens', 'cachedTokens')]:
        value, expected = usage.get(raw), sample.get(field)
        if type(value) is not int or type(expected) is not int or value < 0 or value != expected: return False
    return True

def message_text(text):
    if not isinstance(text,str): return None
    if '## My request:' in text: text=text.split('## My request:',1)[1]
    elif '# My request:' in text: text=text.split('# My request:',1)[1]
    elif text.lstrip().startswith(('<environment_context>','<external_codex_apps_open_page>','# AGENTS.md','# Files mentioned by the user:')): return None
    if '<send_user_message_question_reply>' in text:
        try:
            replies=json.loads(text.split('<send_user_message_question_reply>',1)[1].split('</',1)[0])
            text='\n'.join(x.get('answer','') for x in replies)
        except (ValueError,TypeError,AttributeError):return None
    text=re.sub(r'<image\b[^>]*>.*?</image>','',text,flags=re.S)
    text='\n'.join(x for x in text.splitlines() if not x.lstrip().startswith('<image')).strip()
    return text if text and not text.startswith('<') else None

def sentence(text):
    text=message_text(text)
    if text is None:return None
    lines=[x.strip() for x in text.splitlines() if x.strip()]
    if not lines:return None
    first=re.sub(r'^#{1,6}\s+','',lines[0])
    m=re.search(r'[。！？!?]|\.(?=\s|$)',first)
    if m:first=first[:m.end()]
    first=' '.join(first.split())
    if first.startswith('<') or not first:return None
    return first if len(first)<=80 else first[:79]+'…'

def output_timings(home, samples):
    """Resolve typed non-reasoning output starts from local Codex logs.

    TTFT and raw output_item.added can point to a reasoning item. Only an
    explicit added message/function/custom-tool item establishes this boundary.
    Return numeric durations only; never export or persist the log bodies.
    """
    database = Path(home) / 'logs_2.sqlite'
    if not database.exists(): return {}
    by_conversation = {}
    for sample in samples:
        if not isinstance(sample, dict): continue
        conversation = sample.get('conversationID')
        start, end = sample.get('startedAt'), sample.get('completedAt')
        if (isinstance(conversation, str) and conversation and isinstance(sample.get('model'), str) and
            isinstance(sample.get('id'), str) and sample['id'] and
            type(start) in (int, float) and type(end) in (int, float) and
            math.isfinite(start) and math.isfinite(end) and 0 < end-start <= 3600):
            by_conversation.setdefault(conversation, []).append(sample)
    result = {}
    frozen_stamp = None
    wal = Path(str(database) + '-wal')
    uri = database.resolve().as_uri() + '?mode=ro'
    try:
        try:
            connection = sqlite3.connect(uri, uri=True, timeout=.25)
        except sqlite3.Error:
            # Some bundled SQLite builds cannot open a closed WAL-mode DB
            # read-only after its WAL/SHM files were removed. A stable,
            # checkpointed file can be read without creating journal files.
            if wal.exists(): return {}
            stat = database.stat()
            frozen_stamp = (stat.st_size, stat.st_mtime_ns)
            connection = sqlite3.connect(uri + '&immutable=1', uri=True, timeout=.25)
        with connection:
            for conversation, calls in by_conversation.items():
                low = int(min(call['startedAt'] for call in calls))
                high = int(max(call['completedAt'] for call in calls)) + 1
                rows = connection.execute(
                    'select ts,ts_nanos,feedback_log_body from logs where thread_id=? '
                    'and target=? and ts between ? and ? '
                    'and feedback_log_body like ? order by ts,ts_nanos',
                    (conversation, 'codex_core::stream_events_utils', low, high, '%Output item item_type=%')).fetchall()
                starts, arrivals, earlier_untrusted = [], [], []
                for seconds, nanos, body in rows:
                    if not isinstance(body, str): continue
                    leaf = body.rsplit('}:', 1)[-1].strip()
                    item = re.match(r'^Output item item_type="(message|function_call|custom_tool_call)"', leaf)
                    models = re.findall(r'\bmodel=(?:"([^"\n]+)"|([^\s}:]+))', body)
                    if item and models:
                        model = next((quoted or plain for quoted, plain in reversed(models)), None)
                        starts.append((seconds + nanos / 1e9, model))
                    elif models:
                        model = next((quoted or plain for quoted, plain in reversed(models)), None)
                        # A completed non-reasoning item with no earlier arrival,
                        # or an unsupported output type, means we cannot establish
                        # the first output boundary from a later item alone.
                        done = re.match(r'^handle_output_item_done: Output item item_type="(message|function_call|custom_tool_call)"', leaf)
                        other = re.match(r'^Output item item_type="([^"]+)"', leaf)
                        if done or (other and other.group(1) != 'reasoning'):
                            earlier_untrusted.append((seconds + nanos / 1e9, model))
                    if models and re.match(r'^Output item item_type="', leaf):
                        arrivals.append((seconds + nanos / 1e9,
                                         next((quoted or plain for quoted, plain in reversed(models)), None)))
                for call in calls:
                    start, end = call['startedAt'], call['completedAt']
                    if any(other['id'] != call['id'] and other['model'] == call['model'] and
                           other['startedAt'] < end and other['completedAt'] > start for other in calls):
                        continue
                    # Consumer logs can be buffered long after the network has
                    # received output. Never mix their late start with the
                    # transport end. Require the first item on both timelines
                    # to agree within 10 ms (transport timestamps use ms).
                    duration = call.get('durationSeconds')
                    if type(duration) not in (int, float) or not math.isfinite(duration) or not 0 < duration <= end-start:
                        continue
                    first_items = [when for when, model in arrivals if model == call['model'] and start <= when < end]
                    if not first_items or abs(min(first_items) - (end - duration)) > .010:
                        continue
                    eligible = [when for when, model in starts if model == call['model'] and start <= when < end]
                    if eligible:
                        first = min(eligible)
                        if any(model == call['model'] and start <= when < first for when, model in earlier_untrusted): continue
                        duration = end - first
                        if .001 <= duration <= 3600: result[call['id']] = duration
        connection.close()
        if frozen_stamp is not None:
            stat = database.stat()
            if wal.exists() or (stat.st_size, stat.st_mtime_ns) != frozen_stamp: return {}
    except (sqlite3.Error, OSError, ValueError, TypeError, KeyError):
        return {}  # Missing/locked/older logs leave the timing explicitly unavailable.
    return result

class RolloutIndex:
    """Volatile, bounded association facts. No TPS calculations or timing cache.

    Full text stays in the rollout; offsets are used only after checking the
    file identity. An idle worker blocks on stdin, without a refresh timer.
    """
    MAX_FILES = 96
    MAX_FACTS = 24000

    def __init__(self):
        self.files = OrderedDict()
        self.read_bytes = 0  # Diagnostic/test counter; never persisted.

    @staticmethod
    def stamp(stat):
        return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)

    @staticmethod
    def decode(line):
        header = RECORD_HEADER.match(line[:512])
        if header:
            root = header.group(1)
            if root not in (b'response_item', b'event_msg', b'turn_context', b'compacted', b'session_meta'): return None
            if root == b'response_item' and re.match(
                br'\s*"type"\s*:\s*"(?:reasoning|function_call_output|custom_tool_call_output)"\s*[,}]',
                line[header.end():header.end()+128]): return None
        if b'"image_url"' in line and b'data:image/' in line: line = without_image_data(line)
        try:
            item = json.loads(line)
            when = datetime.datetime.fromisoformat(item['timestamp'].replace('Z', '+00:00')).timestamp()
            kind, payload = item.get('type'), item.get('payload', {})
            if isinstance(payload, dict): return when, kind, payload
        except (ValueError, KeyError, TypeError): pass
        return None

    @staticmethod
    def compact(kind, payload):
        if kind == 'turn_context': return dict(turn_id=payload.get('turn_id'))
        if kind == 'event_msg':
            event = payload.get('type')
            if event in ('task_started', 'task_complete'):
                result = dict(type=event,turn_id=payload.get('turn_id'))
                attribution = payload.get('turn_attribution')
                if event == 'task_started' and isinstance(attribution,dict):
                    result['turn_attribution'] = {k:attribution.get(k) for k in
                        ('turn_id','parent_turn_id','root_turn_id') if isinstance(attribution.get(k),str)}
                return result
            if event == 'token_count':
                info = payload.get('info')
                key = usage_identity(info.get('last_token_usage')) if isinstance(info,dict) else None
                return dict(type=event,usage=key) if key is not None else None
            if event == 'item_completed':
                item = payload.get('item')
                if isinstance(item,dict) and item.get('type')=='SubAgentActivity' and item.get('kind') in ('started','interacted'):
                    return dict(type=event,thread_id=payload.get('thread_id'),turn_id=payload.get('turn_id'),
                        child=item.get('agent_thread_id'))
            if event != 'user_message': return None
            text = message_text(payload.get('message'))
            if text: return dict(type=event, message=sentence(text) or text[:80], dedup=hashlib.sha256(text.encode()).hexdigest())
        if kind == 'response_item':
            role, output = payload.get('role'), payload.get('type')
            if role == 'user':
                text = message_text('\n'.join(x.get('text', '') for x in payload.get('content', []) if isinstance(x, dict)))
                if text: return dict(role=role, content=[dict(text=sentence(text) or text[:80])], dedup=hashlib.sha256(text.encode()).hexdigest())
            elif output == 'message' and role == 'assistant':
                text = '\n'.join(x.get('text', '') for x in payload.get('content', [])
                    if isinstance(x, dict) and x.get('type') in ('output_text', 'text'))
                return dict(type=output, role=role, content=[dict(type='output_text', text=sentence(text) or text[:80])])
            elif output in ('function_call', 'custom_tool_call'):
                return dict(type=output, name=(payload.get('name') or '未记录名称')[:256], arguments='')
        if kind == 'compacted':
            # Retain only the exact identity/counters checked by compaction_matches.
            record = payload.get('latest_token_usage_record')
            if not isinstance(record, dict): return None
            usage = record.get('usage')
            if not isinstance(usage, dict): return None
            return dict(compaction_response_id=payload.get('compaction_response_id'), latest_token_usage_record={
                **{k: record.get(k) for k in ('response_id', 'thread_id')},
                'usage': {k: usage.get(k) for k in ('input_tokens', 'output_tokens', 'reasoning_output_tokens', 'cached_input_tokens')}})
        return None

    def records(self, path):
        import os
        with path.open('rb') as stream:
            stat = os.fstat(stream.fileno())
            stamp = self.stamp(stat)
            state = self.files.pop(path, None)
            if state and stamp == state['stamp']:
                self.files[path] = state
                return state['records']
            # Rollouts are append-only. Replaced, shortened or rewritten files
            # invalidate offsets. Check both ends of the indexed prefix as well.
            reusable = state and stamp[:2] == state['stamp'][:2] and stamp[2] > state['stamp'][2]
            if reusable:
                for offset, expected in state['guards']:
                    stream.seek(offset)
                    actual = stream.read(len(expected)); self.read_bytes += len(actual)
                    if actual != expected: reusable = False; break
            if not reusable: state = dict(offset=0, records=[])
            stream.seek(state['offset'])
            while stream.tell() < stat.st_size:
                offset = stream.tell()
                line = stream.readline(); self.read_bytes += len(line)
                if not line.endswith(b'\n') or stream.tell() > stat.st_size: break
                state['offset'] = stream.tell()
                decoded = self.decode(line)
                if decoded is None: continue
                when, kind, payload = decoded
                if kind=='session_meta' and offset==0: state['session']=payload.get('id')
                if kind=='event_msg' and payload.get('type')=='task_started':
                    attribution = payload.get('turn_attribution')
                    state['subtask_turn'] = payload.get('turn_id') if isinstance(attribution,dict) and attribution.get('parent_turn_id') else None
                # Usage facts are needed only for explicitly attributed child
                # turns. Keeping every ordinary token-count update would evict
                # warm conversation caches and repeatedly scan large rollouts.
                if kind=='event_msg' and payload.get('type')=='token_count' and (
                    not state.get('subtask_turn') or state.get('subtask_turn')!=state.get('turn')): continue
                kept = self.compact(kind, payload)
                if kept is not None:
                    if kept.get('turn_id') and (kind=='turn_context' or
                        (kind=='event_msg' and kept.get('type')=='task_started')):
                        state['turn'] = kept['turn_id']
                    kept['_turn'] = state.get('turn')
                    kept['_session'] = state.get('session')
                    # Only references and short text survive this iteration.
                    kept['_ref'] = (path, stamp[:2], offset, hashlib.sha256(line).digest())
                    state['records'].append((when, kind, kept))
                    if kind=='event_msg' and kept.get('type')=='task_complete' and kept.get('turn_id') in (None,state.get('turn')):
                        state['turn'] = None
            after = self.stamp(os.fstat(stream.fileno()))
            current = self.stamp(path.stat())
            if (after != current or after[:2] != stamp[:2] or after[2] < stamp[2] or
                (after[2] == stamp[2] and after != stamp)):
                raise OSError('Rollout changed while indexing')
            # If an append raced this read, remember the original size so that
            # the next request reads its suffix rather than trusting a new stamp.
            state['stamp'] = stamp
            state['guards'] = []
            for offset in dict.fromkeys((0, max(0, state['offset'] - 512))):
                stream.seek(offset)
                value = stream.read(min(512, state['offset'] - offset)); self.read_bytes += len(value)
                state['guards'].append((offset, value))
        self.files[path] = state
        records = state['records']
        while len(self.files) > self.MAX_FILES or sum(len(v['records']) for v in self.files.values()) > self.MAX_FACTS:
            self.files.popitem(last=False)
        return records

    def full(self, reference):
        import os
        path, identity, offset, digest = reference
        with path.open('rb') as stream:
            if self.stamp(os.fstat(stream.fileno()))[:2] != identity: raise OSError('Replaced rollout')
            stream.seek(offset)
            line = stream.readline(); self.read_bytes += len(line)
            if hashlib.sha256(line).digest() != digest: raise OSError('Changed rollout record')
            decoded = self.decode(line)
            if decoded is None: raise OSError('Missing rollout record')
            return decoded[2]


class TaskAttribution:
    """Display-only proof chain. No timing-based parent selection or numeric writes."""
    def __init__(self, owner):
        self.owner, self.meta, self.cache = owner, {}, {}

    def facts(self, conversation):
        if conversation in self.cache: return self.cache[conversation]
        paths = self.owner.paths.get(conversation,[])
        # One thread can span several rollout files. Trust their session ID,
        # not a UUID-looking filename. Deduplicate replicated facts, retaining
        # distinct usage events so identical counters remain ambiguous.
        records = []
        try:
            for path in sorted(paths):
                for when,kind,payload in self.owner.index.records(path):
                    if payload.get('_session')!=conversation: continue
                    records.append((when,kind,payload))
        except (OSError,ValueError): self.cache[conversation]=None; return None
        users, tasks, usages, links, active = [], {}, {}, {}, {}
        previous_path = None
        for when, kind, payload in records:
            turn = payload.get('_turn')
            path = payload['_ref'][0]
            if path!=previous_path: active={}; previous_path=path
            if kind=='event_msg' and payload.get('type')=='task_started':
                tasks.setdefault(payload.get('turn_id'),[]).append(payload.get('turn_attribution',{}))
            elif kind=='event_msg' and payload.get('type')=='task_complete':
                active.pop(payload.get('turn_id') or turn,None)
            elif kind=='event_msg' and payload.get('type')=='token_count':
                copies = usages.setdefault(tuple(payload['usage']),{}).setdefault((when,turn),{})
                copies[path]=copies.get(path,0)+1
            elif kind=='event_msg' and payload.get('type')=='item_completed':
                if payload.get('thread_id')==conversation and turn==payload.get('turn_id'):
                    links.setdefault((payload.get('child'),turn),[]).append(active.get(turn))
            source = None
            if kind=='response_item' and payload.get('role')=='user':
                text = message_text('\n'.join(x.get('text','') for x in payload.get('content',[]) if isinstance(x,dict)))
                source = 'response'
            elif kind=='event_msg' and payload.get('type')=='user_message':
                text, source = message_text(payload.get('message')), 'event'
            if source and text:
                user = dict(time=when,turn=turn,text=text,source=source,
                    dedup=payload.get('dedup'),reference=payload.get('_ref'))
                users.append(user); active[turn]=user
        def canonical(user):
            if user and user['source']=='event':
                matches = [v for v in users if v['source']=='response' and v['turn']==user['turn'] and
                    v['dedup']==user['dedup'] and abs(v['time']-user['time'])<2]
                if len({(x['time'],x['dedup']) for x in matches})==1: return matches[0]
            return user
        links = {key:[canonical(user) for user in candidates] for key,candidates in links.items()}
        users = [u for u in users if u['source']!='event' or not any(
            v['source']=='response' and v['turn']==u['turn'] and v['dedup']==u['dedup'] and
            abs(v['time']-u['time'])<2 for v in users)]
        result = dict(users=users,tasks=tasks,usages={k:[turn for (_,turn),copies in v.items()
            for _ in range(max(copies.values()))] for k,v in usages.items()},links=links)
        self.cache[conversation]=result
        return result

    def user(self, conversation, turn, visited=(), dispatched_user=None):
        pair = (conversation,turn)
        if pair in visited or len(visited)>=4: return None,'subtask_cycle'
        meta, facts = self.meta.get(conversation), self.facts(conversation)
        if not meta or not facts or not turn or turn not in facts['tasks']: return None,'subtask_parent_missing'
        if not meta['subagent']:
            if not dispatched_user: return None,'subtask_user_ambiguous'
            return dict(conversation=conversation,turn=turn,user=dispatched_user),None
        attributes = facts['tasks'][turn]
        if not attributes or any(a!=attributes[0] for a in attributes): return None,'subtask_turn_conflict'
        attribution = attributes[0]
        if attribution.get('turn_id')!=turn: return None,'subtask_turn_conflict'
        parent, parent_turn = meta.get('parent'), attribution.get('parent_turn_id')
        parent_facts = self.facts(parent) if parent else None
        if not parent_facts or (conversation,parent_turn) not in parent_facts['links']:
            return None,'subtask_dispatch_missing'
        # The explicit dispatch's record position identifies the active human
        # message. Later steering messages in the same turn cannot steal it.
        # Repeated dispatches pointing at different humans remain ambiguous.
        candidates = parent_facts['links'][(conversation,parent_turn)]
        identities = {(u['time'],u['dedup']) if u else None for u in candidates}
        if not self.meta.get(parent,{}).get('subagent') and (len(identities)!=1 or None in identities):
            return None,'subtask_user_ambiguous'
        result, issue = self.user(parent,parent_turn,visited+(pair,),candidates[0])
        if result and attribution.get('root_turn_id') not in (None,result['turn']):
            return None,'subtask_turn_conflict'
        return result,issue

    def apply(self, samples, result, full_id):
        ids = {s.get('conversationID') for s in samples}
        self.meta.update(thread_lineage(self.owner.home,ids))
        if not any(m['subagent'] for m in self.meta.values()): return result
        for _ in range(4):
            parents = {m['parent'] for m in self.meta.values() if m.get('parent') and m['parent'] not in self.meta}
            if not parents or len(parents)>64: break
            found = thread_lineage(self.owner.home,parents)
            if not found: break
            self.meta.update(found)
        peers = {}
        for s in samples:
            peers.setdefault((s.get('conversationID'),usage_identity(s,SAMPLE_USAGE_FIELDS)),[]).append(s['id'])
        root_metadata = thread_metadata(self.owner.home,self.meta)
        for sample in samples:
            conversation = sample.get('conversationID')
            meta = self.meta.get(conversation)
            if not meta or not meta['subagent']: continue
            info = result.setdefault(sample['id'],{})
            if info.get('sourceKind') in CALL_SOURCES:
                info['callSource']=dict(kind='source',title=info['sourceTitle'],text=info['sourceDescription'])
            for key in ('groupID','groupPreview','groupTimestamp','message'): info.pop(key,None)
            path = meta.get('path')
            title = path.rstrip('/').rsplit('/',1)[-1] if path else meta.get('nickname') or '子任务'
            info.update(sourceKind='subagent',sourceTitle='子任务',subtaskTitle=title[:120],
                sourceDescription='已确认子任务，用户消息待关联。')
            if meta.get('parent'): info['parentConversationID']=meta['parent']
            facts = self.facts(conversation)
            key = usage_identity(sample,SAMPLE_USAGE_FIELDS)
            matches = facts['usages'].get(key,[]) if facts and key is not None else []
            if len(matches)!=1 or len(peers[(conversation,key)])!=1 or not matches[0]:
                info['associationIssue']='subtask_usage_ambiguous'; continue
            turn = matches[0]
            info.update(subtaskID=hashlib.sha256((conversation+':'+turn).encode()).hexdigest(),subtaskTurnID=turn)
            root, issue = self.user(conversation,turn)
            if root is None:
                info['associationIssue']=issue; continue
            user, cid = root['user'], root['conversation']
            identity = '%s:%s:%.6f' % (cid,root['turn'],user['time'])
            info.update(groupID=hashlib.sha256(identity.encode()).hexdigest(),groupPreview=sentence(user['text']),
                groupTimestamp=user['time'],rootConversationID=cid,
                sourceDescription='由主会话明确派发的子任务。',
                attributionEvidence='子会话标识、四项用量唯一匹配及派发轮次一致。')
            if info.get('associationIssue') not in ('overlap','no_output'): info.pop('associationIssue',None)
            if root_metadata.get(cid,{}).get('conversationTitle'): info['rootConversationTitle']=root_metadata[cid]['conversationTitle']
            if sample['id']==full_id:
                try:
                    payload = self.owner.index.full(user['reference'])
                    text = payload.get('message') if user['source']=='event' else '\n'.join(
                        x.get('text','') for x in payload.get('content',[]) if isinstance(x,dict))
                    info['message']=message_text(text)
                except (OSError,ValueError): info['associationIssue']='subtask_parent_missing'
        return result


class RequestContext:
    def __init__(self,home):
        self.home=Path(home);self.paths={};self.cache={};self.paths_refreshed=None
        self.index = RolloutIndex()
    def refresh_paths(self, force=False):
        now = time.monotonic()
        if not force and self.paths_refreshed is not None and now - self.paths_refreshed < 60: return
        paths={}
        for folder in ['sessions','archived_sessions']:
            for p in (self.home/folder).rglob('*.jsonl'):
                m=UUID.search(p.name)
                if m:paths.setdefault(m.group(),set()).add(p)
        for db in sorted(self.home.glob('state_*.sqlite')):
            try:
                with sqlite3.connect('file:'+str(db)+'?mode=ro',uri=True) as c:
                    for id,path in c.execute('select id,rollout_path from threads'):
                        if not isinstance(path,str):continue
                        p=Path(path)
                        if p.exists():paths.setdefault(id,set()).add(p)
            except (sqlite3.Error,OSError):pass
        self.paths=paths
        self.paths_refreshed=now
    def timeline(self,id):
        messages,usages=[],[]
        for p in self.paths.get(id,[]):
            try:
                size=p.stat().st_size
                state=self.cache.get(p,dict(offset=0,messages=[],usages=[]))
                if size<state['offset']:state=dict(offset=0,messages=[],usages=[])
                with p.open('rb') as f:
                    f.seek(state['offset'])
                    while True:
                        line=f.readline()
                        if not line or not line.endswith(b'\n'):break
                        state['offset']=f.tell()
                        if not any(tag in line for tag in [b'"role":"user"',b'"role": "user"',b'"type":"user_message"',b'"type": "user_message"',b'"type":"token_count"',b'"type": "token_count"']):continue
                        try:
                            o=json.loads(line);d=o.get('payload',{})
                            t=datetime.datetime.fromisoformat(o['timestamp'].replace('Z','+00:00')).timestamp()
                        except (ValueError,KeyError,TypeError):continue
                        text=None
                        if o.get('type')=='response_item' and d.get('role')=='user':
                            text='\n'.join(x.get('text','') for x in d.get('content',[]) if isinstance(x,dict))
                        elif o.get('type')=='event_msg' and d.get('type')=='user_message':text=d.get('message')
                        if text is not None:
                            short=sentence(text)
                            if short:state['messages'].append((t,short))
                        if o.get('type')=='event_msg' and d.get('type')=='token_count':
                            usage=d.get('info',{}).get('last_token_usage') or {}
                            if usage.get('output_tokens',0)>0:state['usages'].append((t,usage.get('input_tokens'),usage.get('output_tokens')))
                self.cache[p]=state
                messages+=state['messages'];usages+=state['usages']
            except (OSError,ValueError,TypeError):continue
        return messages,usages
    def preview(self,id,when):
        self.refresh_paths()
        messages,_=self.timeline(id)
        eligible=[x for x in messages if x[0]<=when]
        return max(eligible,key=lambda x:x[0])[1] if eligible else None
    def message(self,id,when):
        # Keep complete messages out of the collector cache and TPS sample file.
        # A selected API call uses the latest actual user message before its start.
        self.refresh_paths(force=True)
        latest=None
        for p in sorted(self.paths.get(id,[])):
            try:
                with p.open('rb') as f:
                    for line in f:
                        if not line.endswith(b'\n'):continue
                        if not any(tag in line for tag in [b'"role":"user"',b'"role": "user"',b'"type":"user_message"',b'"type": "user_message"']):continue
                        try:
                            o=json.loads(line);d=o.get('payload',{})
                            t=datetime.datetime.fromisoformat(o['timestamp'].replace('Z','+00:00')).timestamp()
                        except (ValueError,KeyError,TypeError):continue
                        if t>when or (latest and t<latest[0]):continue
                        text=None
                        if o.get('type')=='response_item' and d.get('role')=='user':
                            text='\n'.join(x.get('text','') for x in d.get('content',[]) if isinstance(x,dict))
                        elif o.get('type')=='event_msg' and d.get('type')=='user_message':text=d.get('message')
                        full=message_text(text)
                        if full:latest=(t,full)
            except OSError:continue
        return latest[1] if latest else None
    def call_contexts(self, samples, full_id=None):
        """Local UI context only. Never mutate or persist numeric samples."""
        self.refresh_paths(force=True)
        by_conversation = {}
        for sample in samples:
            if sample.get('conversationID'):
                by_conversation.setdefault(sample['conversationID'], []).append(sample)
        result = {}
        metadata = thread_metadata(self.home,by_conversation)
        source_info = suggestion_sources(self.home, [sample for calls in by_conversation.values()
            for sample in calls if not self.paths.get(sample['conversationID'])])
        for conversation, calls in by_conversation.items():
            records = []
            low = min(s.get('startedAt', s['completedAt'] - s['durationSeconds'] - s.get('ttftSeconds', 0)) for s in calls)
            high = max(s['completedAt'] for s in calls) + .15
            full_call = next((s for s in calls if s['id'] == full_id), None)
            full_start = full_call.get('startedAt', full_call['completedAt'] - full_call['durationSeconds'] - full_call.get('ttftSeconds', 0)) if full_call else None
            full_end = full_call['completedAt'] + .15 if full_call else None
            for path in sorted(self.paths.get(conversation, [])):
                try:
                    for when, kind, payload in self.index.records(path):
                        if when > high: continue
                        if kind == 'compacted' or (kind == 'response_item' and payload.get('role') != 'user'):
                            if when < low: continue
                        kept = payload
                        if (kind == 'response_item' and payload.get('role') != 'user' and
                            full_start is not None and full_start <= when <= full_end):
                            kept = self.index.full(payload['_ref'])
                        records.append((when, kind, kept))
                except FileNotFoundError: continue
            records.sort(key=lambda r: r[0])
            users, outputs, turns, ended, compactions = [], [], [], [], []
            turn = None
            for when, kind, payload in records:
                if not isinstance(payload, dict): continue
                if kind == 'compacted': compactions.append((when, payload))
                if kind == 'turn_context' or (kind == 'event_msg' and payload.get('type') == 'task_started'):
                    next_turn = payload.get('turn_id')
                    if next_turn and next_turn != turn:
                        turn = next_turn
                        turns.append((when, turn))
                if kind == 'event_msg' and payload.get('type') == 'task_complete':
                    ended.append((when, payload.get('turn_id') or turn))
                text, source = None, None
                if kind == 'response_item' and payload.get('role') == 'user':
                    text = '\n'.join(x.get('text', '') for x in payload.get('content', []) if isinstance(x, dict))
                    source = 'response'
                elif kind == 'event_msg' and payload.get('type') == 'user_message':
                    text, source = payload.get('message'), 'event'
                full = message_text(text)
                if full: users.append(dict(time=when, text=full, turn=turn, source=source,
                                          dedup=payload.get('dedup') or hashlib.sha256(full.encode()).hexdigest(), reference=payload.get('_ref')))
                if kind != 'response_item': continue
                if payload.get('type') == 'message' and payload.get('role') == 'assistant':
                    text = '\n'.join(x.get('text', '') for x in payload.get('content', [])
                                     if isinstance(x, dict) and x.get('type') in ('output_text', 'text'))
                    if text.strip(): outputs.append((when, dict(kind='output', title='输出内容', text=text.strip())))
                elif payload.get('type') in ('function_call', 'custom_tool_call'):
                    name = payload.get('name') or '未记录名称'
                    arguments = payload.get('arguments', payload.get('input', ''))
                    if not isinstance(arguments, str): arguments = json.dumps(arguments, ensure_ascii=False)
                    outputs.append((when, dict(kind='tool', title='工具调用：' + name, text=arguments, name=name)))
            # Rollouts can record one human message twice (event + response_item).
            # Prefer its response record, without merging two separate user messages.
            users = [u for u in users if u['source'] != 'event' or not any(
                v['source'] == 'response' and v['turn'] == u['turn'] and
                abs(v['time'] - u['time']) < 2 and v['dedup'] == u['dedup'] for v in users)]
            for sample in calls:
                start = sample.get('startedAt', sample['completedAt'] - sample['durationSeconds'] - sample.get('ttftSeconds', 0))
                end = sample['completedAt']
                current_turn = next((t for when, t in reversed(turns) if when <= start), None)
                eligible = [u for u in users if u['time'] <= start and (not current_turn or u['turn'] == current_turn)]
                user = max(eligible, key=lambda u: u['time']) if eligible else None
                if user and any(user['time'] <= when < start and t == user['turn'] for when, t in ended):
                    user = None  # A completed task's user message is not the next background task's parent.
                info = dict(metadata.get(conversation,{}))
                if user:
                    identity = '%s:%s:%.6f' % (conversation, user['turn'] or '', user['time'])
                    info.update(groupID=hashlib.sha256(identity.encode()).hexdigest(),
                                groupPreview=sentence(user['text']), groupTimestamp=user['time'])
                    if sample['id'] == full_id:
                        payload = self.index.full(user['reference'])
                        text = payload.get('message') if user['source'] == 'event' else '\n'.join(
                            x.get('text', '') for x in payload.get('content', []) if isinstance(x, dict))
                        info['message'] = message_text(text)
                # Concurrent calls in one conversation cannot be assigned by time alone.
                overlaps = any(other['id'] != sample['id'] and
                    other.get('startedAt', other['completedAt'] - other['durationSeconds'] - other.get('ttftSeconds', 0)) < end and
                    other['completedAt'] > start for other in calls)
                next_start = min((other.get('startedAt', other['completedAt'] - other['durationSeconds'] - other.get('ttftSeconds', 0))
                                  for other in calls if other['id'] != sample['id'] and
                                  other.get('startedAt', other['completedAt'] - other['durationSeconds'] - other.get('ttftSeconds', 0)) >= end), default=float('inf'))
                content = [] if overlaps else [part for when, part in outputs if start <= when <= end + .15 and when < next_start]
                # Compaction is a special rollout record, not an assistant message.
                # Do not display replacement_history, retained context, or hidden prompts.
                matches = {payload.get('compaction_response_id') for when, payload in compactions
                           if start <= when <= end + .15 and when < next_start and compaction_matches(payload, sample)}
                if not overlaps and len(matches) == 1:
                    info.update(source_context('compaction'))
                    content = []
                elif sample['id'] in source_info:
                    info.update(source_info[sample['id']])
                if content:
                    messages = [part['text'] for part in content if part['kind'] == 'output']
                    tools = list(dict.fromkeys(part['name'] for part in content if part['kind'] == 'tool'))
                    preview = sentence(messages[0]) if messages else '调用 ' + '、'.join(tools)
                    info.update(outputPreview=preview, outputKind='output' if messages else 'tool')
                if sample['id'] == full_id:
                    info['content'] = content
                    if not info.get('sourceKind') and (not user or not content):
                        info['associationIssue'] = ('overlap' if overlaps else 'no_rollout' if not self.paths.get(conversation)
                                                    else 'no_user' if not user else 'no_output')
                if info: result[sample['id']] = info
        return TaskAttribution(self).apply(samples,result,full_id)

    def enrich(self,samples):
        if not samples:return
        self.refresh_paths(force=True)
        unknown=[s for s in samples if not s.get('conversationID')]
        ids=set(self.paths)
        if unknown:
            try:
                low=int(min(s['completedAt'] for s in unknown))-3600
                high=int(max(s['completedAt'] for s in unknown))+1
                with sqlite3.connect('file:'+str(self.home/'logs_2.sqlite')+'?mode=ro',uri=True) as c:
                    ids.update(x[0] for x in c.execute('select distinct thread_id from logs where ts between ? and ?', (low,high)) if x[0])
            except (sqlite3.Error,OSError):pass
        for s in unknown:
            if s.get('timingSource')!='websocket':continue
            start=s['completedAt']-s['durationSeconds']-s.get('ttftSeconds',0)
            matches=[]
            for id in ids:
                for delta in [-.000001,0,.000001]:
                    key='%s:%s:%.6f:%.6f'%(id,s['model'],start+delta,s['completedAt'])
                    if hashlib.sha256(key.encode()).hexdigest()==s['id']:
                        matches.append(id);break
            if len(matches)==1:s['conversationID']=matches[0];s['startedAt']=start
        sse=[s for s in unknown if not s.get('conversationID') and s.get('timingSource')=='sse']
        if sse:
            earliest=min(s['completedAt'] for s in sse)-3600
            usage_index=[]
            for id,paths in self.paths.items():
                if not any(p.exists() and p.stat().st_mtime>=earliest for p in paths):continue
                _,usages=self.timeline(id)
                usage_index.extend((id,*u) for u in usages)
            for s in sse:
                candidates={id for id,t,inp,out in usage_index if abs(t-s['completedAt'])<.15 and inp==s['inputTokens'] and out==s['outputTokens']}
                if len(candidates)==1:s['conversationID']=candidates.pop()
        for s in samples:
            if s.get('promptPreview') or not s.get('conversationID'):continue
            when=s.get('startedAt',s['completedAt']-s['durationSeconds']-s.get('ttftSeconds',0))
            preview=self.preview(s['conversationID'],when)
            if preview:s['promptPreview']=preview

if __name__=='__main__':
    import argparse
    import os
    parser=argparse.ArgumentParser()
    parser.add_argument('--home',default=os.environ.get('CODEX_HOME',str(Path.home()/'.codex')))
    parser.add_argument('--conversation')
    parser.add_argument('--before',type=float)
    parser.add_argument('--worker',action='store_true')
    parser.add_argument('--samples',action='store_true')
    parser.add_argument('--output-timings',action='store_true')
    parser.add_argument('--full-id')
    args=parser.parse_args()
    if args.worker:
        import sys
        resolver = RequestContext(args.home)
        # One JSON line per request/reply. EOF on the parent-owned pipe ends the
        # worker, including after a parent crash. There is no idle polling.
        for line in sys.stdin:
            try:
                request = json.loads(line)
                if request['command'] == 'contexts':
                    result = resolver.call_contexts(request['samples'], request.get('fullID'))
                elif request['command'] == 'timings':
                    # Always query current typed events; history cache cannot
                    # supply numeric timing evidence or conceal new overlaps.
                    result = output_timings(args.home, request['samples'])
                else: raise ValueError('Unknown command')
                reply = dict(result=result)
            except Exception:
                # Do not publish partial associations or leak prompt text in errors.
                resolver = RequestContext(args.home)
                reply = dict(error='无法读取本地对话记录')
            print(json.dumps(reply, ensure_ascii=False, allow_nan=False), flush=True)
        raise SystemExit(0)
    if args.output_timings:
        import sys
        print(json.dumps(output_timings(args.home, json.load(sys.stdin)), allow_nan=False))
        raise SystemExit(0)
    resolver = RequestContext(args.home)
    if args.samples:
        import sys
        print(json.dumps(resolver.call_contexts(json.load(sys.stdin), args.full_id), ensure_ascii=False))
    elif args.conversation and args.before is not None:
        print(json.dumps(dict(message=resolver.message(args.conversation,args.before)),ensure_ascii=False))
    else: parser.error('use --samples or --conversation and --before')
