# The client protocol seam

dmangos serves the 1.12.1 client (build 5875). Later client versions (2.4.3, 3.3.5) are meant to be added beside it
in this one codebase, not in a fork: the engine, the cluster, the scripting and the harness are the same for all of
them. What differs by client version is kept behind a seam. This document says where the seam is and the rules
that keep it. Nothing but 1.12 is implemented yet.

## What differs by client version

- **Packets:** opcode numbers, packet layouts, the movement block, the auth handshake.
- **Update fields:** each field's slot and size (`updatefields.d`, generated per build). Game code already reaches
  fields by name only (`get!UNIT_FIELD_HEALTH`), so a second build is a second table.
- **Client data:** the DBC formats (`clientdata.d`'s format strings).
- **World database schema:** CMaNGOS-classic's columns; tbc and wotlk differ.
- **Rules:** what changed between patches (docs/FORMULAS.md and RULES-AUDIT.md say which patch each source covers).
- **Content:** the scripts of each expansion's places, as modules on the one script API (docs/SCRIPTING.md).

## The packet rule

Game code says *what* to tell a client; the protocol package says *how*, in bytes.

- A server packet is built by a function of `dmangos.protocol` that takes game values and returns a `Packet`: its
  opcode and its body together. Game code hands the `Packet` to a sink (`deliver`, `sendToObservers`, ...).
- Game code does not name server opcodes and does not write packet bytes (`ByteWriter`) itself.
- A client packet is read by a parser of `dmangos.protocol` into a typed request; handlers take the request.

So a second client version is a second implementation of the protocol package's functions, with the same
signatures. How a realm picks its client version is decided when the second version is added.

## Migration

The packets move group by group (chat, combat log, spells, movement, loot, quests, ...), each group one verified
commit that changes no bytes: the tests and chaos scenarios, which read the 1.12 bytes, prove it. A group is done
when no game module names its opcodes. Once all are done, `check.sh` enforces the rule (as it enforces that no
engine module imports a script module).

Done so far: chat (`dmangos.protocol.chat`).
