#!/usr/bin/env python3
"""Kill the elected coordinator in a three-voter cluster with clients on a gateway.

Run after tools/harness/setup.sh and a release build. The test imports fresh login
and character schemas in the harness's MariaDB and reuses its world data. It leaves
logs and vote files under the harness directory and deletes the two test schemas.
"""

import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HARNESS = Path(os.environ.get("DMANGOS_HARNESS", Path.home() / ".cache/dmangos-harness")).resolve()
MARIADB = Path(os.environ.get("MARIADB_ROOT", Path.home() / "dmangos-server/mariadb")) / "usr/bin/mariadb"
WORLD = Path(os.environ.get("WORLDSERVER", REPO / "bin/worldserver")).resolve()
LOADGEN = Path(os.environ.get("LOADGEN", REPO / "bin/loadgen")).resolve()
VOTERS = (1, 2, 3)
GATEWAY = 4
BOTS = 8
ELECTION = re.compile(r"cluster: node (\d+) elected coordinator for term (\d+)")
WORLD_PACKET = re.compile(r"^(\S+) < (SMSG_NEW_WORLD|SMSG_INITIAL_SPELLS) ", re.MULTILINE)


def available_ports(count):
    sockets = []
    try:
        for _ in range(count):
            reserve = socket.socket()
            sockets.append(reserve)
            reserve.bind(("127.0.0.1", 0))
        return [reserve.getsockname()[1] for reserve in sockets]
    finally:
        for reserve in sockets:
            reserve.close()


def wait_for(description, check, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.25)
    raise RuntimeError(f"timed out waiting for {description}")


def run():
    base = json.loads((HARNESS / "world.json").read_text())
    subprocess.run([HERE / "db.sh", "start"], check=True)
    run_dir = Path(tempfile.mkdtemp(prefix="quorum-", dir=HARNESS))
    print(f"quorum logs in {run_dir}", flush=True)
    database_prefix = run_dir.name.replace("-", "_")
    processes = []
    schemas = []
    mysql = [str(MARIADB), "--no-defaults", "-S", str(HARNESS / "run/mysql.sock"), "-u", "root"]
    mysql_env = dict(os.environ, LD_LIBRARY_PATH=str(Path(base["mysql_library"]).parent))

    def query(sql):
        subprocess.run([*mysql, "-e", sql], env=mysql_env, check=True)

    def fresh_schema(name, template):
        query(f"CREATE DATABASE `{name}`")
        schemas.append(name)
        with (REPO / "sql" / template).open("rb") as source:
            subprocess.run([*mysql, name], stdin=source, env=mysql_env, check=True)
        return f".;{HARNESS / 'run/mysql.sock'};mangos;harness;{name}"

    def start(name, args):
        with (run_dir / (name + ".log")).open("wb") as log:
            process = subprocess.Popen(args, cwd=run_dir, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    def log(name):
        return (run_dir / (name + ".log")).read_text(errors="replace")

    def leader_after(term, nodes):
        elected = [
            (int(found_term), int(node))
            for node_id, process in nodes.items() if node_id in VOTERS and process.poll() is None
            for node, found_term in ELECTION.findall(log(f"node{node_id}")) if int(found_term) > term
        ]
        return max(elected, default=None)

    try:
        base["login_database"] = fresh_schema(f"{database_prefix}_login", "classicrealmd.sql")
        base["character_database"] = fresh_schema(f"{database_prefix}_chars", "classiccharacters.sql")
        base["bind_address"] = "127.0.0.1"
        base["realm_id"] = 1
        ports = available_ports(8)
        voters = [{"node_id": node, "address": f"127.0.0.1:{ports[node + 3]}"} for node in VOTERS]
        nodes = {}
        for node in (*VOTERS, GATEWAY):
            name = f"node{node}"
            path = run_dir / (name + ".json")
            config = dict(base, port=ports[node - 1], write_log=name + ".writes", metrics_interval_seconds=1)
            config["cluster"] = {
                "name": "quorum-harness", "node_id": node, "gateway": node == GATEWAY,
                "listen_address": "127.0.0.1", "listen_port": ports[node + 3], "voters": voters,
            }
            if node in VOTERS:
                config["cluster"]["vote_file"] = f"{name}.vote"
            path.write_text(json.dumps(config, indent=2))
            nodes[node] = start(name, [WORLD, "-c", path])

        term, leader = wait_for("an elected coordinator", lambda: leader_after(0, nodes), 45)
        wait_for("the gateway to follow the coordinator",
                 lambda: f"node {leader} leads quorum term {term}" in log(f"node{GATEWAY}"), 20)
        # An election is followed by issuing the first ownership grants and worker leases.
        wait_for("the gateway's lease and the initial regions",
                 lambda: "lease holds" in log(f"node{GATEWAY}") and any(
                     re.search(r"owns [1-9]\d* region\(s\), lease holds", log(f"node{node}")) for node in VOTERS), 20)
        bots = start("loadgen", [LOADGEN, "--world", f"127.0.0.1:{ports[GATEWAY - 1]}",
                                "--login-db", base["login_database"], "--character-db", base["character_database"],
                                "--world-db", base["world_database"], "--mysql-library", base["mysql_library"],
                                "--bots", str(BOTS), "--scenario", "crowd", "--duration", "45", "--warmup", "2",
                                "--trace"])

        def clients_entered():
            if bots.poll() is not None:
                raise RuntimeError("loadgen exited before the clients entered the world")
            return "measuring for" in log("loadgen")

        wait_for("all clients to enter the world", clients_entered, 45)
        trace_start = (run_dir / "loadgen.log").stat().st_size

        # This is an ungraceful failure of a process created above, with every client still connected.
        nodes[leader].kill()
        nodes[leader].wait(timeout=10)
        next_term, successor = wait_for("a successor in a higher term", lambda: leader_after(term, nodes), 30)
        wait_for("the gateway to follow the successor",
                 lambda: f"node {successor} leads quorum term {next_term}" in log(f"node{GATEWAY}"), 15)
        print(f"coordinator {leader} in term {term} was replaced by {successor} in term {next_term}", flush=True)

        if bots.wait(timeout=50) or f"bots in the world at the end: {BOTS}; failed: 0" not in log("loadgen"):
            raise RuntimeError("a gateway client did not stay in the world after the election")
        with (run_dir / "loadgen.log").open("rb") as trace:
            trace.seek(trace_start)
            transfers, recovered = set(), set()
            for account, opcode in WORLD_PACKET.findall(trace.read().decode(errors="replace")):
                if opcode == "SMSG_NEW_WORLD":
                    transfers.add(account)
                elif account in transfers:
                    recovered.add(account)
        if len(recovered) != BOTS:
            raise RuntimeError(f"only {len(recovered)}/{BOTS} gateway clients acknowledged their replacement world")
        if any(process.poll() is not None for node, process in nodes.items() if node != leader):
            raise RuntimeError("a surviving node exited during the test")
        print(f"PASS: all {BOTS} gateway clients stayed connected and recovered on the surviving nodes", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for name in schemas:
            query(f"DROP DATABASE `{name}`")


if __name__ == "__main__":
    def stop_on_term(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_on_term)
    try:
        run()
    except KeyboardInterrupt:
        raise SystemExit("quorum test interrupted")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f"quorum test failed: {error}")
