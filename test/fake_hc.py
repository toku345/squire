#!/usr/bin/env python3
"""Test double: no real core, terminal, network, or user state is accessed."""
import json
import os
import sys
import time
from pathlib import Path

state_path = Path(os.environ["SQUIRE_HC_STATE"])


def record(value):
    with open(os.environ["SQUIRE_HC_LOG"], "a") as log:
        log.write(json.dumps(value) + "\n")


def state():
    return json.loads(state_path.read_text())


def main():
    args = sys.argv[1:]
    record(args)
    if args == ["connect"]:
        mode = os.environ.get("SQUIRE_HC_BEHAVIOR", "")
        if mode == "hang":
            time.sleep(30)
            return
        if mode == "fail":
            print("offline fixture", file=sys.stderr)
            sys.exit(1)
        for line in sys.stdin:
            req = json.loads(line)
            record(req)
            if req["method"] == "hello":
                result = {"generation": 2 if mode == "generation" else 1,
                          "core": {"id": "local-core"}, "methods": ["terminal.list"]}
            elif req["method"] == "terminal.list":
                result = state()
            else:
                raise AssertionError("unexpected method: " + req["method"])
            print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
    elif args[:1] == ["run"]:
        assert "--no-parent" in args and "--bg" in args and "--keep" not in args
        argv = args[args.index("--") + 1:]
        terminal = {"address": "t2b", "name": "squire", "state": "live", "created_ms": 200,
                    "status": None, "cwd": "/fixture", "labels": {"squire.role": "companion"},
                    "argv": argv, "keep": False, "reason": None}
        s = state()
        s["terminals"].append(terminal)
        state_path.write_text(json.dumps(s))
        print(json.dumps({"terminal": terminal}))
    else:
        raise AssertionError("unexpected hc action: " + repr(args))


if __name__ == "__main__":
    main()
