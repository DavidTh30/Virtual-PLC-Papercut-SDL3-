"""The test of the MCP server (mcp\\vplc_mcp.py) as Claude Code uses it: it starts the server, does the MCP
handshake, lists the tools and calls them while the Virtual PLC runs the test VPLC_MCP_TEST (IPC on; the
permission to change the program comes on after a while). The results go to shots\\mcp_client.txt.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, '..', 'mcp', 'vplc_mcp.py')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'shots', 'mcp_client.txt')
log = []


def check(ok, what):
    log.append(('ok    ' if ok else 'FAIL  ') + what)


srv = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True, encoding='utf-8', bufsize=1)
seq = [0]


def rpc(method, params=None, notify=False):
    msg = {'jsonrpc': '2.0', 'method': method}
    if params is not None:
        msg['params'] = params
    if not notify:
        seq[0] += 1
        msg['id'] = seq[0]
    srv.stdin.write(json.dumps(msg) + '\n')
    srv.stdin.flush()
    if notify:
        return None
    return json.loads(srv.stdout.readline())


def tool(name, args=None):
    r = rpc('tools/call', {'name': name, 'arguments': args or {}})['result']
    return r['content'][0]['text'], r.get('isError', False)


try:
    r = rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                           'clientInfo': {'name': 'mcptest', 'version': '1'}})
    check(r['result']['serverInfo']['name'] == 'virtual-plc', 'initialize: ' + json.dumps(r['result']['serverInfo']))
    rpc('notifications/initialized', notify=True)
    # the app: wait for the pipe
    t0 = time.time()
    while time.time() - t0 < 40:
        txt, err = tool('plc_state')
        if not err:
            break
        time.sleep(0.5)
    check(not err and '"mode"' in txt, 'plc_state: ' + txt)
    tools = rpc('tools/list')['result']['tools']
    names = [t['name'] for t in tools]
    check(len(tools) >= 15 and 'write_network' in names and 'get_guide' in names,
          '%d tools: %s' % (len(tools), ', '.join(names)))
    txt, err = tool('get_guide')
    check(not err and 'LAD' in txt and len(txt) > 1000, 'get_guide: %d characters' % len(txt))
    txt, err = tool('get_project')
    check(not err and '"OB1"' in txt, 'get_project: ' + txt[:160])
    txt, err = tool('get_block', {'block': 'OB1'})
    check(not err and 'networks' in txt, 'get_block OB1: ' + txt[:120])
    # no permission yet: refused
    code = '%MW200 := 42;'
    txt, err = tool('write_network', {'block': 'OB1', 'language': 'SCL', 'title': 'from Claude Code',
                                      'code': code})
    check(err and 'permission' in txt, 'write_network without the permission: ' + txt[:150])
    # the app turns the permission on: the same call again until it works
    t0 = time.time()
    while time.time() - t0 < 40:
        txt, err = tool('write_network', {'block': 'OB1', 'language': 'SCL', 'title': 'from Claude Code',
                                          'code': code})
        if not err or 'permission' not in txt:
            break
        time.sleep(0.5)
    check(not err, 'write_network with the permission: ' + txt[:200])
    txt, err = tool('compile')
    check(not err and '"errors":0' in txt.replace(' ', ''), 'compile: ' + txt[:200])
    txt, err = tool('download_and_run')
    check(not err and '"downloaded":true' in txt and 'RUN' in txt, 'download_and_run: ' + txt)
    txt, err = tool('read_values', {'operands': ['%MW200', '"Motor"'], 'wait_ms': 300})
    check(not err and '42' in txt, 'read_values: ' + txt)
    txt, err = tool('set_inputs', {'inputs': {'"Stop_PB"': True}})
    check(not err, 'set_inputs: ' + txt[:120])
    txt, err = tool('get_diagnostics')
    check(not err and 'cpu_mode' in txt, 'get_diagnostics: ' + txt[:160])
    txt, err = tool('no_such_tool')
    check(err, 'an unknown tool: ' + txt[:80])
except Exception as e:
    check(False, 'exception: ' + repr(e))
finally:
    srv.stdin.close()
    srv.wait(5)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(log) + '\n')
