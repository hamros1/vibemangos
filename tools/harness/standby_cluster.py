"""A single-standby cluster behind the loopback proxy, for the takeover scenarios (docs/CLUSTER.md).

Node 1 coordinates, node 2 is its standby (`cluster.standby`, no quorum), node 3 is a worker and node 4 is
either a gateway or a second worker. Every cluster link goes through `ClusterProxy`, so a scenario can hold
or drop the frames of one direction.
"""

import json
import os
import re
import subprocess
import sys
import time

from cluster_fixture import AUTH, REPO, wait_for


COORDINATOR, STANDBY, WORKER, FOURTH = 1, 2, 3, 4
NODES = (COORDINATOR, STANDBY, WORKER, FOURTH)
METRICS = re.compile(r"cluster: node \d+( \(coordinator\))?, view .*; owns (\d+) region\(s\), lease (holds|LAPSED)")
TAKEOVER = "the standby, takes over"


class StandbyCluster:
    def __init__(self, fixture, proxy, world_ports, auth_port, name, *, gateway, account, password):
        self.fixture, self.proxy, self.world_ports, self.auth_port = fixture, proxy, world_ports, auth_port
        self.account, self.password = account, password
        self.login = fixture.fresh_schema("login", "classicrealmd.sql")
        self.chars = fixture.fresh_schema("chars", "classiccharacters.sql")
        base = dict(fixture.base, bind_address="127.0.0.1", realm_id=1, idle_timeout=180,
                    metrics_interval_seconds=1, login_database=self.login, character_database=self.chars)
        coordinator = f"{proxy.ADDRESS}:{proxy.ports[COORDINATOR]}"
        self.processes = {}
        for node in NODES:
            label = f"node{node}"
            config = dict(base, port=world_ports[node], write_log=f"{label}.writes")
            config["cluster"] = dict(name=name, node_id=node, coordinator=coordinator, standby=node == STANDBY,
                                     gateway=gateway and node == FOURTH, listen_address=proxy.DESTINATION,
                                     advertise_address=proxy.ADDRESS, listen_port=proxy.ports[node],
                                     balance_interval_seconds=300)
            self.processes[node] = fixture.start_world(label, config)
        wait_for("every node's lease", lambda: all(self.lease(self.log(node)) == "holds" for node in NODES), 65)

        auth = fixture.directory / "auth.json"
        auth.write_text(json.dumps(dict(login_database=self.login, mysql_library=base["mysql_library"],
                                       bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
        subprocess.run([AUTH, "-c", auth, "account", "create", account, password], cwd=fixture.directory,
                       check=True, timeout=15, stdout=subprocess.DEVNULL)
        fixture.grant_admins(self.login)
        fixture.start("auth", [AUTH, "-c", auth])
        wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 15)

    def log(self, node, alive=None):
        """Node `node`'s log; with `alive`, fails if one of those nodes exited."""
        for other in alive or ():
            if self.processes[other].poll() is not None:
                raise RuntimeError(f"node {other} exited:\n{self.fixture.log(f'node{other}')[-2500:]}")
        return self.fixture.log(f"node{node}")

    @staticmethod
    def lease(log):
        matches = METRICS.findall(log)
        return matches[-1][2] if matches else ""

    def client(self, label, node, *actions):
        env = dict(os.environ, WORLD=f"127.0.0.1:{self.world_ports[node]}", DMANGOS_TEST_WAITFILE_SECONDS="90",
                   DMANGOS_TEST_ENUM_SECONDS="20")  # a login just after the takeover waits one lease
        env.pop("REALM", None)
        return self.fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(self.auth_port),
                                          self.account, self.password, *actions], env=env)

    def create(self, name, node):
        # A node refuses a creation until the coordinator has given it a block of character ids.
        for attempt in range(10):
            label = f"create{attempt}"
            if not self.client(label, node, "enum", f"create:{name}:1:1", "drop").wait(timeout=25) \
                    and "(success)" in self.fixture.log(label):
                break
            time.sleep(1)
        else:
            raise RuntimeError(self.fixture.log(label))
        wait_for("the new character to be durable",
                 lambda: self.fixture.query(f"SELECT guid FROM characters WHERE name='{name}'", self.chars), 10)
