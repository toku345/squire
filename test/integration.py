"""CLI, REPL, protocol and launcher tests with isolated fake integrations."""
import json
import fcntl
import os
import pty
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
checks = 0


def check(condition, name):
    global checks
    checks += 1
    assert condition, name


with tempfile.TemporaryDirectory(prefix="squire-integration-") as directory:
    root = Path(directory)
    home = root / "app"
    (home / "layouts").mkdir(parents=True)
    base = {"id": "root", "type": "row", "children": [
        {"id": "work", "type": "block", "content": {"tab": "active"}, "size": {"weight": 1}}]}
    base_file = home / "layouts/bottom-tabs.json"
    base_file.write_text(json.dumps(base))
    (home / "fake-state.json").write_text(json.dumps({"layout": "bottom-tabs"}))
    data = root / "data"
    state = root / "hc-state.json"
    log = root / "hc.log"
    fixture = {"machines": [{"id": "remote-core", "name": "box", "state": "connected"}],
               "terminals": [
                   {"address": "t1b", "created_ms": 100, "cwd": "/work", "state": "live",
                    "status": {"state": "done", "app": "codex", "msg": "secret-message"},
                    "labels": {"where": "work / 1"}, "title": "secret-title", "argv": ["secret-arg"]},
                   {"address": "box/t1", "created_ms": 120, "cwd": "/remote", "state": "live",
                    "status": None, "labels": {}}]}
    state.write_text(json.dumps(fixture))
    for name in ("hc", "app"):
        target = root / ("fake-" + name)
        shutil.copyfile(Path(__file__).with_name("fake_" + name + ".py"), target)
        target.chmod(0o700)
    env = dict(os.environ, HERDR_APP_HOME=str(home), SQUIRE_HC_STATE=str(state), SQUIRE_HC_LOG=str(log))

    def run(command, *args, input=None, behavior=None, fail_app=False):
        call_env = dict(env)
        if behavior:
            call_env["SQUIRE_HC_BEHAVIOR"] = behavior
        if fail_app:
            call_env["SQUIRE_APP_FAIL"] = "1"
        cmd = [binary, command, "--data-dir", str(data), *map(str, args)]
        return subprocess.run(cmd, input=input, text=True, capture_output=True, env=call_env, timeout=15)

    def ok(command, *args, **kwargs):
        result = run(command, *args, **kwargs)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    title = "書類提出 $(touch NEVER) `echo unsafe`"
    check(title in ok("add", title), "literal Japanese title")
    ok("update", "1", "--status", "doing", "--next", "提出先を確認")
    hc = ["--hc", root / "fake-hc"]
    check("プログラム報告=done" in ok("sessions", *hc), "raw report shown")
    check("[doing]" in ok("list"), "report cannot complete work")
    ok("link", "1", "t1b", *hc)
    ok("link", "1", "box/t1", *hc)
    check("関連 2:" in ok("show", "1"), "multiple links")
    stale = run("sessions", *hc, behavior="fail")
    check(stale.returncode != 0 and "古い情報" in stale.stdout, "stale is unsuccessful")
    check(run("link", "1", "t1b", *hc, behavior="fail").returncode != 0, "no stale link")
    check(run("sessions", *hc, behavior="generation").returncode != 0, "incompatible API fails")
    check(run("sessions", *hc, behavior="hang").returncode != 0, "timeout bounded")
    contents = (data / "squire.sqlite").read_bytes()
    check(not any(word.encode() in contents for word in ("secret-message", "secret-title", "secret-arg")), "no raw session content saved")
    check((data.stat().st_mode & 0o777) == 0o700, "private data directory")
    check(((data / "squire.sqlite").stat().st_mode & 0o777) == 0o600, "private DB")

    repl = ok("repl", *hc, input="add セッションなしの仕事\nupdate 2\nnext\n明日確認する\ndone 2\nquit\n")
    check("[done]" in repl and "明日確認する" in ok("show", "2"), "Japanese REPL persisted")
    ok("reopen", "2")
    check("[todo]" in ok("show", "2"), "explicit reopen")
    master, slave = pty.openpty()
    pty_data = root / "pty-data"
    child = subprocess.Popen([binary, "repl", "--data-dir", str(pty_data)],
                             stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)

    def until_prompt():
        output = b""
        deadline = time.monotonic() + 5
        while b"squire> " not in output:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], "PTY prompt timeout"
            chunk = os.read(master, 8192)
            assert chunk, "PTY ended before prompt"
            output += chunk
        return output

    try:
        until_prompt()
        os.write(master, "add 日本語X".encode() + b"\x7f\n")
        until_prompt()
        os.write(master, b"quit\n")
        check(child.wait(timeout=5) == 0, "PTY exits normally")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)
    pty_result = subprocess.run([binary, "show", "1", "--data-dir", str(pty_data)],
                                capture_output=True, text=True, env=env, timeout=5)
    check("日本語" in pty_result.stdout and "日本語X" not in pty_result.stdout, "UTF-8 and terminal line editing")
    with sqlite3.connect(data / "squire.sqlite") as db:
        db.execute("CREATE TRIGGER fail_update BEFORE UPDATE ON work_items BEGIN SELECT RAISE(ABORT,'fixture'); END")
    check(run("done", "1").returncode != 0 and "[doing]" in ok("show", "1"), "DB failure is unsuccessful")

    open_args = [*hc, "--herdr-app", root / "fake-app", "--app-home", home]
    preview = ok("open", *open_args, "--preview")
    check("<assigned-at-open>" in preview and not (home / "layouts/squire.json").exists(), "preview does not apply")
    original = base_file.read_bytes()
    ok("open", *open_args)
    target = home / "layouts/squire.json"
    layout = json.loads(target.read_text())
    check(layout["children"][-1]["children"][0]["content"] == {"terminal": "t2b"}, "native terminal block")
    layout["children"][-1]["size"] = {"px": 550}
    target.write_text(json.dumps(layout))
    ok("open", *open_args)
    check(json.loads(target.read_text())["children"][-1]["size"] == {"px": 550}, "reopen preserves width")
    records = [json.loads(line) for line in log.read_text().splitlines()]
    check(sum(isinstance(r, list) and r[:1] == ["run"] for r in records) == 1, "no duplicate process")
    layout = json.loads(target.read_text())
    layout["children"][-1]["children"] = []
    target.write_text(json.dumps(layout))
    s = json.loads(state.read_text())
    s["terminals"] = [t for t in s["terminals"] if t["address"] != "t2b"]
    state.write_text(json.dumps(s))
    ok("open", *open_args)
    check(len(json.loads(target.read_text())["children"][-1]["children"]) == 1, "exit removes slot, open restores")
    (home / "fake-state.json").write_text(json.dumps({"layout": "bottom-tabs"}))
    check(run("open", *open_args, fail_app=True).returncode != 0, "switch failure reported")
    check(json.loads((home / "fake-state.json").read_text())["layout"] == "bottom-tabs", "failure restores selection")
    check(base_file.read_bytes() == original, "base layout remains unchanged")
    with open(data / "open.lock", "a") as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check(run("open", *open_args).returncode != 0, "OS lock rejects concurrent open")
    ok("open", *open_args)
    check(json.loads((home / "fake-state.json").read_text())["layout"] == "squire", "OS lock released after owner exits")
    s = json.loads(state.read_text())
    s["terminals"][-1]["argv"] = ["unrelated"]
    state.write_text(json.dumps(s))
    check(run("open", *open_args).returncode != 0, "name collision cannot take over")
    records = [json.loads(line) for line in log.read_text().splitlines()]
    methods = {r["method"] for r in records if isinstance(r, dict)}
    check(methods == {"hello", "terminal.list"}, "observation only calls approved read methods")
    check(all(not isinstance(r, list) or r[:1] in (["connect"], ["run"]) for r in records), "no read/send/kill actions")

print(f"squire integration: {checks} checks passed")
