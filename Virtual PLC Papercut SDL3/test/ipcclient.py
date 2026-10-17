"""A client of the Virtual PLC's IPC server (the named pipe \\\\.\\pipe\\VirtualPLC), for the test
VPLC_IPC_TEST: it waits for the pipe, then reads and writes through it, starts the sample's motor and
writes what it got to shots\\ipc_client.txt.
"""
import sys
import time

PIPE = r'\\.\pipe\VirtualPLC'
OUT = sys.argv[1] if len(sys.argv) > 1 else 'shots/ipc_client.txt'
log = []


def connect(timeout=40):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            return open(PIPE, 'r+b', buffering=0)
        except OSError:
            time.sleep(0.2)
    return None


def ask(f, cmd):
    f.write((cmd + '\n').encode('utf-8'))
    line = b''
    while not line.endswith(b'\n'):
        c = f.read(1)
        if not c:
            break
        line += c
    return line.decode('utf-8').strip()


def check(ok, what):
    log.append(('ok    ' if ok else 'FAIL  ') + what)


f = connect()
if f is None:
    log.append('FAIL  no pipe within 40 s')
else:
    r = ask(f, 'PING'); check(r.startswith('OK Virtual PLC'), 'PING -> ' + r)
    r = ask(f, 'STATE'); check(r == 'OK RUN', 'STATE -> ' + r)
    r = ask(f, 'READ "Motor"'); check(r == 'OK FALSE', 'READ "Motor" -> ' + r)
    for cmd in ('WRITE "Stop_PB" TRUE', 'WRITE "Overload_OK" TRUE', 'WRITE "Start_PB" TRUE'):
        r = ask(f, cmd); check(r == 'OK', cmd + ' -> ' + r)
    time.sleep(0.5)
    r = ask(f, 'WRITE "Start_PB" FALSE'); check(r == 'OK', 'WRITE "Start_PB" FALSE -> ' + r)
    time.sleep(0.5)
    r = ask(f, 'READ "Motor"'); check(r == 'OK TRUE', 'the motor runs (self holding): READ "Motor" -> ' + r)
    r = ask(f, 'WRITE %MW100 1234'); check(r == 'OK', 'WRITE %MW100 1234 -> ' + r)
    time.sleep(0.3)
    r = ask(f, 'READ %MW100'); check(r == 'OK 1234', 'READ %MW100 -> ' + r)
    r = ask(f, 'READ "Motor".SpeedRpm'); check(r.startswith('OK '), 'READ "Motor".SpeedRpm -> ' + r)
    r = ask(f, 'READ "Nope"'); check(r.startswith('ERR '), 'READ "Nope" -> ' + r)
    r = ask(f, 'WRITE %MW100 abc'); check(r.startswith('ERR '), 'WRITE %MW100 abc -> ' + r)
    r = ask(f, 'FOO'); check(r.startswith('ERR unknown'), 'FOO -> ' + r)
    # TAGS: a head line, the tags, END
    f.write(b'TAGS\n')
    data = b''
    while not data.endswith(b'END\n'):
        c = f.read(1)
        if not c:
            break
        data += c
    lines = data.decode('utf-8').splitlines()
    check(lines[0].startswith('OK ') and lines[-1] == 'END' and any(x.startswith('Motor;Bool;') for x in lines),
          'TAGS -> %s, %d lines, ..., END' % (lines[0], len(lines)))
    # a second client at the same time
    g = connect(5)
    check(g is not None and ask(g, 'PING').startswith('OK'), 'a second client at the same time: PING')
    if g:
        g.close()
    r = ask(f, 'STOP'); check(r == 'OK', 'STOP -> ' + r)
    time.sleep(0.4)
    r = ask(f, 'STATE'); check(r == 'OK STOP', 'STATE after STOP -> ' + r)
    r = ask(f, 'RUN'); check(r == 'OK', 'RUN -> ' + r)
    f.close()
fails = sum(1 for x in log if x.startswith('FAIL'))
log.append('%d checks, %d failed' % (len(log), fails))
open(OUT, 'w', encoding='utf-8').write('\n'.join(log) + '\n')
print('\n'.join(log))
