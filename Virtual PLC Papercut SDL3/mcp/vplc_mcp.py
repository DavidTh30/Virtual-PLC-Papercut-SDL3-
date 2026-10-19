"""MCP server of the Virtual PLC (Papercut SDL3) for Claude Code.

It speaks MCP (JSON-RPC 2.0, one message per line on stdin / stdout) and passes every tool call to the
running Virtual PLC through its IPC server, the Windows named pipe \\\\.\\pipe\\VirtualPLC (Ports screen:
"IPC server" on). The tools are the ones of the assistant built into the Virtual PLC (get_project,
get_block, write_network, compile, read_values, set_inputs, download_and_run ..); the ones that change the
PLC work only while "Claude Code may change the program" is on in the Ports screen.

Only the Python standard library is used. Add it to Claude Code with:

    claude mcp add virtual-plc -- python "<the folder of VirtualPLC.exe>\\mcp\\vplc_mcp.py"
"""
import json
import os
import sys
import time

PIPE = r'\\.\pipe\VirtualPLC'
VERSION = '1.0'
PROTOCOL = '2025-06-18'

GUIDE_TOOL = {
    'name': 'get_guide',
    'description': 'How the Virtual PLC is programmed through these tools: the CPU families, SCL / STL / LAD, '
                   'the LAD cell format of write_network, addresses and symbols. Read it once before you write code.',
    'inputSchema': {'type': 'object', 'properties': {}},
}
STATE_TOOL = {
    'name': 'plc_state',
    'description': 'Whether the Virtual PLC is reachable, its CPU and its mode (RUN / STOP).',
    'inputSchema': {'type': 'object', 'properties': {}},
}

NOT_RUNNING = ('The Virtual PLC is not reachable: start VirtualPLC.exe and turn on "IPC server" on its Ports '
               'screen (the named pipe ' + PIPE + ').')


def log(*args):
    # stderr: Claude Code shows it in the MCP log, stdout is the protocol
    print('vplc_mcp:', *args, file=sys.stderr, flush=True)


class PlcPipe:
    """One request line to the Virtual PLC, one answer line back (UTF-8)."""

    def __init__(self):
        self.f = None

    def _open(self):
        if self.f is None:
            self.f = open(PIPE, 'r+b', buffering=0)

    def ask(self, line):
        for attempt in range(2):
            try:
                self._open()
                self.f.write((line + '\n').encode('utf-8'))
                buf = bytearray()
                while not buf.endswith(b'\n'):
                    c = self.f.read(65536)
                    if not c:
                        raise OSError('the pipe was closed')
                    buf += c
                return buf.decode('utf-8', errors='replace').strip()
            except OSError as e:
                # the app was restarted / the IPC switched off and on: once more with a new connection
                log('pipe:', e)
                try:
                    if self.f is not None:
                        self.f.close()
                except OSError:
                    pass
                self.f = None
                if attempt == 1:
                    return None
                time.sleep(0.2)
        return None


plc = PlcPipe()


CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tools_cache.json')
served_live = [False]   # the last tools/list came from the running app


def app_tools():
    """The tools of the running app (and they are kept in tools_cache.json); None when it is not reachable."""
    ans = plc.ask('TOOLS')
    if not (ans and ans.startswith('OK ')):
        return None
    tools = [{'name': t['name'], 'description': t.get('description', ''),
              'inputSchema': t.get('input_schema', {'type': 'object', 'properties': {}})}
             for t in json.loads(ans[3:])]
    try:
        with open(CACHE, 'w', encoding='utf-8') as f:
            json.dump(tools, f, indent=1, ensure_ascii=False)
    except OSError as e:
        log('cache:', e)
    return tools


def tool_list():
    # the app's own list when it runs; else the one it gave last time (tools_cache.json): Claude Code asks for
    # the list when it starts, often before the Virtual PLC is open
    tools = app_tools()
    served_live[0] = tools is not None
    if tools is None:
        try:
            with open(CACHE, encoding='utf-8') as f:
                tools = json.load(f)
        except (OSError, ValueError) as e:
            log('no tool list of the app yet:', e)
            tools = []
    return [GUIDE_TOOL, STATE_TOOL] + tools


def notify(method):
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'method': method}) + '\n')
    sys.stdout.flush()


def check_list_changed():
    # the app came up after a list from the cache: its tools may differ, Claude Code asks again
    if served_live[0]:
        return
    live = app_tools()
    if live is None:
        return
    served_live[0] = True
    notify('notifications/tools/list_changed')


def text(s, err=False):
    return {'content': [{'type': 'text', 'text': s}], 'isError': err}


def call_tool(name, args):
    if name == 'get_guide':
        ans = plc.ask('GUIDE')
        if ans is None:
            return text(NOT_RUNNING, True)
        if not ans.startswith('OK '):
            return text(ans, True)
        return text(json.loads(ans[3:]))
    if name == 'plc_state':
        ping = plc.ask('PING')
        if ping is None:
            return text(NOT_RUNNING, True)
        state = plc.ask('STATE') or ''
        return text(json.dumps({'reachable': True, 'cpu': ping[3:].replace('Virtual PLC ', ''),
                                'mode': state[3:] if state.startswith('OK ') else state}))
    args = dict(args or {})
    # read_values with wait_ms: the wait happens here (the app answers at once)
    if name == 'read_values' and int(args.get('wait_ms') or 0) > 0:
        time.sleep(min(10000, int(args['wait_ms'])) / 1000.0)
        args['wait_ms'] = 0
    ans = plc.ask('TOOL ' + name + ' ' + json.dumps(args, ensure_ascii=False))
    if ans is None:
        return text(NOT_RUNNING, True)
    if ans.startswith('ERR '):
        return text(ans[4:], True)
    if not ans.startswith('OK '):
        return text(ans, True)
    r = json.loads(ans[3:])
    return text(r.get('text', ''), bool(r.get('is_error')))


def reply(msg_id, result=None, error=None):
    out = {'jsonrpc': '2.0', 'id': msg_id}
    if error is not None:
        out['error'] = error
    else:
        out['result'] = result
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + '\n')
    sys.stdout.flush()


def handle(msg):
    method = msg.get('method')
    msg_id = msg.get('id')
    params = msg.get('params') or {}
    if msg_id is None:
        return   # a notification (notifications/initialized ..): no answer
    if method == 'initialize':
        reply(msg_id, {
            'protocolVersion': params.get('protocolVersion', PROTOCOL),
            'capabilities': {'tools': {'listChanged': True}},
            'serverInfo': {'name': 'virtual-plc', 'version': VERSION},
            'instructions': 'Tools of the Virtual PLC (a Siemens S7-300/400/1200/1500 simulator, Papercut SDL3). '
                            'Call get_guide once, then get_project. Changes need "Claude Code may change the '
                            'program" on the Ports screen of the app.'})
    elif method == 'ping':
        reply(msg_id, {})
    elif method == 'tools/list':
        reply(msg_id, {'tools': tool_list()})
    elif method == 'tools/call':
        try:
            reply(msg_id, call_tool(params.get('name', ''), params.get('arguments')))
            check_list_changed()
        except Exception as e:   # a bad answer of the app: the tool fails, the server goes on
            log('tool error:', repr(e))
            reply(msg_id, text('error: ' + str(e), True))
    else:
        reply(msg_id, error={'code': -32601, 'message': 'method not found: ' + str(method)})


def main():
    # stdin / stdout as UTF-8 lines (Windows consoles may default to another code page)
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply(None, error={'code': -32700, 'message': 'parse error'})
            continue
        if isinstance(msg, list):
            for m in msg:
                handle(m)
        else:
            handle(msg)


if __name__ == '__main__':
    main()
