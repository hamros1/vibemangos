"""A scripted 1.12.1 client for testing dmangos (or mangosd) end to end.

It logs in through the login server (SRP6), reads the realm list, connects to
the realm's world server, and then runs the actions given on the command line
in order:

    python3 tools/testclient.py LOGIN_PORT ACCOUNT PASSWORD ACTION...

    enum                      list the characters
    create:NAME:RACE:CLASS    create a male character with default looks
    delete:NAME               delete a character
    login:NAME                enter the world; prints the login packets and the
                              decoded player and item objects
    query                     name, item and time queries (after login)
    move:X:Y:Z                walk to a position (after login)
    say:TEXT                  say something and print what comes back
    sit                       sit down and print the changed fields
    logout                    log out to the character screen
    drop                      close the connection without logging out

The update packet parser here is independent of the server's D code: it checks
every block's field mask against the client's field counts, that every
inventory slot points at an object the client was sent, and that no byte is
left over. A layout mistake therefore cannot hide behind a matching mistake
in the D tests.

Example, against the realm on the local login server's default port:

    python3 tools/testclient.py 3724 tester PASSWORD create:Probe:1:1 login:Probe query logout delete:Probe
"""
import hashlib, os, socket, struct, sys, zlib
H = lambda *p: hashlib.sha1(b"".join(p)).digest()
le = lambda b: int.from_bytes(b, "little")
tole = lambda n, l: n.to_bytes(l, "little")
auth_port, user, pw = int(sys.argv[1]), sys.argv[2].upper().encode(), sys.argv[3].upper().encode()
actions = sys.argv[4:]

def recv(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk: raise EOFError(f"connection closed after {len(data)}/{n} bytes")
        data += chunk
    return data

# ---- login server (SRP6) ----
s = socket.create_connection(("127.0.0.1", auth_port), timeout=5)
body = b"WoW\0" + bytes([1, 12, 1]) + struct.pack("<H", 5875) + b"68x\0niW\0SUne" + struct.pack("<i", 60) + bytes([127,0,0,1]) + bytes([len(user)]) + user
s.sendall(bytes([0, 3]) + struct.pack("<H", len(body)) + body)
head = recv(s, 3); assert head[2] == 0, f"challenge rejected {head[2]}"
rest = recv(s, 116); B, g, N, salt = rest[0:32], rest[33], le(rest[35:67]), rest[67:99]
a = le(os.urandom(19)); A = tole(pow(g, a, N), 32)
u = le(H(A, B)); x = le(H(salt, H(user + b":" + pw)))
S_ = pow((le(B) - 3 * pow(g, x, N)) % N, a + u * x, N)
t = tole(S_, 32); k = 0
while k < 32 and t[k] == 0: k += 1
if (32 - k) % 2: k += 1
t = t[k:]; e, o = H(t[0::2]), H(t[1::2]); K = bytes(c for p in zip(e, o) for c in p)
M1 = H(bytes(i ^ j for i, j in zip(H(tole(N, 32)), H(bytes([g])))), H(user), salt, A, B, K)
s.sendall(bytes([1]) + A + M1 + bytes(20) + b"\0\0")
r = recv(s, 2); assert r[1] == 0, f"login rejected {r[1]}"
r += recv(s, 24); assert r[2:22] == H(A, M1, K)
s.sendall(bytes([0x10, 0, 0, 0, 0]))
hdr = recv(s, 3); rl = recv(s, struct.unpack("<H", hdr[1:3])[0])
name, addr, _ = rl[10:].split(b"\0", 2); flags = rl[9]
#print(f"login OK; realm '{name.decode()}' at {addr.decode()} flags=0x{flags:02x}")
s.close()
if flags & 0x02: print("realm is OFFLINE"); sys.exit(3)

# ---- world server ----
host, port = addr.decode().rsplit(":", 1)
w = socket.create_connection((host, int(port)), timeout=5)
class Cipher:
    def __init__(self): self.i = 0; self.j = 0
    def enc(self, data):
        out = bytearray()
        for b in data:
            self.i %= 40; x = ((b ^ K[self.i]) + self.j) & 0xFF; self.i += 1; self.j = x; out.append(x)
        return bytes(out)
    def dec(self, data):
        out = bytearray()
        for b in data:
            self.i %= 40; x = ((b - self.j) & 0xFF) ^ K[self.i]; self.i += 1; self.j = b; out.append(x)
        return bytes(out)
send_c, recv_c, crypted = Cipher(), Cipher(), False
def wrecv():
    h = recv(w, 4)
    if crypted: h = recv_c.dec(h)
    size = struct.unpack(">H", h[:2])[0]; op = struct.unpack("<H", h[2:])[0]
    return op, recv(w, size - 2)
def wsend(op, payload):
    h = struct.pack(">H", len(payload) + 4) + struct.pack("<I", op)
    w.sendall((send_c.enc(h) if crypted else h) + payload)

op, payload = wrecv(); assert op == 0x1EC, hex(op)
server_seed = payload[:4]
client_seed = os.urandom(4)
digest = H(user, bytes(4), client_seed, server_seed, K)
addons = b"".join(n + b"\0" + b"\x01" + struct.pack("<II", crc, 0) for n, crc in [(b"Blizzard_AuctionUI", 0x4C1C776D), (b"Questie", 0xDEADBEEF)])
wsend(0x1ED, struct.pack("<II", 5875, 0) + user + b"\0" + client_seed + digest + struct.pack("<I", len(addons)) + zlib.compress(addons))
crypted = True
replies = [wrecv(), wrecv()]
ops = {o: p for o, p in replies}
assert 0x2EF in ops and 0x1EE in ops, [hex(o) for o, _ in replies]
#print(f"world auth result 0x{ops[0x1EE][0]:02x} (0x0c = AUTH_OK); addon info {len(ops[0x2EF])} bytes for 2 addons")
assert ops[0x1EE][0] == 0x0C


def enum():
    wsend(0x037, b"")
    op, p = wrecv(); assert op == 0x03B
    chars, pos = {}, 1
    for _ in range(p[0]):
        guid = struct.unpack_from("<Q", p, pos)[0]; pos += 8
        end = p.index(b"\0", pos); name = p[pos:end].decode(); pos = end + 1
        race, cls = p[pos], p[pos + 1]; level = p[pos + 8]; pos += 9 + 28 + 1 + 12
        equip = [struct.unpack_from("<IB", p, pos + 5 * i)[0] for i in range(20)]; pos += 100
        chars[name] = (guid, race, cls, level, sum(1 for e in equip if e))
    return chars

OBJECT_END, ITEM_END, CONTAINER_END, UNIT_END, PLAYER_END = 6, 48, 122, 188, 1282
COUNTS = {1: ITEM_END, 2: CONTAINER_END, 4: PLAYER_END}

def packed_guid(p, pos):
    mask = p[pos]; pos += 1; g = 0
    for i in range(8):
        if mask & (1 << i): g |= p[pos] << (8 * i); pos += 1
    return g, pos

def parse_update(op, p):
    """An independent parser for SMSG_(COMPRESSED_)UPDATE_OBJECT; must consume every byte."""
    if op == 0x1F6:
        size = struct.unpack_from("<I", p)[0]; p = zlib.decompress(p[4:]); assert len(p) == size, (len(p), size)
    count, transport = struct.unpack_from("<IB", p); pos = 5; objects = []
    for _ in range(count):
        kind = p[pos]; pos += 1
        guid, pos = packed_guid(p, pos)
        typeid = None
        if kind in (2, 3):
            typeid = p[pos]; pos += 1
            flags = p[pos]; pos += 1
            move = None
            if flags & 0x20:
                mflags, mtime, x, y, z, o = struct.unpack_from("<II4f", p, pos); pos += 24
                if mflags & 0x02000000: pos += 8 + 16
                if mflags & 0x00200000: pos += 4
                pos += 4
                if mflags & 0x00002000: pos += 16
                if mflags & 0x04000000: pos += 4
                speeds = struct.unpack_from("<6f", p, pos); pos += 24
                move = (x, y, z, o, speeds)
            elif flags & 0x40:
                pos += 16
            if flags & 0x08: pos += 4
            if flags & 0x10: assert struct.unpack_from("<I", p, pos)[0] == 1; pos += 4
            if flags & 0x04: _, pos = packed_guid(p, pos)
            if flags & 0x02: pos += 4
        blocks = p[pos]; pos += 1
        masks = struct.unpack_from(f"<{blocks}I", p, pos); pos += 4 * blocks
        values = {}
        for i in range(blocks * 32):
            if masks[i // 32] & (1 << (i % 32)):
                values[i] = struct.unpack_from("<I", p, pos)[0]; pos += 4
        if typeid is not None:
            expected = (COUNTS[typeid] + 31) // 32
            assert blocks == expected, f"type {typeid}: {blocks} mask blocks, the client expects {expected}"
            assert max(values) < COUNTS[typeid], f"type {typeid}: field {max(values)} past the end"
            assert values[0] | values.get(1, 0) << 32 == guid, "OBJECT_FIELD_GUID matches the block's guid"
        objects.append((kind, guid, typeid, values, move if kind in (2, 3) else None))
    assert pos == len(p), f"{len(p) - pos} bytes left over"
    return objects

f = lambda v: struct.unpack("<f", struct.pack("<I", v))[0]
OPS = {0x236: "LOGIN_VERIFY_WORLD", 0x209: "ACCOUNT_DATA_TIMES", 0x332: "EXPECTED_SPAM_RECORDS", 0x096: "MESSAGECHAT",
       0x21E: "SET_REST_START", 0x155: "BINDPOINTUPDATE", 0x0FD: "TUTORIAL_FLAGS", 0x12A: "INITIAL_SPELLS",
       0x129: "ACTION_BUTTONS", 0x122: "INITIALIZE_FACTIONS", 0x042: "LOGIN_SETTIMESPEED", 0x127: "SET_PROFICIENCY",
       0x0FA: "TRIGGER_CINEMATIC", 0x1F6: "COMPRESSED_UPDATE_OBJECT", 0x0A9: "UPDATE_OBJECT", 0x067: "FRIEND_LIST",
       0x06B: "IGNORE_LIST", 0x2C2: "INIT_WORLD_STATES", 0x051: "NAME_QUERY_RESPONSE", 0x058: "ITEM_QUERY_RESPONSE",
       0x04C: "LOGOUT_RESPONSE", 0x04D: "LOGOUT_COMPLETE", 0x1CF: "QUERY_TIME_RESPONSE", 0x29D: "STANDSTATE_UPDATE",
       0x041: "CHARACTER_LOGIN_FAILED"}

def until(last):
    got = []
    while True:
        op, p = wrecv(); got.append((op, p))
        if op == last or op == 0x041: return got

def movement(op, x, y, z, o=0.0, flags=0):
    wsend(op, struct.pack("<II4fI", flags, 1000, x, y, z, o, 0))

for action in actions:
    kind, *args = action.split(":")
    if kind == "login":
        guid = enum()[args[0]][0]
        wsend(0x03D, struct.pack("<Q", guid))
        got = until(0x2C2)
        print("login packets:", " ".join(OPS.get(op, hex(op)) for op, _ in got))
        for op, p in got:
            if op == 0x041: print("  login failed, reason", p[0]); sys.exit(1)
            if op == 0x236: print("  verify world: map %d at %.2f %.2f %.2f o %.2f" % struct.unpack("<I4f", p))
            if op == 0x096:
                n = struct.unpack_from("<I", p, 16)[0]; print("  system message:", p[20:20 + n - 1].decode())
            if op == 0x12A:
                n = struct.unpack_from("<H", p, 1)[0]; print(f"  {n} spells:", [struct.unpack_from("<H", p, 3 + 4 * i)[0] for i in range(n)][:12], "...")
            if op == 0x129:
                b = struct.unpack("<120I", p); print("  action buttons:", {i: (v & 0xFFFFFF, v >> 24) for i, v in enumerate(b) if v})
            if op == 0x127: print("  proficiency class %d mask 0x%x" % struct.unpack("<BI", p))
            if op in (0x0A9, 0x1F6):
                objs = parse_update(op, p)
                for kind_, g, t, v, move in objs:
                    if t == 4:
                        b0 = v[UNIT_END - 0xB6 + 0x1E + 0]  # UNIT_FIELD_BYTES_0
                        print(f"  player guid {g}: {len(v)} fields; level {v[OBJECT_END + 0x1C]}, health {v[OBJECT_END + 0x10]}/{v[OBJECT_END + 0x16]}, "
                              f"race {b0 & 0xFF} class {(b0 >> 8) & 0xFF} power type {b0 >> 24}, display {v[OBJECT_END + 0x7D]}, "
                              f"faction {v[OBJECT_END + 0x1D]}, scale {f(v[4]):.2f}")
                        print(f"    stats {[v.get(OBJECT_END + 0x90 + i, 0) for i in range(5)]}, armor {v.get(OBJECT_END + 0x95, 0)}, "
                              f"AP {v.get(OBJECT_END + 0x9F, 0)}, damage {f(v.get(OBJECT_END + 0x80, 0)):.1f}-{f(v.get(OBJECT_END + 0x81, 0)):.1f} "
                              f"every {v.get(OBJECT_END + 0x78, 0)} ms, mana {v.get(OBJECT_END + 0x11, 0)}/{v.get(OBJECT_END + 0x17, 0)}")
                        skills = [(v[UNIT_END + 0x212 + 3 * i] & 0xFFFF, v[UNIT_END + 0x213 + 3 * i] & 0xFFFF, v[UNIT_END + 0x213 + 3 * i] >> 16) for i in range(128) if v.get(UNIT_END + 0x212 + 3 * i)]
                        print(f"    {len(skills)} skills:", skills[:8], "...", f"next level xp {v.get(UNIT_END + 0x211, 0)}, money {v.get(UNIT_END + 0x3DC, 0)}")
                        print(f"    position {move[0]:.2f} {move[1]:.2f} {move[2]:.2f}, run speed {move[4][1]}")
                        inv = {i: v[UNIT_END + 0x12A + 2 * i] for i in range(113) if v.get(UNIT_END + 0x12A + 2 * i)}
                        print(f"    inventory slots in use: {sorted(inv)}")
                    else:
                        print(f"  {'bag ' if t == 2 else 'item'} {g & 0xFFFFFFFF}: entry {v[3]} count {v.get(OBJECT_END + 8)} contained in {(v.get(OBJECT_END + 2, 0) | v.get(OBJECT_END + 3, 0) << 32):#x}"
                              + (f", {v[ITEM_END]} slots" if t == 2 else ""))
                me = [o for o in objs if o[2] == 4][0]; player_guid = me[1]
                items = {o[1]: o for o in objs if o[2] in (1, 2)}
                pv = me[3]
                for i in range(113):
                    if pv.get(UNIT_END + 0x12A + 2 * i):
                        ig = pv[UNIT_END + 0x12A + 2 * i] | pv.get(UNIT_END + 0x12B + 2 * i, 0) << 32
                        assert ig in items, f"slot {i} points at an object the client was not sent"
    elif kind == "query":
        wsend(0x050, struct.pack("<Q", player_guid)); op, p = wrecv(); assert op == 0x051
        name = p[8:p.index(b"\0", 8)].decode(); print(f"name query: '{name}'")
        for o in list(items.values())[:3]:
            entry = o[3][3]; wsend(0x056, struct.pack("<IQ", entry, 0)); op, p = wrecv(); assert op == 0x058
            iname = p[12:p.index(b"\0", 12)].decode(); print(f"item query {entry}: '{iname}', {len(p)} bytes")
        wsend(0x1CE, b""); op, p = wrecv(); print("query time:", struct.unpack("<I", p)[0])
    elif kind == "move":
        x, y, z = map(float, args); movement(0x0B5, x, y, z, flags=1); movement(0x0EE, x, y, z, flags=1); movement(0x0B7, x, y, z)
        print(f"moved to {x} {y} {z}")
    elif kind == "say":
        wsend(0x095, struct.pack("<II", 0, 7) + args[0].encode() + b"\0"); op, p = wrecv()
        n = struct.unpack_from("<I", p, 24)[0]; print(f"heard: '{p[28:28 + n - 1].decode()}'")
    elif kind == "sit":
        wsend(0x101, struct.pack("<I", 1)); got = [wrecv(), wrecv()]
        objs = parse_update(*got[0]); print("sat down; update fields changed:", sorted(objs[0][3]))
    elif kind == "logout":
        wsend(0x04B, b""); got = until(0x04D); print("logout:", " ".join(OPS.get(op, hex(op)) for op, _ in got))
    elif kind == "drop":
        w.close(); print("connection dropped"); sys.exit(0)
    elif kind == "create":
        name, race, cls = args[0], int(args[1]), int(args[2])
        wsend(0x036, name.encode() + b"\0" + bytes([race, cls, 0, 0, 0, 1, 0, 0, 0]))
        op, p = wrecv(); print(f"create {name}: 0x{p[0]:02x}" + (" (success)" if p[0] == 0x2E else ""))
    elif kind == "enum":
        for name, (guid, race, cls, level, worn) in enum().items():
            print(f"  {name}: guid {guid} race {race} class {cls} level {level}, {worn} visible items")
    elif kind == "delete":
        guid = enum()[args[0]][0]
        wsend(0x038, struct.pack("<Q", guid))
        op, p = wrecv(); print(f"delete {args[0]}: 0x{p[0]:02x}" + (" (success)" if p[0] == 0x39 else ""))
w.close()
