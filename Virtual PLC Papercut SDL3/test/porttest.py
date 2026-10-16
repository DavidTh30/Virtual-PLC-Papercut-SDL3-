"""Talks to the Virtual PLC's simulated ports with raw sockets, using the exact
telegrams snap7 sends (ISO connection request, PDU negotiation, read area,
SZL 0x0424) and a plain Modbus TCP request. No third-party packages.

    python porttest.py [host] [s7port] [modbusport] [slot]
"""
import socket, struct, sys

host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
s7port = int(sys.argv[2]) if len(sys.argv) > 2 else 102
mbport = int(sys.argv[3]) if len(sys.argv) > 3 else 502
slot = int(sys.argv[4]) if len(sys.argv) > 4 else 1

def recv_tpkt(s):
    h = s.recv(4)
    n = struct.unpack('>H', h[2:4])[0]
    b = b''
    while len(b) < n - 4:
        b += s.recv(n - 4 - len(b))
    return b

s = socket.create_connection((host, s7port), timeout=2)
# snap7 ISO connection request (remote TSAP 01.<rack*32+slot>)
s.send(bytes([0x03,0x00,0x00,0x16,0x11,0xE0,0x00,0x00,0x00,0x01,0x00,0xC0,0x01,0x0A,0xC1,0x02,0x01,0x00,0xC2,0x02,0x01,slot]))
cc = recv_tpkt(s)
print('COTP', 'CC ok' if cc[1] == 0xD0 else 'unexpected %02x' % cc[1])
# snap7 PDU negotiation (480)
s.send(bytes.fromhex('0300001902f08032010000040000080000f0000001000101e0'))
r = recv_tpkt(s)
print('PDU length', struct.unpack('>H', r[3+18:3+20])[0])
# snap7 read area: MB20, 2 bytes (byte transport)
s.send(bytes.fromhex('0300001f02f080320100000500000e00000401120a100200020000830000a0'))
r = recv_tpkt(s)[3:]
print('MW20 =', struct.unpack('>H', r[18:20])[0], '(return code %02x)' % r[14])
# snap7 read area: DB1.DBD0, 4 bytes -> REAL
s.send(bytes.fromhex('0300001f02f080320100000600000e00000401120a10020004000184000000'))
r = recv_tpkt(s)[3:]
print('DB1.DBD0 = %.2f' % struct.unpack('>f', r[18:22])[0], '(return code %02x)' % r[14])
# snap7 SZL 0x0424 (Cli_GetPlcStatus)
s.send(bytes.fromhex('0300002102f080320700000700000800080001120411440100ff09000404240000'))
r = recv_tpkt(s)[3:]
pl = struct.unpack('>H', r[6:8])[0]
st = r[10 + pl + 15]
print('CPU state:', {8: 'RUN', 4: 'STOP'}.get(st, hex(st)))
s.close()

m = socket.create_connection((host, mbport), timeout=2)
# Modbus TCP: read input registers 32 x1 (= IW64 on the S7-1200)
m.send(struct.pack('>HHHBBHH', 1, 0, 6, 1, 4, 32, 1))
r = m.recv(64)
print('Modbus input register 32 =', struct.unpack('>H', r[9:11])[0])
# read coils 0..15 (= Q0.0 .. Q1.7)
m.send(struct.pack('>HHHBBHH', 2, 0, 6, 1, 1, 0, 16))
r = m.recv(64)
print('Modbus coils 0..15 = %s' % format(r[9] | (r[10] << 8), '016b')[::-1])
m.close()
