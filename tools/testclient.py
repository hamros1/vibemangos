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
    whisper:NAME:TEXT         whisper to another player
    emote:ID                  a text emote (101 = /wave, 34 = /dance)
    wait:SECONDS              do nothing for a while (packets queue up)
    listen:SECONDS            print what other players do for a while
    cmd:TEXT                  say a chat command (".recall port Goldshire") and print what follows
    trigger:ID                walk into an area trigger (78 = the Deadmines entrance)
    worldport:MAP:X:Y:Z       the client's worldport command (administrators)
    invite:NAME  accept  decline  leave  raid
                              group invitations, leaving, converting to a raid
    party:TEXT  raidsay:TEXT  party and raid chat
    join:CHANNEL  part:CHANNEL  chan:CHANNEL:TEXT  chanlist:CHANNEL
                              chat channels
    afk:TEXT  dnd:TEXT        away and busy (an empty TEXT clears it)
    objects:N                 count the creatures and game objects seen, and query N of each

Teleports are answered as the client answers them: MSG_MOVE_TELEPORT_ACK for
a near one, MSG_MOVE_WORLDPORT_ACK after SMSG_NEW_WORLD, whenever they come.
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
GAMEOBJECT_END = OBJECT_END + 0x1A
COUNTS = {1: ITEM_END, 2: CONTAINER_END, 3: UNIT_END, 4: PLAYER_END, 5: GAMEOBJECT_END}
seen_objects = {}

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
        if kind == 4:  # out of range: a list of guids
            n = struct.unpack_from("<I", p, pos)[0]; pos += 4
            gone = []
            for _ in range(n):
                g, pos = packed_guid(p, pos); gone.append(g)
            objects.append((4, gone, None, {}, None))
            continue
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
       0x041: "CHARACTER_LOGIN_FAILED", 0x0C7: "MOVE_TELEPORT_ACK", 0x0C5: "MOVE_TELEPORT", 0x03F: "TRANSFER_PENDING",
       0x03E: "NEW_WORLD", 0x040: "TRANSFER_ABORTED", 0x06F: "GROUP_INVITE", 0x074: "GROUP_DECLINE", 0x077: "GROUP_UNINVITE",
       0x079: "GROUP_SET_LEADER", 0x07C: "GROUP_DESTROYED", 0x07D: "GROUP_LIST", 0x07E: "PARTY_MEMBER_STATS",
       0x07F: "PARTY_COMMAND_RESULT", 0x099: "CHANNEL_NOTIFY", 0x09B: "CHANNEL_LIST", 0x2B8: "AREA_TRIGGER_MESSAGE",
       0x1CB: "NOTIFICATION", 0x2F2: "PARTY_MEMBER_STATS_FULL", 0x166: "ITEM_PUSH_RESULT", 0x1D4: "LEVELUP_INFO",
       0x12B: "LEARNED_SPELL", 0x203: "REMOVED_SPELL", 0x291: "SERVER_MESSAGE", 0x2D2: "PLAY_SOUND",
       0x0E2: "FORCE_RUN_SPEED_CHANGE", 0x0E6: "FORCE_SWIM_SPEED_CHANGE", 0x0E4: "FORCE_RUN_BACK_SPEED_CHANGE",
       0x2DC: "FORCE_SWIM_BACK_SPEED_CHANGE", 0x0E8: "FORCE_MOVE_ROOT", 0x0EA: "FORCE_MOVE_UNROOT",
       0x2C3: "UPDATE_WORLD_STATE", 0x0EF: "MOVE_KNOCK_BACK"}

import select, time
MOVES = set(range(0x0B5, 0x0C4)) | {0x0C9, 0x0CA, 0x0CB, 0x0DA, 0x0DB, 0x0EE}

def describe(op, p):
    """Prints a packet that another player caused."""
    if op in (0x0A9, 0x1F6):
        for kind, g, t, v, move in parse_update(op, p):
            if kind == 4: print(f"  [out of range] {g}")
            elif kind in (2, 3) and t == 4:
                b0 = v[OBJECT_END + 0x1E]
                print(f"  [appears] player {g}: race {b0 & 0xFF} class {(b0 >> 8) & 0xFF} level {v[OBJECT_END + 0x1C]}, "
                      f"health {v.get(OBJECT_END + 0x10)}/{v.get(OBJECT_END + 0x16)} (percent), {len(v)} fields, "
                      f"at {move[0]:.1f} {move[1]:.1f} {move[2]:.1f}")
            elif kind in (2, 3) and t in (3, 5):
                entry = v.get(3, 0); seen_objects[g] = (t, entry)
                if t == 3:
                    print(f"  [creature] {entry} guid {g & 0xFFFFFF}: level {v.get(OBJECT_END + 0x1C)}, health {v.get(OBJECT_END + 0x10)}, "
                          f"display {v.get(OBJECT_END + 0x7D)}, faction {v.get(OBJECT_END + 0x1D)}, npc flags {v.get(0x93, 0)}, "
                          f"at {move[0]:.1f} {move[1]:.1f} {move[2]:.1f}")
                else:
                    print(f"  [game object] {entry} guid {g & 0xFFFFFF}: type {v.get(OBJECT_END + 0x15)}, display {v.get(OBJECT_END + 0x8)}")
            elif kind == 0:
                health = f", health {v[OBJECT_END + 0x10]}/{v.get(OBJECT_END + 0x16, '?')}" if OBJECT_END + 0x10 in v else ""
                print(f"  [changes] {g}: fields {sorted(v)}{health}")
    elif op in MOVES:
        g, pos = packed_guid(p, 0); flags, t, x, y, z, o = struct.unpack_from("<II4f", p, pos)
        print(f"  [moves] {g} {OPS.get(op, hex(op))} to {x:.1f} {y:.1f} {z:.1f}")
    elif op == 0x096:
        kind, lang = struct.unpack_from("<BI", p); pos = 5; channel = ""
        if kind == 0x0E:
            end = p.index(b"\0", pos); channel = " in " + p[pos:end].decode(); pos = end + 1 + 4
        sender = struct.unpack_from("<Q", p, pos)[0]; pos += 16 if kind in (0, 1, 5) else 8
        n = struct.unpack_from("<I", p, pos)[0]; tag = p[pos + 4 + n]
        print(f"  [chat type {kind}{channel}] from {sender}: '{p[pos + 4:pos + 4 + n - 1].decode()}'" + (f" (tag {tag})" if tag else ""))
    elif op == 0x0C7:
        g, pos = packed_guid(p, 0); counter = struct.unpack_from("<I", p, pos)[0]
        x, y, z = struct.unpack_from("<3f", p, pos + 12)
        print(f"  [teleport] to {x:.1f} {y:.1f} {z:.1f}; answering")
        wsend(0x0C7, struct.pack("<QII", g, counter, 0))
    elif op == 0x0C5:
        g, pos = packed_guid(p, 0); x, y, z = struct.unpack_from("<3f", p, pos + 8); print(f"  [teleports] {g} to {x:.1f} {y:.1f} {z:.1f}")
    elif op == 0x03F: print(f"  [loading screen] map {struct.unpack('<I', p)[0]}")
    elif op == 0x03E:
        print("  [new world] map %d at %.1f %.1f %.1f; answering" % struct.unpack("<I4f", p)[:4]); wsend(0x0DC, b"")
    elif op == 0x040: print(f"  [transfer aborted] reason {p[0]}")
    elif op == 0x2B8: print(f"  [area trigger message] '{p[4:-1].decode()}'")
    elif op == 0x291: print(f"  [server message] type {struct.unpack_from('<I', p)[0]} '{p[4:-1].decode()}'")
    elif op == 0x166:
        received, created, show, bag, slot, entry, suffix, prop, count = struct.unpack_from("<IIIBIIIiI", p, 8)
        print(f"  [item received] {count} x {entry} in bag {bag} slot {slot if slot != 0xFFFFFFFF else 'stack'}")
    elif op == 0x1D4: print(f"  [level up] to level {struct.unpack_from('<I', p)[0]}")
    elif op == 0x12B: print(f"  [learned spell] {struct.unpack_from('<I', p)[0]}")
    elif op == 0x061:
        entry = struct.unpack_from("<I", p)[0]
        if entry & 0x80000000: print(f"  [creature query] {entry & 0x7FFFFFFF}: unknown")
        else:
            end = p.index(b"\0", 4); name = p[4:end].decode(); sub_end = p.index(b"\0", end + 4)
            print(f"  [creature query] {entry}: '{name}' <{p[end + 4:sub_end].decode()}>")
    elif op == 0x05F:
        entry, kind, display = struct.unpack_from("<III", p); end = p.index(b"\0", 12)
        print(f"  [object query] {entry}: '{p[12:end].decode()}' type {kind}")
    elif op == 0x1CB: print(f"  [notification] '{p[:-1].decode()}'")
    elif op == 0x06F: print(f"  [invited by] {p[:-1].decode()}")
    elif op == 0x074: print(f"  [declined] {p[:-1].decode()}")
    elif op == 0x079: print(f"  [new leader] {p[:-1].decode()}")
    elif op in (0x077, 0x07C): print(f"  [{OPS[op].lower()}]")
    elif op == 0x07F:
        operation = struct.unpack_from("<I", p)[0]; end = p.index(b"\0", 4)
        print(f"  [party result] operation {operation} '{p[4:end].decode()}' result {struct.unpack_from('<I', p, end + 1)[0]}")
    elif op == 0x07D:
        if len(p) == 24 and not any(p): print("  [group list] empty"); return
        kind, own, n = struct.unpack_from("<BBI", p); pos = 6; members = []
        for _ in range(n):
            end = p.index(b"\0", pos); name = p[pos:end].decode(); pos = end + 1
            g, status, flags = struct.unpack_from("<QBB", p, pos); pos += 10; members.append(f"{name} ({g}, status {status}, group {flags & 0x7F})")
        leader = struct.unpack_from("<Q", p, pos)[0]
        print(f"  [group list] {'raid' if kind else 'party'}, leader {leader}: {', '.join(members)}")
    elif op in (0x07E, 0x2F2):
        g, pos = packed_guid(p, 0); mask = struct.unpack_from("<I", p, pos)[0]; print(f"  [member stats] {g} mask {mask:#x}")
    elif op == 0x099:
        end = p.index(b"\0", 1); print(f"  [channel] notice {p[0]:#04x} '{p[1:end].decode()}' {p[end + 1:].hex()}")
    elif op == 0x09B:
        end = p.index(b"\0"); n = struct.unpack_from("<I", p, end + 2)[0]
        members = [struct.unpack_from("<QB", p, end + 6 + 9 * i) for i in range(n)]
        print(f"  [channel list] '{p[:end].decode()}': {members}")
    elif op == 0x103: print("  [animation] emote %d by %d" % struct.unpack("<IQ", p))
    elif op == 0x105:
        g, text, num, n = struct.unpack_from("<QIII", p); print(f"  [text emote] {text} by {g} at '{p[20:20 + n - 1].decode()}'")
    elif op == 0x0AA: print(f"  [destroyed] {struct.unpack('<Q', p)[0]}")
    elif op == 0x2A9: print(f"  [no such player] {p[:-1].decode()}")
    else: print(f"  [other] {OPS.get(op, hex(op))}")

def expect(wanted):
    """Reads until a packet with opcode `wanted`, describing anything else on the way."""
    while True:
        op, p = wrecv()
        if op == wanted: return op, p
        describe(op, p)

def until(last):
    got = []
    while True:
        op, p = wrecv(); got.append((op, p))
        if op == last or op == 0x041: return got

def listen_for(seconds):
    """Prints (and answers, for teleports) whatever arrives for a while."""
    end = time.time() + seconds
    while time.time() < end:
        if select.select([w], [], [], max(0, end - time.time()))[0]:
            op, p = wrecv(); describe(op, p)

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
                n = struct.unpack_from("<I", p, 13)[0]; print("  system message:", p[17:17 + n - 1].decode())
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
        wsend(0x050, struct.pack("<Q", player_guid)); op, p = expect(0x051)
        name = p[8:p.index(b"\0", 8)].decode(); print(f"name query: '{name}'")
        for o in list(items.values())[:3]:
            entry = o[3][3]; wsend(0x056, struct.pack("<IQ", entry, 0)); op, p = expect(0x058)
            iname = p[12:p.index(b"\0", 12)].decode(); print(f"item query {entry}: '{iname}', {len(p)} bytes")
        wsend(0x1CE, b""); op, p = expect(0x1CF); print("query time:", struct.unpack("<I", p)[0])
    elif kind == "move":
        x, y, z = map(float, args); movement(0x0B5, x, y, z, flags=1); movement(0x0EE, x, y, z, flags=1); movement(0x0B7, x, y, z)
        print(f"moved to {x} {y} {z}")
    elif kind == "say":
        wsend(0x095, struct.pack("<II", 0, 7) + args[0].encode() + b"\0"); op, p = expect(0x096)
        n = struct.unpack_from("<I", p, 21)[0]; print(f"heard: '{p[25:25 + n - 1].decode()}'")
    elif kind == "sit":
        wsend(0x101, struct.pack("<I", 1)); got = [expect(0x1F6)]
        objs = parse_update(*got[0]); print("sat down; update fields changed:", sorted(objs[0][3])); expect(0x29D)
    elif kind == "whisper":
        wsend(0x095, struct.pack("<II", 6, 7) + args[0].encode() + b"\0" + args[1].encode() + b"\0")
        op, p = wrecv(); describe(op, p)
    elif kind == "emote":
        wsend(0x104, struct.pack("<IIQ", int(args[0]), 0, 0)); print(f"emote {args[0]}")
    elif kind == "wait":
        time.sleep(float(args[0]))
    elif kind == "listen":
        listen_for(float(args[0]))
    elif kind == "cmd":
        wsend(0x095, struct.pack("<II", 0, 7) + ":".join(args).encode() + b"\0"); print(f"command '{':'.join(args)}'")
        listen_for(1.5)
    elif kind == "trigger":
        wsend(0x0B4, struct.pack("<I", int(args[0]))); print(f"area trigger {args[0]}"); listen_for(1.5)
    elif kind == "worldport":
        m, x, y, z = int(args[0]), *map(float, args[1:4])
        wsend(0x008, struct.pack("<II4f", 0, m, x, y, z, 0)); print(f"worldport {m} {x} {y} {z}"); listen_for(1.5)
    elif kind == "invite":
        wsend(0x06E, args[0].encode() + b"\0"); print(f"invite {args[0]}")
    elif kind in ("accept", "decline", "leave", "raid"):
        wsend({"accept": 0x072, "decline": 0x073, "leave": 0x07B, "raid": 0x28E}[kind], b""); print(kind)
    elif kind in ("party", "raidsay"):
        wsend(0x095, struct.pack("<II", 1 if kind == "party" else 2, 7) + ":".join(args).encode() + b"\0"); print(f"{kind} '{':'.join(args)}'")
    elif kind == "join":
        wsend(0x097, args[0].encode() + b"\0\0"); print(f"join channel {args[0]}")
    elif kind == "part":
        wsend(0x098, args[0].encode() + b"\0"); print(f"leave channel {args[0]}")
    elif kind == "chanlist":
        wsend(0x09A, args[0].encode() + b"\0"); print(f"list channel {args[0]}")
    elif kind == "chan":
        wsend(0x095, struct.pack("<II", 0x0E, 7) + args[0].encode() + b"\0" + ":".join(args[1:]).encode() + b"\0")
        print(f"to channel {args[0]}: '{':'.join(args[1:])}'")
    elif kind in ("afk", "dnd"):
        wsend(0x095, struct.pack("<II", 0x14 if kind == "afk" else 0x15, 0) + ":".join(args).encode() + b"\0"); print(f"{kind} '{':'.join(args)}'")
    elif kind == "objects":
        wanted = int(args[0]) if args else 5
        creatures = [(g, e) for g, (t, e) in seen_objects.items() if t == 3][:wanted]
        objects = [(g, e) for g, (t, e) in seen_objects.items() if t == 5][:wanted]
        print(f"seen {sum(1 for t, _ in seen_objects.values() if t == 3)} creatures and "
              f"{sum(1 for t, _ in seen_objects.values() if t == 5)} game objects; querying a few")
        for g, e in creatures: wsend(0x060, struct.pack("<IQ", e, g))
        for g, e in objects: wsend(0x05E, struct.pack("<IQ", e, g))
        listen_for(1.5)
    elif kind == "logout":
        wsend(0x04B, b""); op, p = expect(0x04C)
        if p[4] == 0: print("logout: waiting 20 seconds"); w.settimeout(30)
        got = [(op, p)] + until(0x04D); w.settimeout(5); print("logout:", " ".join(OPS.get(op, hex(op)) for op, _ in got))
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
