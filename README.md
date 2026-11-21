# dmangos

A World of Warcraft 1.12.x server written in D. It supports client builds 5875 (1.12.1),
6005 (1.12.2) and 6141 (1.12.3). The default setup runs two world server nodes that share
one realm and its databases.

**Installing dmangos?** The [setup guide](docs/SETUP.md) takes you from a fresh checkout to
your first login. Download the world database from [CMaNGOS Classic-DB on GitHub](https://github.com/cmangos/classic-db)
and extract the client data from your own 1.12.x client.

## Using the server

| I want to… | Where to look |
|---|---|
| Install, start, or fix a local server | [Setup](docs/SETUP.md) |
| Change a setting or manage accounts | [Configuration](docs/CONFIGURATION.md) |
| Run in-game admin commands | [GM commands](docs/COMMANDS.md) |
| Use a gateway, configure failover, or run nodes on separate hosts | [Clustering](docs/CLUSTER.md) |
| Check features, known gaps, and upcoming work | [Gameplay](docs/GAMEPLAY.md) · [Roadmap](docs/ROADMAP.md) |
| See extraction modes and file formats | [Client data](docs/CLIENT-DATA.md) |

## Developing dmangos

| Topic | Where to look |
|---|---|
| Build for development and run tests | [Developer guide](docs/DEVELOPING.md) |
| Follow a packet or find the relevant code | [Architecture](docs/ARCHITECTURE.md) · [Source layout](docs/SOURCE-LAYOUT.md) |
| Understand design and D conventions | [Design](docs/DESIGN.md) · [D conventions](docs/DLANG.md) |
| Work on cluster services or gameplay scripts | [Cluster services](docs/SERVICES.md) · [Scripting](docs/SCRIPTING.md) |
| Diagnose spell support or game rules | [Spell coverage](docs/SPELLS.md) · [Formulas](docs/FORMULAS.md) · [Rules audit](docs/RULES-AUDIT.md) |
| Run or compare load tests | [Benchmarks](docs/BENCHMARKS.md) |

The code is licensed under [AGPL-3.0-or-later](LICENSE). See [Notices](NOTICE.md) for third-party
licenses and [Provenance](PROVENANCE.md) for the sources used by each module.
