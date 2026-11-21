#!/usr/bin/env python3
"""Derive the second node of the default local cluster from its coordinator config."""

import argparse
import json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("coordinator", type=argparse.FileType(encoding="utf-8"))
    args = parser.parse_args()

    config = json.load(args.coordinator)
    cluster = config["cluster"]
    if cluster["node_id"] != 1 or cluster.get("voters") or cluster.get("gateway") or cluster.get("standby"):
        parser.error("expected the default fixed coordinator configuration for node 1")

    config["port"] += 1
    cluster["node_id"] = 2
    cluster["listen_port"] += 1
    if cluster.get("client_address"):
        host, port = cluster["client_address"].rsplit(":", 1)
        cluster["client_address"] = f"{host}:{int(port) + 1}"
    # Each node needs its own write-ahead log. Node 2 defaults to writes-2.log.
    config.pop("write_log", None)
    print(json.dumps(config, indent=4))


if __name__ == "__main__":
    main()
