"""Processes and isolated character databases for local cluster tests."""

import json
import os
from pathlib import Path
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
AUTH = Path(os.environ.get("AUTHSERVER", REPO / "bin/authserver")).resolve()
LOADGEN = Path(os.environ.get("LOADGEN", REPO / "bin/loadgen")).resolve()


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


class ClusterFixture:
    def __init__(self, name):
        self.base = json.loads((HARNESS / "world.json").read_text())
        subprocess.run([HERE / "db.sh", "start"], check=True)
        self.directory = Path(tempfile.mkdtemp(prefix=name + "-", dir=HARNESS))
        print(f"{name} logs in {self.directory}", flush=True)
        self.processes = []
        self.schemas = []
        self.socket = HARNESS / "run/mysql.sock"
        self.mysql = [str(MARIADB), "--no-defaults", "-S", str(self.socket), "-u", "root"]
        self.mysql_env = dict(os.environ, LD_LIBRARY_PATH=str(Path(self.base["mysql_library"]).parent))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
        for process in self.processes:
            try:
                process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for name in self.schemas:
            self.query(f"DROP DATABASE `{name}`")

    def query(self, sql, database=None):
        args = [*self.mysql, "-NB"]
        if database is not None:
            args.append(database.rsplit(";", 1)[-1])
        return subprocess.run([*args, "-e", sql], env=self.mysql_env, check=True,
                              stdout=subprocess.PIPE, text=True).stdout.strip()

    def fresh_schema(self, label, template):
        name = self.directory.name.replace("-", "_") + "_" + label
        self.query(f"CREATE DATABASE `{name}`")
        self.schemas.append(name)
        with (REPO / "sql" / template).open("rb") as source:
            subprocess.run([*self.mysql, name], stdin=source, env=self.mysql_env, check=True)
        return f".;{self.socket};mangos;harness;{name}"

    def start(self, name, args):
        with (self.directory / (name + ".log")).open("wb") as log:
            process = subprocess.Popen(args, cwd=self.directory, stdout=log, stderr=subprocess.STDOUT)
        self.processes.append(process)
        return process

    def start_world(self, name, config):
        path = self.directory / (name + ".json")
        path.write_text(json.dumps(config, indent=2))
        return self.start(name, [WORLD, "-c", path])

    def start_clients(self, name, config, port, *options):
        return self.start(name, [LOADGEN, "--world", f"127.0.0.1:{port}",
                                 "--login-db", config["login_database"], "--character-db", config["character_database"],
                                 "--world-db", config["world_database"], "--mysql-library", config["mysql_library"],
                                 *options])

    def log(self, name):
        return (self.directory / (name + ".log")).read_text(errors="replace")

    def wait_for_clients(self, name, process):
        def entered():
            if process.poll() is not None:
                raise RuntimeError(f"{name} exited before the clients entered the world")
            return "measuring for" in self.log(name)

        wait_for(f"the clients in {name} to enter the world", entered, 45)


def run_test(name, test):
    def stop_on_term(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_on_term)
    try:
        with ClusterFixture(name) as fixture:
            test(fixture)
    except KeyboardInterrupt:
        raise SystemExit(f"{name} test interrupted")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f"{name} test failed: {error}")
