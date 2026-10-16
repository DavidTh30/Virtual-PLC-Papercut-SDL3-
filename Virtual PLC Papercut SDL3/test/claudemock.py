"""A local stand-in for the Messages API (no key, no cost) for the Claude panel of the Virtual PLC.

Run it, then start the app with
    ANTHROPIC_BASE_URL=http://127.0.0.1:8765  ANTHROPIC_API_KEY=mock-local-test  VPLC_CLAUDE_MOCK=1
    VirtualPLC.exe --shots shots
The mock plays one tool loop and checks every request the app sends: the headers, the body, that the
roles alternate, that every tool_use gets its tool_result (parallel ones in one message), and that the
assistant content (a thinking block with its signature too) comes back unchanged. The results go to
claudemock.log (and the console); the process ends after the last answer.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8765
LOG = []
SENT = []        # the assistant contents the mock sent, in order
FAILS = 0


def check(ok, what):
    global FAILS
    LOG.append(('  ok   ' if ok else '  FAIL ') + what)
    if not ok:
        FAILS += 1


ANSWERS = [
    # 1: a thinking block (must come back unchanged), text, one tool
    [{"type": "thinking", "thinking": "", "signature": "sig-mock-1"},
     {"type": "text", "text": "I'll look at the FC first."},
     {"type": "tool_use", "id": "toolu_m1", "name": "get_block", "input": {"block": "FC2"}}],
    # 2: two tools in parallel
    [{"type": "text", "text": "Now I add a counter network to OB1 and compile."},
     {"type": "tool_use", "id": "toolu_m2", "name": "write_network",
      "input": {"block": "OB1", "language": "SCL", "title": "Counter (Claude)",
                "code": "// counts every cycle\n%MW100 := %MW100 + 1;"}},
     {"type": "tool_use", "id": "toolu_m3", "name": "compile", "input": {}}],
    # 3: the download needs the user's OK
    [{"type": "tool_use", "id": "toolu_m4", "name": "download_and_run", "input": {}}],
    # 4: live values
    [{"type": "tool_use", "id": "toolu_m5", "name": "read_values", "input": {"operands": ["%MW100", "\"Motor\".SpeedRpm"]}}],
    # 5: the end
    [{"type": "text", "text": "## Done\nNetwork **Counter (Claude)** in OB1 counts %MW100 up every cycle:\n```\n%MW100 := %MW100 + 1;\n```\nIt runs: the value grows."}],
]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = len(SENT)
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        LOG.append('request %d (%d bytes)' % (n + 1, len(body)))
        check(self.path == '/v1/messages', 'path /v1/messages')
        check(self.headers.get('x-api-key') == 'mock-local-test', 'x-api-key header')
        check(self.headers.get('anthropic-version') == '2023-06-01', 'anthropic-version 2023-06-01')
        check('server-side-fallback-2026-07-01' in (self.headers.get('anthropic-beta') or ''), 'fallback beta header')
        try:
            req = json.loads(body.decode('utf-8'))
        except Exception as e:
            check(False, 'body is JSON: %s' % e)
            self.reply(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad JSON"}})
            return
        check(req.get('model') == 'claude-opus-5-5', 'model claude-opus-5-5')
        check(req.get('max_tokens') == 16000, 'max_tokens 16000')
        check(req.get('fallbacks') == 'default', 'fallbacks "default"')
        check(req.get('output_config', {}).get('effort') == 'high', 'effort high')
        check('thinking' not in req, 'thinking left at the model default (adaptive)')
        check(req.get('cache_control', {}).get('type') == 'ephemeral', 'prompt caching')
        names = [t.get('name') for t in req.get('tools', [])]
        check(len(names) == 13 and 'set_inputs' in names and 'read_values' in names, 'the 13 tools')
        check(all('input_schema' in t for t in req.get('tools', [])), 'every tool has an input_schema')
        sys_text = ''.join(b.get('text', '') for b in req.get('system', []))
        check('Virtual PLC' in sys_text and 'LAD' in sys_text, 'the system prompt')
        msgs = req.get('messages', [])
        roles = [m.get('role') for m in msgs]
        check(roles[:1] == ['user'] and all(roles[i] != roles[i + 1] for i in range(len(roles) - 1)),
              'roles alternate, the first is user: %s' % roles)
        check(len(msgs) == 2 * n + 1, 'the conversation grows by one answer and one result (%d messages)' % len(msgs))
        # every answer sent so far comes back unchanged, followed by the results of its tool calls
        for k in range(n):
            a = msgs[2 * k + 1] if 2 * k + 1 < len(msgs) else {}
            check(a.get('role') == 'assistant' and a.get('content') == SENT[k],
                  'answer %d echoed unchanged' % (k + 1))
            ids = [b['id'] for b in SENT[k] if b['type'] == 'tool_use']
            u = msgs[2 * k + 2] if 2 * k + 2 < len(msgs) else {}
            got = [b.get('tool_use_id') for b in u.get('content', []) if b.get('type') == 'tool_result']
            check(got == ids, 'answer %d: one user message with the results %s (got %s)' % (k + 1, ids, got))
        if n == 0:
            blocks = msgs[0]['content']
            first = blocks[-1].get('text', '')
            check(blocks[-1].get('type') == 'text' and '[CPU ' in first and 'the editor shows' in first,
                  'the user message carries the editor context (the text last)')
            docs = [b for b in blocks if b.get('type') == 'document']
            check(len(docs) == 1 and docs[0].get('title') == 'attach_test.txt' and
                  docs[0]['source'].get('type') == 'text' and 'ปุ่มสตาร์ท' in docs[0]['source'].get('data', ''),
                  'the TXT attachment: a text document block, UTF-8 Thai intact')
            imgs = [b for b in blocks if b.get('type') == 'image']
            ok = False
            jpg = [b for b in imgs if b['source'].get('media_type') == 'image/jpeg']
            check(len(jpg) == 1 and base64.b64decode(jpg[0]['source']['data'])[:3] == bytes([0xFF, 0xD8, 0xFF]),
                  'the JPG attachment: sent as it is, a base64 JPEG image block')
            imgs = [b for b in imgs if b['source'].get('media_type') == 'image/png']
            if len(imgs) == 1 and imgs[0]['source'].get('type') == 'base64':
                raw = base64.b64decode(imgs[0]['source']['data'])
                ok = imgs[0]['source'].get('media_type') == 'image/png' and raw[:4] == bytes([0x89, 0x50, 0x4E, 0x47])
            check(ok, 'the BMP attachment: sent as a base64 PNG image block')
            check([b.get('type') for b in blocks] == ['document', 'image', 'image', 'text'], 'the files go before the text')
        last = msgs[-1]['content'] if msgs else []
        res = {b.get('tool_use_id'): b for b in last if isinstance(b, dict) and b.get('type') == 'tool_result'}
        if n == 1:
            check('Clamp' in res.get('toolu_m1', {}).get('content', ''), 'get_block returned FC2 "Clamp"')
        if n == 2:
            check('"errors" : 0' in res.get('toolu_m2', {}).get('content', '').replace('"errors":0', '"errors" : 0'),
                  'write_network compiled without errors')
            check(not res.get('toolu_m3', {}).get('is_error', True), 'compile ran')
        if n == 3:
            check('Downloaded' in res.get('toolu_m4', {}).get('content', ''), 'download_and_run: allowed and downloaded')
        if n == 4:
            v = res.get('toolu_m5', {}).get('content', '')
            check('%MW100' in v and '"Run"' in v.replace('"cpu_mode" : "Run"', '"Run"').replace('"cpu_mode":"Run"', '"Run"'),
                  'read_values in RUN: ' + v[:120])
        if n >= len(ANSWERS):
            self.reply(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "too many requests"}})
            return
        content = ANSWERS[n]
        SENT.append(content)
        stop = 'tool_use' if any(b['type'] == 'tool_use' for b in content) else 'end_turn'
        self.reply(200, {"id": "msg_mock_%d" % (n + 1), "type": "message", "role": "assistant",
                         "model": "claude-opus-5-5", "content": content, "stop_reason": stop,
                         "stop_details": None,
                         "usage": {"input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 900}})
        if stop == 'end_turn':
            LOG.append('%d checks failed' % FAILS)
            open('claudemock.log', 'w', encoding='utf-8').write('\n'.join(LOG) + '\n')
            print('\n'.join(LOG))
            sys.stdout.flush()

    def reply(self, code, obj):
        data = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    srv = HTTPServer(('127.0.0.1', PORT), H)
    srv.timeout = 1
    import time
    t0 = time.time()
    while len(SENT) < len(ANSWERS) and time.time() - t0 < 300:
        srv.handle_request()
    time.sleep(0.5)
