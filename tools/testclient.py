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
    yell:TEXT                 yell something (heard 300 yards around)
    sit                       sit down and print the changed fields
    whisper:NAME:TEXT         whisper to another player
    attack:ENTRY  stopattack  walk up to the nearest creature of ENTRY and fight it; stop
    approach:ENTRY:DIST       walk to DIST yards of the nearest creature of ENTRY
    loot                      walk to the creature last attacked, take its money and items
    release  corpse  tocorpse  reclaim  spirithealer
                              dead: release the spirit, ask where the corpse is, go there, take it
                              back; or ask the spirit healer picked with npc:ENTRY
    who[:TEXT]                /who, everyone or those matching TEXT, and print the list
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
    bgjoin:NPC:MAP  bgport:MAP:1  bgleave:MAP  bgstatus  pvplog
                              battlegrounds: queue at a battlemaster, accept, leave, the scoreboard
    objects:N                 count the creatures and game objects seen, and query N of each
    npc:ENTRY                 pick a creature in sight by entry, for the NPC actions:
    gossip  select:N  text:ID  trainer  buyspell:ID  vendor  binder  bank
    buy:ENTRY[:COUNT]  sell:SLOT  buyback:N  repair  buybankslot
                              trade with the NPC (SLOT: a backpack or equipment slot;
                              N: the buyback slot from 0)
    inv                       print the carried items, as the client now knows them
    equip:SLOT  swap:SRC:DST  split:SRC:DST:COUNT  destroy:SLOT[:COUNT]
    tobank:SLOT  frombank:SLOT
                              move items between the character's own slots

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
# WORLD=host:port picks the world server instead of the realm list (a given node of a cluster).
host, port = os.environ.get("WORLD", addr.decode()).rsplit(":", 1)
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
COUNTS = {1: ITEM_END, 2: CONTAINER_END, 3: UNIT_END, 4: PLAYER_END, 5: GAMEOBJECT_END, 7: 0x26}  # 7: CORPSE_END
seen_objects = {}
seen_positions = {}   # creature guid -> where it was created
here = [0.0, 0.0, 0.0]  # where this client last put its character
corpse_at = [0.0, 0.0, 0.0]
last_target = [0]
duel_flag = [0]
my_guid = [0]
pet_info = {}
item_objects = {}  # guid -> fields of the items the client was sent
my_slots = {}      # the player's own slots: slot -> item guid
player_guid = None
SLOT_FIELD = UNIT_END + 0x12A  # PLAYER_FIELD_INV_SLOT_HEAD

def track(objs):
    """Keeps `item_objects` and `my_slots` as the client would."""
    for kind, g, t, v, move in objs:
        if kind == 4:
            for gone in g: item_objects.pop(gone, None)
        elif kind in (2, 3) and t in (1, 2): item_objects[g] = dict(v)
        elif kind == 0 and g in item_objects: item_objects[g].update(v)
        if g == player_guid and kind in (0, 2, 3):
            for i in range(113):
                if SLOT_FIELD + 2 * i in v or SLOT_FIELD + 2 * i + 1 in v:
                    ig = v.get(SLOT_FIELD + 2 * i, 0) | v.get(SLOT_FIELD + 2 * i + 1, 0) << 32
                    if ig: my_slots[i] = ig
                    else: my_slots.pop(i, None)
    for slot, ig in my_slots.items():
        assert ig in item_objects, f"slot {slot} points at item {ig:#x}, which the client was not sent"

def packed(guid):
    """A guid in packed form: a mask of its non-zero bytes, then those bytes."""
    mask, out = 0, b""
    for i in range(8):
        b = (guid >> (8 * i)) & 0xFF
        if b:
            mask |= 1 << i; out += bytes([b])
    return bytes([mask]) + out


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
                if mflags & 0x00400000:  # walking a spline: flags, facing, times, id, path, destination
                    sflags = struct.unpack_from("<I", p, pos)[0]; pos += 4
                    pos += 12 if sflags & 0x10000 else 8 if sflags & 0x20000 else 4 if sflags & 0x40000 else 0
                    passed, duration, sid, nodes = struct.unpack_from("<IIII", p, pos); pos += 16 + 12 * nodes + 12
                    print(f"  [walking] {guid & 0xFFFFFF}: {passed}/{duration} ms along spline {sid} of {nodes} points")
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
       0x2C3: "UPDATE_WORLD_STATE", 0x0EF: "MOVE_KNOCK_BACK", 0x0DD: "MONSTER_MOVE"}

import select, time
MOVES = set(range(0x0B5, 0x0C4)) | {0x0C9, 0x0CA, 0x0CB, 0x0DA, 0x0DB, 0x0EE}

def describe(op, p):
    """Prints a packet that another player caused."""
    if op in (0x0A9, 0x1F6):
        objs = parse_update(op, p); track(objs)
        for kind, g, t, v, move in objs:
            if kind in (2, 3) and t in (1, 2): print(f"  [item created] {g & 0xFFFFFFFF}: entry {v[3]} count {v.get(OBJECT_END + 8)}")
            elif kind == 0 and g in item_objects: print(f"  [item changed] {g & 0xFFFFFFFF}: fields {sorted(v)}")
            elif kind == 0 and g == player_guid: print(f"  [player changed] {len(v)} fields")
            elif kind == 4: print(f"  [out of range] {', '.join(str(x & 0xFFFFFFFF) for x in g)}")
            elif kind in (2, 3) and t == 4:
                seen_objects[g] = (t, 0)
                b0 = v[OBJECT_END + 0x1E]
                print(f"  [appears] player {g}: race {b0 & 0xFF} class {(b0 >> 8) & 0xFF} level {v[OBJECT_END + 0x1C]}, "
                      f"health {v.get(OBJECT_END + 0x10)}/{v.get(OBJECT_END + 0x16)} (percent), {len(v)} fields, "
                      f"at {move[0]:.1f} {move[1]:.1f} {move[2]:.1f}")
            elif kind in (2, 3) and t == 7:
                print(f"  [corpse appears] {g & 0xFFFFFF} at {move[0]:.1f} {move[1]:.1f} {move[2]:.1f}" if move else
                      f"  [corpse appears] {g & 0xFFFFFF}")
            elif kind in (2, 3) and t in (3, 5):
                entry = v.get(3, 0); seen_objects[g] = (t, entry)
                if move: seen_positions[g] = move[:3]
                if t == 3:
                    print(f"  [creature] {entry} guid {g & 0xFFFFFF}: level {v.get(OBJECT_END + 0x1C)}, health {v.get(OBJECT_END + 0x10)}, "
                          f"display {v.get(OBJECT_END + 0x7D)}, faction {v.get(OBJECT_END + 0x1D)}, npc flags {v.get(0x93, 0)}, "
                          f"at {move[0]:.1f} {move[1]:.1f} {move[2]:.1f}")
                else:
                    # GAMEOBJECT_POS_X .. _Z (0xF .. 0x11) where the movement block has no position.
                    if not move and 0xF in v:
                        seen_positions[g] = tuple(struct.unpack("<f", struct.pack("<I", v[i]))[0] for i in (0xF, 0x10, 0x11))
                    print(f"  [game object] {entry} guid {g & 0xFFFFFF}: type {v.get(0x15)}, display {v.get(0x8)}, "
                          f"state {v.get(0xE)}")
            elif kind == 0:
                health = f", health {v[OBJECT_END + 0x10]}/{v.get(OBJECT_END + 0x16, '?')}" if OBJECT_END + 0x10 in v else ""
                print(f"  [changes] {g}: fields {sorted(v)}{health}")
    elif op == 0x179:
        if len(p) <= 8:
            print("  [pet spells] none (no pet)"); return
        guid, _, react, command = struct.unpack_from("<QIBB", p); pet_info["guid"] = guid
        bar = struct.unpack_from("<10I", p, 16)
        count = p[56]; spells = struct.unpack_from(f"<{count}I", p, 57)
        print(f"  [pet spells] pet {guid:#x}: react {react}, command {command}, bar "
              f"{[(b & 0xFFFFFF, b >> 24) for b in bar]}, spells {[(x & 0xFFFFFF, x >> 24) for x in spells]}")
    elif op == 0x053:
        number = struct.unpack_from("<I", p)[0]; name = p[4:p.index(0, 4)].decode()
        print(f"  [pet name] {number}: '{name}'")
    elif op == 0x173: print(f"  [pet tame failure] reason {p[0]}")
    elif op == 0x2C6: print(f"  [pet action feedback] {p[0]}")
    elif op == 0x273: print(f"  [stable result] {p[0]:#x}")
    elif op == 0x26F:
        n = p[8]; slots = p[9]; pos = 10; pets = []
        for _ in range(n):
            number, entry, level = struct.unpack_from("<III", p, pos); pos += 12
            end = p.index(0, pos); name = p[pos:end].decode(); pos = end + 1
            loyalty, slot = struct.unpack_from("<IB", p, pos); pos += 5
            pets.append((number, entry, level, name, slot))
        print(f"  [stabled pets] {slots} slots bought: {pets}")
    elif op == 0x143:
        a, v = struct.unpack("<QQ", p); print(f"  [attack start] {a & 0xFFFFFF} -> {v & 0xFFFFFF}")
    elif op == 0x144:
        a, pos = packed_guid(p, 0); v, pos = packed_guid(p, pos); print(f"  [attack stop] {a & 0xFFFFFF} -> {v & 0xFFFFFF}")
    elif op in (0x145, 0x146, 0x147, 0x148, 0x149):
        print("  [swing error] " + {0x145: "not in range", 0x146: "bad facing", 0x147: "not standing",
                                    0x148: "dead target", 0x149: "can't attack"}[op])
    elif op == 0x14E:
        print("  [cancel combat]")
    elif op == 0x269:
        print(f"  [corpse reclaim delay] {struct.unpack_from('<I', p, 0)[0] / 1000:.0f} s")
    elif op == 0x2BD:
        print("  [durability lost on death]")
    elif op in (0x0E8, 0x0EA, 0x0DE, 0x0DF):
        print("  [" + {0x0E8: "rooted", 0x0EA: "unrooted", 0x0DE: "water walk", 0x0DF: "land walk"}[op] + "]")
    elif op == 0x14A:
        info, = struct.unpack_from("<I", p, 0); a, pos = packed_guid(p, 4); v, pos = packed_guid(p, pos)
        total, lines = struct.unpack_from("<IB", p, pos); pos += 5 + lines * 20
        state, _, _, blocked = struct.unpack_from("<IIII", p, pos)
        outcome = ("miss" if info & 0x10 else "crit" if info & 0x80 else "glance" if info & 0x4000
                   else "crush" if info & 0x8000 else {2: "dodge", 3: "parry", 5: "block", 6: "evade"}.get(state, "hit"))
        print(f"  [swing] {a & 0xFFFFFF} -> {v & 0xFFFFFF}: {outcome} for {total}" + (f" ({blocked} blocked)" if blocked else ""))
    elif op == 0x103:
        e, g = struct.unpack("<IQ", p); print(f"  [emote] {g & 0xFFFFFF}: {e}")
    elif op == 0x0DD:
        g, pos = packed_guid(p, 0)
        x, y, z, sid, kind = struct.unpack_from("<3fIB", p, pos); pos += 17
        if kind == 1:
            print(f"  [monster stops] {g & 0xFFFFFF} at {x:.1f} {y:.1f} {z:.1f}")
            if g in seen_positions: seen_positions[g] = (x, y, z)
            return
        facing = ""
        if kind == 4: facing = f", facing {struct.unpack_from('<f', p, pos)[0]:.2f}"; pos += 4
        elif kind == 2: pos += 12
        elif kind == 3: pos += 8
        flags, duration, count, dx, dy, dz = struct.unpack_from("<III3f", p, pos)
        entry = seen_objects.get(g, (0, 0))[1]
        if g in seen_positions: seen_positions[g] = (dx, dy, dz)
        print(f"  [monster moves] {entry} guid {g & 0xFFFFFF}: from {x:.1f} {y:.1f} {z:.1f} to {dx:.1f} {dy:.1f} {dz:.1f}, "
              f"{count} points, {duration} ms, flags {flags:#x}{facing}")
    elif op in MOVES:
        g, pos = packed_guid(p, 0); flags, t, x, y, z, o = struct.unpack_from("<II4f", p, pos)
        print(f"  [moves] {g} {OPS.get(op, hex(op))} to {x:.1f} {y:.1f} {z:.1f}")
    elif op == 0x096:
        kind, lang = struct.unpack_from("<BI", p); pos = 5; channel = ""
        if kind == 0x0E:
            end = p.index(b"\0", pos); channel = " in " + p[pos:end].decode(); pos = end + 1 + 4
        if kind in (0x0B, 0x0C, 0x0D, 0x1A, 0x59, 0x5A):
            # A creature's: (its guid,) its name, whom it addresses, the text.
            sender = 0
            if kind in (0x0B, 0x0C):
                sender = struct.unpack_from("<Q", p, pos)[0]; pos += 8
            n = struct.unpack_from("<I", p, pos)[0]; name = p[pos + 4:pos + 4 + n - 1].decode(); pos += 4 + n
            listener = struct.unpack_from("<Q", p, pos)[0]; pos += 8
            n = struct.unpack_from("<I", p, pos)[0]
            print(f"  [monster chat type {kind:#x}, language {lang}] {name} ({sender & 0xFFFFFF}) to {listener}: "
                  f"'{p[pos + 4:pos + 4 + n - 1].decode()}'")
        else:
            sender = struct.unpack_from("<Q", p, pos)[0]; pos += 16 if kind in (0, 1, 5) else 8
            n = struct.unpack_from("<I", p, pos)[0]; tag = p[pos + 4 + n]
            print(f"  [chat type {kind}{channel}] from {sender}: '{p[pos + 4:pos + 4 + n - 1].decode()}'" + (f" (tag {tag})" if tag else ""))
    elif op == 0x0C7:
        g, pos = packed_guid(p, 0); counter = struct.unpack_from("<I", p, pos)[0]
        x, y, z = struct.unpack_from("<3f", p, pos + 12)
        print(f"  [teleport] to {x:.1f} {y:.1f} {z:.1f}; answering")
        here[:] = [x, y, z]
        wsend(0x0C7, struct.pack("<QII", g, counter, 0))
    elif op == 0x0C5:
        g, pos = packed_guid(p, 0); x, y, z = struct.unpack_from("<3f", p, pos + 8); print(f"  [teleports] {g} to {x:.1f} {y:.1f} {z:.1f}")
    elif op == 0x03F: print(f"  [loading screen] map {struct.unpack('<I', p)[0]}")
    elif op == 0x03E:
        print("  [new world] map %d at %.1f %.1f %.1f; answering" % struct.unpack("<I4f", p)[:4]); wsend(0x0DC, b"")
    elif op == 0x040: print(f"  [transfer aborted] reason {p[0]}")
    elif op == 0x2D4:
        slot, mapid = struct.unpack_from("<II", p, 0)
        if mapid == 0: print(f"  [battlefield status] slot {slot}: none")
        else:
            instance, status = struct.unpack_from("<II", p, 9)
            times = struct.unpack_from("<" + "I" * ((len(p) - 17) // 4), p, 17)
            names = {1: "queued", 2: "invited", 3: "in progress"}
            print(f"  [battlefield status] slot {slot}: map {mapid} copy {instance} {names.get(status, status)} {list(times)}")
    elif op == 0x23D:
        g, mapid, _, n = struct.unpack_from("<QIBI", p, 0)
        print(f"  [battlefield list] map {mapid}: copies {list(struct.unpack_from('<' + 'I' * n, p, 17))}")
    elif op == 0x2E8: print(f"  [group joined battleground] {struct.unpack('<i', p)[0]}")
    elif op == 0x2EC: print(f"  [battleground player joined] {struct.unpack('<Q', p)[0] & 0xFFFFFFFF}")
    elif op == 0x2ED: print(f"  [battleground player left] {struct.unpack('<Q', p)[0] & 0xFFFFFFFF}")
    elif op == 0x2E0:
        over = p[0]; pos = 2 if over else 1; n = struct.unpack_from("<I", p, pos)[0]
        print(f"  [scoreboard] {'over, winner ' + str(p[1]) if over else 'running'}, {n} players")
    elif op == 0x2B8: print(f"  [area trigger message] '{p[4:-1].decode()}'")
    elif op == 0x291: print(f"  [server message] type {struct.unpack_from('<I', p)[0]} '{p[4:-1].decode()}'")
    elif op == 0x166:
        received, created, show, bag, slot, entry, suffix, prop, count = struct.unpack_from("<IIIBIIIiI", p, 8)
        print(f"  [item received] {count} x {entry} in bag {bag} slot {slot if slot != 0xFFFFFFFF else 'stack'}")
    elif op == 0x1D4: print(f"  [level up] to level {struct.unpack_from('<I', p)[0]}")
    elif op == 0x1D0: print("  [experience] %d (kind %d)" % struct.unpack_from("<IB", p, 8))
    elif op == 0x161: print("  [loot window closed]")
    elif op == 0x099: print(f"  [learned spell] {struct.unpack_from('<I', p, 0)[0]}")
    elif op == 0x17D:
        g, text, n = struct.unpack_from("<QII", p, 0); pos = 16
        for i in range(n):
            pos += 6; end = p.index(b"\0", pos); pos = end + 1
        q = struct.unpack_from("<I", p, pos)[0]; pos += 4; quests = []
        for i in range(q):
            qid, icon, lvl = struct.unpack_from("<IIi", p, pos); pos += 12; end = p.index(b"\0", pos)
            quests.append((qid, icon, p[pos:end].decode())); pos = end + 1
        print(f"  [gossip] {n} options, quests {quests}")
    elif op == 0x188:
        g, qid = struct.unpack_from("<QI", p, 0); title = p[12:p.index(b"\0", 12)].decode(); print(f"  [quest details] {qid}: {title}")
    elif op == 0x18B: print(f"  [quest request items] {struct.unpack_from('<I', p, 8)[0]}")
    elif op == 0x18D: print(f"  [quest offer reward] {struct.unpack_from('<I', p, 8)[0]}")
    elif op == 0x191:
        qid, _, xp, money = struct.unpack_from("<IIII", p, 0); print(f"  [quest complete] {qid}: {xp} xp, {money} copper")
    elif op == 0x198: print(f"  [quest objectives done] {struct.unpack_from('<I', p, 0)[0]}")
    elif op == 0x067:
        n = p[0]; at = 1; friends = []
        for _ in range(n):
            guid, status = struct.unpack_from("<QB", p, at); at += 9
            if status:
                area, level, cls = struct.unpack_from("<III", p, at); at += 12
                friends.append(f"{guid & 0xFFFFFF} online (zone {area}, level {level}, class {cls})")
            else:
                friends.append(f"{guid & 0xFFFFFF} offline")
        print(f"  [friend list] {n}: " + ", ".join(friends))
    elif op == 0x06B: print(f"  [ignore list] {p[0]}")
    elif op == 0x092:
        ev, n = p[0], p[1]; parts = p[2:].split(b"\0")[:n]
        print(f"  [guild event] {ev}: " + ", ".join(x.decode(errors='replace') for x in parts))
    elif op == 0x093:
        cmd = struct.unpack_from("<I", p, 0)[0]; txt = p[4:p.index(0, 4)]; res = struct.unpack_from("<I", p, p.index(0, 4) + 1)[0]
        print(f"  [guild result] command {cmd} '{txt.decode(errors='replace')}' result {res}")
    elif op == 0x088:
        name = p[:p.index(0)]; d, m, y, members, accounts = struct.unpack_from("<IIIII", p, p.index(0) + 1)
        print(f"  [guild info] {name.decode()}: created {y}-{m:02}-{d:02}, {members} members, {accounts} accounts")
    elif op == 0x08A:
        count = struct.unpack_from("<I", p, 0)[0]; motd = p[4:p.index(0, 4)]
        print(f"  [guild roster] {count} members, motd '{motd.decode(errors='replace')}'")
    elif op == 0x055:
        gid = struct.unpack_from("<I", p, 0)[0]; name = p[4:p.index(0, 4)]
        print(f"  [guild query] {gid}: {name.decode(errors='replace')}")
    elif op == 0x068: print(f"  [friend status] result {p[0]} guid {struct.unpack_from('<Q', p, 1)[0] & 0xFFFFFF}")
    elif op == 0x199:
        qid, entry_, count, req = struct.unpack_from("<IIII", p, 0); print(f"  [quest kill] {qid}: {entry_} {count}/{req}")
    elif op == 0x18F: print(f"  [quest invalid] {struct.unpack_from('<I', p, 0)[0]}")
    elif op == 0x167:
        flag, by = struct.unpack_from("<QQ", p, 0); duel_flag[0] = flag; print(f"  [duel requested] by {by & 0xFFFFFF}")
    elif op == 0x2B7: print(f"  [duel countdown] {struct.unpack_from('<I', p, 0)[0]} ms")
    elif op == 0x16A: print(f"  [duel complete] {p[0]}")
    elif op == 0x16B:
        kind_ = p[0]; names = p[1:].split(b"\0")
        print(f"  [duel winner] {names[0].decode()} beat {names[1].decode()}" + (" (fled)" if kind_ else ""))
    elif op == 0x168: print("  [duel: out of bounds]")
    elif op == 0x123: print(f"  [faction visible] {struct.unpack_from('<I', p, 0)[0]}")
    elif op == 0x1A9:
        node = struct.unpack_from("<I", p, 12)[0]; mask = struct.unpack_from("<8I", p, 16)
        known = [i * 32 + b + 1 for i in range(8) for b in range(32) if mask[i] & (1 << b)]
        print(f"  [taxi nodes] at {node}, known {known[:20]}{'...' if len(known) > 20 else ''}")
    elif op == 0x1AB: print(f"  [taxi node status] {p[8]}")
    elif op == 0x1AE: print(f"  [taxi reply] {struct.unpack_from('<I', p, 0)[0]}")
    elif op == 0x1AF: print("  [new taxi path]")
    elif op == 0x124:
        n = struct.unpack_from("<I", p, 0)[0]
        print("  [faction standing] " + ", ".join(f"{struct.unpack_from('<I', p, 4 + 8 * i)[0]}: "
              f"{struct.unpack_from('<i', p, 8 + 8 * i)[0]}" for i in range(n)))
    elif op == 0x130:
        spell, status = struct.unpack_from("<IB", p, 0)
        print(f"  [cast result] {spell}: " + ("ok" if status == 0 else f"failed {p[5]:#x}"))
    elif op == 0x131:
        g, pos = packed_guid(p, 0); g2, pos = packed_guid(p, pos); spell, flags, time_ = struct.unpack_from("<IHI", p, pos)
        print(f"  [spell start] {spell} by {g & 0xFFFFFF}, {time_} ms")
    elif op == 0x132:
        g, pos = packed_guid(p, 0); g2, pos = packed_guid(p, pos); spell, flags = struct.unpack_from("<IH", p, pos)
        print(f"  [spell go] {spell} by {g & 0xFFFFFF}")
    elif op == 0x133:
        g, pos = packed_guid(p, 0); spell, reason = struct.unpack_from("<IB", p, pos); print(f"  [spell failed] {spell} reason {reason:#x}")
    elif op == 0x250:
        t, pos = packed_guid(p, 0); a, pos = packed_guid(p, pos); spell, dmg, school = struct.unpack_from("<IIB", p, pos)
        print(f"  [spell damage] {spell}: {dmg} to {t & 0xFFFFFF}")
    elif op == 0x150:
        t, pos = packed_guid(p, 0); a, pos = packed_guid(p, pos); spell, amount = struct.unpack_from("<II", p, pos)
        print(f"  [spell heal] {spell}: {amount}")
    elif op == 0x24B: print(f"  [spell missed] {struct.unpack_from('<I', p, 0)[0]} ({p[-1]})")
    elif op == 0x137: print(f"  [aura duration] slot {p[0]}: {struct.unpack_from('<i', p, 1)[0]} ms")
    elif op == 0x24E:
        t, pos = packed_guid(p, 0); c, pos = packed_guid(p, pos); spell, n, aura = struct.unpack_from("<III", p, pos)
        print(f"  [periodic] {spell} aura {aura}: {struct.unpack_from('<I', p, pos + 12)[0]}")
    elif op == 0x29: print(f"  [stand state] {p[0]}")
    elif op == 0x162: print(f"  [loot removed] slot {p[0]}")
    elif op == 0x165: print("  [loot money taken]")
    elif op == 0x166:
        g, rec, cre, chat, bag, slot, entry, suffix, prop, count = struct.unpack_from("<QIIIBIIIiI", p, 0)
        print(f"  [item received] {entry} x{count}")
    elif op == 0x1F8: print("  [discovered] area %d: %d experience" % struct.unpack("<II", p))
    elif op == 0x2C2: print("  [world states] map %d zone %d" % struct.unpack_from("<II", p))
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
    elif op == 0x17D:
        g, text, n = struct.unpack_from("<QII", p); pos = 16; items = []
        for _ in range(n):
            index, icon, coded = struct.unpack_from("<IBB", p, pos); end = p.index(b"\0", pos + 6)
            items.append(f"{index}:{p[pos + 6:end].decode()} (icon {icon})"); pos = end + 1
        print(f"  [gossip] {g} text {text}: {'; '.join(items) if items else 'no options'}")
    elif op == 0x17E: print("  [gossip closed]")
    elif op == 0x224:
        flags, x, y, icon, data = struct.unpack_from("<IffII", p); print(f"  [map flag] '{p[20:-1].decode()}' at {x:.0f} {y:.0f}")
    elif op == 0x180:
        text_id, prob = struct.unpack_from("<If", p); end = p.index(b"\0", 8)
        print(f"  [npc text] {text_id}: '{p[8:end].decode()}'")
    elif op == 0x1B1:
        g, kind, n = struct.unpack_from("<QII", p); spells = []
        for i in range(n):
            spell, state, cost = struct.unpack_from("<IBI", p, 16 + 38 * i); level = p[16 + 38 * i + 17]
            spells.append(f"{spell} {('green', 'red', 'gray')[state]} {cost}c lvl {level}")
        print(f"  [trainer] type {kind}, {n} spells, greeting '{p[16 + 38 * n:-1].decode()}': {'; '.join(spells[:8])}")
    elif op == 0x1B3: print("  [bought] trainer %d spell %d" % struct.unpack("<QI", p))
    elif op == 0x12C: print("  [superseded] %d by %d" % struct.unpack("<HH", p))
    elif op == 0x19F:
        g, n = struct.unpack_from("<QB", p)
        wares = [struct.unpack_from("<7I", p, 9 + 28 * i) for i in range(n)]
        print(f"  [vendor] {n} items: " + "; ".join(f"{w[1]} for {w[4]}c" for w in wares[:8]))
    elif op == 0x2EB: print(f"  [bind here?] {struct.unpack('<Q', p)[0]}")
    elif op == 0x155: print("  [hearthstone bound] %.1f %.1f %.1f map %d zone %d" % struct.unpack("<3fII", p))
    elif op == 0x158: print("  [bound by] %d in area %d" % struct.unpack("<QI", p))
    elif op == 0x1B8: print(f"  [bank opened] {struct.unpack('<Q', p)[0]}")
    elif op == 0x2A9: print(f"  [no such player] {p[:-1].decode()}")
    elif op == 0x112:
        print(f"  [inventory error] {p[0]}" + (" items %d %d bag %d" % struct.unpack_from("<QQB", p, len(p) - 17) if len(p) > 1 else ""))
    elif op == 0x1A4: print("  [bought] from %d slot %d, %d left, %d items" % struct.unpack("<QIII", p))
    elif op == 0x1A5: print("  [buy failed] from %d slot %d: %d" % struct.unpack("<QIB", p))
    elif op == 0x1A1: print("  [sell failed] at %d item %d: %d" % struct.unpack("<QQB", p))
    elif op == 0x1BA: print(f"  [bank slot] result {struct.unpack('<I', p)[0]}")
    elif op == 0x113: print(f"  [bag opened] {struct.unpack('<Q', p)[0] & 0xFFFFFFFF}")
    elif op == 0x2F4:
        wtype, grade, sound = struct.unpack_from("<IfI", p)
        print(f"  [weather] {['fine', 'rain', 'snow', 'storm'][wtype] if wtype < 4 else wtype} grade {grade:.2f} sound {sound}")
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

npc = None  # the creature the NPC actions talk to (`npc:ENTRY`)
for action in actions:
    kind, *args = action.split(":")
    if kind == "login":
        guid = enum()[args[0]][0]
        wsend(0x03D, struct.pack("<Q", guid))
        got = until(0x2C2)
        print("login packets:", " ".join(OPS.get(op, hex(op)) for op, _ in got))
        for op, p in got:
            if op == 0x041: print("  login failed, reason", p[0]); sys.exit(1)
            if op == 0x236:
                print("  verify world: map %d at %.2f %.2f %.2f o %.2f" % struct.unpack("<I4f", p))
                here[:] = list(struct.unpack_from("<3f", p, 4))
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
                        my_guid[0] = g
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
                me = [o for o in objs if o[2] == 4][0]; player_guid = me[1]; track(objs)
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
    elif kind == "attack":
        # Walk up to the nearest creature of ENTRY, face it, and start attacking.
        import math
        entry = int(args[0])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
        if not found:
            print(f"attack {entry}: not in sight"); continue
        target = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        cx, cy, cz = seen_positions[target]
        angle = math.atan2(here[1] - cy, here[0] - cx)
        x, y = cx + 1.5 * math.cos(angle), cy + 1.5 * math.sin(angle)
        o = math.atan2(cy - y, cx - x) % (2 * math.pi)
        movement(0x0B5, x, y, cz, o, flags=1); movement(0x0B7, x, y, cz, o); here[:] = [x, y, cz]
        wsend(0x141, struct.pack("<Q", target)); print(f"attack {entry}: {target & 0xFFFFFF} at {cx:.1f} {cy:.1f}")
        last_target[:] = [target]
    elif kind == "target":
        # Select the nearest creature of ENTRY (CMSG_SET_SELECTION), for the GM commands that act on it.
        entry = int(args[0])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
        if not found:
            print(f"target {entry}: not in sight"); continue
        target = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        wsend(0x13D, struct.pack("<Q", target)); print(f"target {entry}: {target & 0xFFFFFF}"); pet_info["target"] = target
    elif kind == "approach":
        # Walk to DIST yards of the nearest creature of ENTRY, without attacking it.
        import math
        entry, dist = int(args[0]), float(args[1])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
        if not found:
            print(f"approach {entry}: not in sight"); continue
        target = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        cx, cy, cz = seen_positions[target]
        angle = math.atan2(here[1] - cy, here[0] - cx)
        x, y = cx + dist * math.cos(angle), cy + dist * math.sin(angle)
        o = math.atan2(cy - y, cx - x) % (2 * math.pi)
        movement(0x0B5, x, y, cz, o, flags=1); movement(0x0B7, x, y, cz, o); here[:] = [x, y, cz]
        print(f"approach {entry}: {dist} yards from {target & 0xFFFFFF}")
    elif kind == "loot":
        # Walk to the last creature attacked and open its loot; take the money and every item, then close.
        import math
        target = last_target[0]
        cx, cy, cz = seen_positions[target]
        angle = math.atan2(here[1] - cy, here[0] - cx)
        x, y = cx + 1.5 * math.cos(angle), cy + 1.5 * math.sin(angle)
        movement(0x0B5, x, y, cz, flags=1); movement(0x0B7, x, y, cz); here[:] = [x, y, cz]
        wsend(0x15D, struct.pack("<Q", target)); print(f"loot {target & 0xFFFFFF}")
        op, p = expect(0x160)
        gold, n = struct.unpack_from("<IB", p, 9) if len(p) > 10 else (0, 0)
        if len(p) <= 10:
            print(f"  loot error {p[9]}"); continue
        slots = []
        for i in range(n):
            slot, item, count = struct.unpack_from("<BII", p, 14 + i * 22); slots.append(slot)
            print(f"  loot slot {slot}: item {item} x{count} (slot type {p[14 + i * 22 + 21]})")
        print(f"  loot gold {gold}")
        if gold:
            wsend(0x15E, b"")
        for slot in slots:
            wsend(0x108, bytes([slot]))
        listen_for(1.0)
        wsend(0x15F, struct.pack("<Q", target))
    elif kind == "cast":
        # cast:SPELL or cast:SPELL:ENTRY (at the nearest creature of ENTRY)
        spell = int(args[0])
        if len(args) > 1:
            entry = int(args[1])
            found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
            if not found:
                print(f"cast {spell}: no {entry} in sight"); continue
            target = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
            wsend(0x12E, struct.pack("<IH", spell, 2) + packed(target)); print(f"cast {spell} at {target & 0xFFFFFF}")
        else:
            wsend(0x12E, struct.pack("<IH", spell, 0)); print(f"cast {spell}")
    elif kind in ("ahello", "ahsell", "ahlist", "ahbid"):
        # ahello:NPC, ahsell:NPC:ITEM:BID:BUYOUT:HOURS (the first of ITEM in the bags), ahlist:NPC[:NAME],
        # ahbid:NPC:AUCTION:PRICE, at the nearest creature of entry NPC.
        entry = int(args[0])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
        if not found:
            print(f"{kind}: no {entry} in sight"); continue
        npc = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        if kind == "ahello":
            wsend(0x255, struct.pack("<Q", npc)); op, p = expect(0x255)
            print(f"auction house {struct.unpack_from('<I', p, 8)[0]}")
        elif kind == "ahsell":
            item_entry, bid, buyout, hours = map(int, args[1:5])
            guids = [g for g, o in items.items() if o[3][3] == item_entry]
            if not guids:
                print(f"ahsell: no {item_entry} in the bags"); continue
            wsend(0x256, struct.pack("<QQIII", npc, guids[0], bid, buyout, hours * 60))
            op, p = expect(0x25B); aid, action, err = struct.unpack_from("<III", p, 0)
            print(f"auction {aid}: action {action} error {err}")
        elif kind == "ahlist":
            name = args[1] if len(args) > 1 else ""
            wsend(0x258, struct.pack("<QI", npc, 0) + name.encode() + b"\0" + struct.pack("<BBIIIIB", 0, 0, *([0xFFFFFFFF] * 4), 0))
            op, p = expect(0x25C); n = struct.unpack_from("<I", p, 0)[0]
            for i in range(n):
                aid, item, _, _, _, count, _, owner, start, outbid, buyout, left, bidder, bid = struct.unpack_from("<IIIiIIIQIIIIQI", p, 4 + i * 64)
                print(f"  auction {aid}: item {item} x{count} from {owner}, start {start}, bid {bid}, buyout {buyout}, {left // 60000} min left")
            print(f"  {n} of {struct.unpack_from('<I', p, 4 + n * 64)[0]}")
        else:
            aid, price = int(args[1]), int(args[2])
            wsend(0x25A, struct.pack("<QII", npc, aid, price))
            op, p = expect(0x25B); aid, action, err = struct.unpack_from("<III", p, 0)
            print(f"bid on {aid}: action {action} error {err}"); listen_for(1)
    elif kind in ("taxi", "fly"):
        # taxi:NPC (learn its node or show the known ones), fly:NPC:FROM:TO, at the nearest creature of NPC.
        entry = int(args[0])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
        if not found:
            print(f"{kind}: no {entry} in sight"); continue
        npc = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        if kind == "taxi":
            wsend(0x1AC, struct.pack("<Q", npc)); print(f"taxi nodes of {entry}")
        else:
            wsend(0x1AD, struct.pack("<QII", npc, int(args[1]), int(args[2]))); print(f"fly {args[1]} -> {args[2]}")
        listen_for(1.5)
    elif kind in ("bgjoin", "bgport", "bgleave", "bgstatus", "pvplog"):
        # bgjoin:NPC:MAP (talk to the nearest battlemaster of entry NPC, then queue for MAP), bgport:MAP:1
        # (accept the invitation; 0 leaves the queue), bgleave:MAP, bgstatus, pvplog (the scoreboard).
        if kind == "bgjoin":
            entry, mapid = int(args[0]), int(args[1])
            found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry and g in seen_positions]
            if not found:
                print(f"bgjoin: no {entry} in sight"); continue
            npc = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
            wsend(0x2D7, struct.pack("<Q", npc)); listen_for(1)
            wsend(0x2EE, struct.pack("<QIIB", npc, mapid, 0, 0)); print(f"queue for map {mapid}")
        elif kind == "bgport":
            wsend(0x2D5, struct.pack("<IB", int(args[0]), int(args[1]))); print(f"battlefield port {args[0]} {args[1]}")
        elif kind == "bgleave":
            wsend(0x2E1, struct.pack("<I", int(args[0]))); print(f"leave battlefield {args[0]}")
        elif kind == "bgstatus":
            wsend(0x2D3, b""); print("battlefield status")
        else:
            wsend(0x2E0, b""); print("scoreboard")
        listen_for(2)
    elif kind in ("castgo", "usego"):
        # castgo:SPELL:ENTRY or usego:ENTRY: walk next to the nearest game object of ENTRY, then cast at it
        # (a lock opened: its loot taken) or use it (CMSG_GAMEOBJ_USE).
        import math
        entry = int(args[-1])
        found = [g for g, (t, e) in seen_objects.items() if t == 5 and e == entry and g in seen_positions]
        if not found:
            print(f"{kind}: no {entry} in sight"); continue
        target = min(found, key=lambda g: (seen_positions[g][0] - here[0]) ** 2 + (seen_positions[g][1] - here[1]) ** 2)
        cx, cy, cz = seen_positions[target]
        angle = math.atan2(here[1] - cy, here[0] - cx)
        x, y = cx + 1.5 * math.cos(angle), cy + 1.5 * math.sin(angle)
        movement(0x0B5, x, y, cz, flags=1); movement(0x0B7, x, y, cz); here[:] = [x, y, cz]
        if kind == "usego":
            wsend(0x0B1, struct.pack("<Q", target)); print(f"use {entry} ({target & 0xFFFFFF})"); listen_for(1.5)
            continue
        wsend(0x12E, struct.pack("<IH", int(args[0]), 0x800) + packed(target)); print(f"cast {args[0]} at {entry} ({target & 0xFFFFFF})")
        op, p = expect(0x160)
        if len(p) <= 10:
            print(f"  loot error {p[9]}"); continue
        gold, n = struct.unpack_from("<IB", p, 9)
        slots = []
        for i in range(n):
            slot, item, count = struct.unpack_from("<BII", p, 14 + i * 22); slots.append(slot)
            print(f"  loot slot {slot}: item {item} x{count}")
        for slot in slots:
            wsend(0x108, bytes([slot]))
        listen_for(1.0)
        wsend(0x15F, struct.pack("<Q", target)); print("  released"); listen_for(1.5)
    elif kind in ("castplayer", "attackplayer"):
        # castplayer:SPELL or attackplayer: at the nearest other player in sight
        players = [g for g, (t, e) in seen_objects.items() if t == 4 and g != my_guid[0]]
        if not players:
            print(f"{kind}: no player in sight"); continue
        target = players[0]
        if kind == "castplayer":
            wsend(0x12E, struct.pack("<IH", int(args[0]), 2) + packed(target)); print(f"cast {args[0]} at player {target & 0xFFFFFF}")
        else:
            wsend(0x141, struct.pack("<Q", target)); print(f"attack player {target & 0xFFFFFF}")
    elif kind == "duelaccept":
        wsend(0x16C, struct.pack("<Q", duel_flag[0])); print("accept the duel")
    elif kind in ("queststatus", "questhello", "questaccept", "questcomplete", "questreward"):
        # questX:ENTRY[:QUEST[:CHOICE]] at the nearest creature of ENTRY (walk there first: approach)
        entry = int(args[0])
        found = [g for g, (t, e) in seen_objects.items() if t == 3 and e == entry]
        if not found:
            print(f"{kind}: no {entry} in sight"); continue
        g = found[0]
        if kind == "queststatus":
            wsend(0x182, struct.pack("<Q", g)); op, p = expect(0x183); print(f"quest status of {entry}: {struct.unpack_from('<I', p, 8)[0]}")
        elif kind == "questhello":
            wsend(0x184, struct.pack("<Q", g)); print(f"hello {entry}")
        elif kind == "questaccept":
            wsend(0x189, struct.pack("<QI", g, int(args[1]))); print(f"accept quest {args[1]}")
        elif kind == "questcomplete":
            wsend(0x18A, struct.pack("<QI", g, int(args[1]))); print(f"complete quest {args[1]}")
        else:
            wsend(0x18E, struct.pack("<QII", g, int(args[1]), int(args[2]) if len(args) > 2 else 0)); print(f"reward quest {args[1]}")
    elif kind in ("sendmail", "maillist"):
        # sendmail:NAME:SUBJECT:BODY:COPPER or maillist, at the nearest mailbox (game object 142075)
        boxes = [g for g, (t, e) in seen_objects.items() if t == 5 and e == 142075]
        if not boxes:
            print(f"{kind}: no mailbox in sight"); continue
        box = boxes[0]
        if kind == "sendmail":
            name, subject, body, copper = args[0], args[1], args[2], int(args[3])
            wsend(0x238, struct.pack("<Q", box) + name.encode() + b"\0" + subject.encode() + b"\0" + body.encode() + b"\0"
                  + struct.pack("<IIQIIQB", 41, 0, 0, copper, 0, 0, 0))
            op, p = expect(0x239); print(f"mail sent: result {struct.unpack_from('<III', p, 0)}")
        else:
            wsend(0x23A, struct.pack("<Q", box)); op, p = expect(0x23B)
            n = p[0]; pos = 1; mails = []
            for i in range(n):
                mid, mtype = struct.unpack_from("<IB", p, pos); pos += 5 + 8
                end = p.index(b"\0", pos); subject = p[pos:end].decode(); pos = end + 1
                textid = struct.unpack_from("<I", p, pos)[0]; pos += 12 + 16 + 1 + 12
                money = struct.unpack_from("<I", p, pos)[0]; pos += 12 + 4 + 4
                mails.append((mid, subject, textid, money))
            print(f"mail list: {mails}")
    elif kind == "learntalent":
        wsend(0x251, struct.pack("<II", int(args[0]), int(args[1]))); print(f"learn talent {args[0]} rank {int(args[1]) + 1}")
    elif kind == "useitem":
        # useitem:BAG:SLOT
        bag, slot = int(args[0]), int(args[1])
        wsend(0x0AB, struct.pack("<BBBH", bag, slot, 1, 0)); print(f"use item in {bag}/{slot}")
    elif kind == "release":
        wsend(0x15A, b""); print("release spirit")
    elif kind == "corpse":
        wsend(0x216, b""); op, p = expect(0x216)
        if p[0]:
            m, x, y, z, cm = struct.unpack_from("<i3fI", p, 1); print(f"corpse: map {m} at {x:.1f} {y:.1f} {z:.1f}")
            corpse_at[:] = [x, y, z]
        else:
            print("corpse: none")
    elif kind == "tocorpse":
        # Run there at a ghost's speed (8.75 yards a second): a heartbeat a second, then stop.
        import math
        x, y, z = corpse_at; sx, sy, sz = here
        steps = max(1, math.ceil(math.dist((sx, sy), (x, y)) / 8.0))
        movement(0x0B5, sx, sy, sz, flags=1)
        for i in range(1, steps + 1):
            time.sleep(1.0)
            f = i / steps
            movement(0x0EE, sx + (x - sx) * f, sy + (y - sy) * f, sz + (z - sz) * f, flags=1)
        movement(0x0B7, x, y, z); here[:] = [x, y, z]
        print(f"to the corpse at {x:.1f} {y:.1f} in {steps} s")
    elif kind == "reclaim":
        wsend(0x1D2, struct.pack("<Q", 0)); print("reclaim corpse")
    elif kind == "spirithealer":
        wsend(0x21C, struct.pack("<Q", npc)); print("spirit healer")
    elif kind == "stopattack":
        wsend(0x142, b""); print("stop attacking")
    elif kind == "move":
        x, y, z = map(float, args); movement(0x0B5, x, y, z, flags=1); movement(0x0EE, x, y, z, flags=1); movement(0x0B7, x, y, z)
        here[:] = [x, y, z]
        print(f"moved to {x} {y} {z}")
    elif kind == "gchat":
        wsend(0x095, struct.pack("<II", 3, 7) + args[0].encode() + b"\0"); print(f"guild chat '{args[0]}'"); listen_for(1)
    elif kind == "say":
        wsend(0x095, struct.pack("<II", 0, 7) + args[0].encode() + b"\0"); op, p = expect(0x096)
        n = struct.unpack_from("<I", p, 21)[0]; print(f"heard: '{p[25:25 + n - 1].decode()}'")
    elif kind == "yell":
        wsend(0x095, struct.pack("<II", 5, 7) + args[0].encode() + b"\0"); op, p = expect(0x096)
        n = struct.unpack_from("<I", p, 21)[0]; print(f"heard: '{p[25:25 + n - 1].decode()}'")
    elif kind == "sit":
        wsend(0x101, struct.pack("<I", 1)); got = [expect(0x1F6)]
        objs = parse_update(*got[0]); print("sat down; update fields changed:", sorted(objs[0][3])); expect(0x29D)
    elif kind == "whisper":
        wsend(0x095, struct.pack("<II", 6, 7) + args[0].encode() + b"\0" + args[1].encode() + b"\0")
        op, p = wrecv(); describe(op, p)
    elif kind in ("gcreate", "gmotd", "ginvite"):
        wsend({"gcreate": 0x081, "gmotd": 0x091, "ginvite": 0x082}[kind], args[0].encode() + b"\0"); print(f"{kind} {args[0]}"); listen_for(1)
    elif kind in ("ginfo", "groster", "gleave", "gdisband"):
        wsend({"ginfo": 0x087, "groster": 0x089, "gleave": 0x08D, "gdisband": 0x08F}[kind], b""); print(kind); listen_for(1)
    elif kind == "gquery":
        wsend(0x054, struct.pack("<I", int(args[0]))); print(f"gquery {args[0]}"); listen_for(1)
    elif kind in ("addfriend", "addignore"):
        wsend(0x069 if kind == "addfriend" else 0x06C, args[0].encode() + b"\0"); print(f"{kind} {args[0]}"); listen_for(1)
    elif kind == "friends":
        wsend(0x066, b""); print("friends"); listen_for(1)
    elif kind == "who":
        strings = [args[0]] if args and args[0] else []
        body = struct.pack("<II", 0, 100) + b"\0\0" + struct.pack("<III", 0xFFFFFFFF, 0xFFFFFFFF, 0)
        body += struct.pack("<I", len(strings)) + b"".join(x.encode() + b"\0" for x in strings)
        wsend(0x062, body); op, p = expect(0x063)
        shown, matches = struct.unpack_from("<II", p, 0); pos = 8
        print(f"who: {shown} shown, {matches} matching")
        for _ in range(shown):
            e = p.index(b"\0", pos); name = p[pos:e].decode(); pos = e + 1
            e = p.index(b"\0", pos); pos = e + 1
            level, cls, race, zone = struct.unpack_from("<IIII", p, pos); pos += 16
            print(f"  {name}: level {level} class {cls} race {race} zone {zone}")
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
    elif kind == "pet":
        # pet:attack|follow|stay|dismiss|passive|defensive|aggressive (attack: the selected target)
        commands = {"stay": (0, 7), "follow": (1, 7), "attack": (2, 7), "dismiss": (3, 7), "passive": (0, 6),
                    "defensive": (1, 6), "aggressive": (2, 6)}
        action, kind_ = commands[args[0]]
        target = pet_info.get("target", 0) if args[0] == "attack" else 0
        wsend(0x175, struct.pack("<QIQ", pet_info.get("guid", 0), action | kind_ << 24, target)); print(f"pet {args[0]}")
        listen_for(1)
    elif kind == "petabandon":
        wsend(0x176, struct.pack("<Q", pet_info.get("guid", 0))); print("petabandon"); listen_for(1)
    elif kind == "petname":
        wsend(0x052, struct.pack("<IQ", int(args[0]), pet_info.get("guid", 0))); print("petname"); listen_for(1)
    elif kind == "petrename":
        wsend(0x177, struct.pack("<Q", pet_info.get("guid", 0)) + args[0].encode() + b"\0"); print(f"petrename {args[0]}")
        listen_for(1)
    elif kind in ("stablelist", "stablepet", "buystableslot", "unstable"):
        entry = int(args[0])
        npc = next((g for g, (t, e) in seen_objects.items() if t == 3 and e == entry), None)
        if npc is None:
            print(f"{kind}: no {entry} in sight"); continue
        op = {"stablelist": 0x26F, "stablepet": 0x270, "buystableslot": 0x272, "unstable": 0x271}[kind]
        body = struct.pack("<Q", npc) + (struct.pack("<I", int(args[1])) if kind == "unstable" else b"")
        wsend(op, body); print(kind); listen_for(1)
    elif kind == "npc":
        entry = int(args[0])
        npc = next((g for g, (t, e) in seen_objects.items() if t == 3 and e == entry), None)
        print(f"npc {entry}: " + (str(npc) if npc else "not in sight"))
    elif kind in ("gossip", "trainer", "vendor", "binder", "bank"):
        print(kind); wsend({"gossip": 0x17B, "trainer": 0x1B0, "vendor": 0x19E, "binder": 0x1B5, "bank": 0x1B7}[kind],
                           struct.pack("<Q", npc)); listen_for(1)
    elif kind == "select":
        print(f"select {args[0]}"); wsend(0x17C, struct.pack("<QI", npc, int(args[0]))); listen_for(1)
    elif kind == "text":
        print(f"text {args[0]}"); wsend(0x17F, struct.pack("<IQ", int(args[0]), npc)); listen_for(1)
    elif kind == "buyspell":
        print(f"buy spell {args[0]}"); wsend(0x1B2, struct.pack("<QI", npc, int(args[0]))); listen_for(1)
    elif kind in ("buy", "sell", "buyback", "repair", "buybankslot", "equip", "swap", "split", "destroy", "tobank", "frombank"):
        n = [int(a) for a in args]
        print(action)
        if kind == "buy": wsend(0x1A2, struct.pack("<QIBB", npc, n[0], n[1] if len(n) > 1 else 1, 1))
        elif kind == "sell": wsend(0x1A0, struct.pack("<QQB", npc, my_slots[n[0]], 0))
        elif kind == "buyback": wsend(0x290, struct.pack("<QI", npc, 69 + n[0]))
        elif kind == "repair": wsend(0x2A8, struct.pack("<QQ", npc, 0))
        elif kind == "buybankslot": wsend(0x1B9, struct.pack("<Q", npc))
        elif kind == "equip": wsend(0x10A, struct.pack("<BB", 255, n[0]))
        elif kind == "swap": wsend(0x10D, struct.pack("<BB", n[0], n[1]))
        elif kind == "split": wsend(0x10E, struct.pack("<5B", 255, n[0], 255, n[1], n[2]))
        elif kind == "destroy": wsend(0x111, struct.pack("<6B", 255, n[0], n[1] if len(n) > 1 else 0, 0, 0, 0))
        elif kind == "tobank": wsend(0x283, struct.pack("<BB", 255, n[0]))
        elif kind == "frombank": wsend(0x282, struct.pack("<BB", 255, n[0]))
        listen_for(1)
    elif kind == "inv":
        for slot in sorted(my_slots):
            v = item_objects[my_slots[slot]]
            line = f"  slot {slot}: {v[3]} x{v.get(OBJECT_END + 8)}"
            if ITEM_END in v:  # a bag: its slots
                inside = [v.get(ITEM_END + 2 + 2 * i, 0) | v.get(ITEM_END + 3 + 2 * i, 0) << 32 for i in range(v[ITEM_END])]
                line += f", holding {[item_objects[g][3] for g in inside if g]}"
            print(line)
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
