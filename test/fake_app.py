#!/usr/bin/env python3
"""Test double for the approved subset of Herdr App operations."""
import json
import os
import shutil
import sys
from pathlib import Path

home = Path(os.environ["HERDR_APP_HOME"])
state_path = home / "fake-state.json"
args = sys.argv[1:]
state = json.loads(state_path.read_text())
if args == ["status"]:
    print(json.dumps({"layout": state["layout"], "errors": []}))
else:
    assert args[0] == "do"
    cmd = args[1]
    value = json.loads(args[2])
    if cmd == "layout.clone":
        dest = home / "layouts" / (value["as"] + ".json")
        assert not dest.exists()
        shutil.copyfile(home / "layouts" / (value["name"] + ".json"), dest)
        state["layout"] = value["as"]
    elif cmd == "layout.switch":
        if os.environ.get("SQUIRE_APP_FAIL") and value["name"] == "squire":
            print(json.dumps({"error": "switch fixture failure"}))
            sys.exit(1)
        state["layout"] = value["name"]
    else:
        raise AssertionError("unexpected app action: " + cmd)
    state_path.write_text(json.dumps(state))
    print("{}")
