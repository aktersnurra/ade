#!/usr/bin/env python3
"""A fake SmolVM CLI for end-to-end tests of the ade binary.

It implements just enough of `machine status|create|start|stop|delete|shell|exec`
to exercise ADE's convergence logic, and records every invocation so a test can
assert on the exact argv ADE produced. Machine state lives in the JSON file named
by FAKE_SMOLVM_STATE.
"""

import json
import os
import sys

STATE_PATH = os.environ.get("FAKE_SMOLVM_STATE", "/tmp/fake-smolvm-state.json")
LOG_PATH = os.environ.get("FAKE_SMOLVM_LOG")


def load():
    try:
        with open(STATE_PATH) as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(state):
    with open(STATE_PATH, "w") as handle:
        json.dump(state, handle)


def value_after(argv, flag):
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def main():
    argv = sys.argv[1:]
    if LOG_PATH:
        with open(LOG_PATH, "a") as handle:
            handle.write(" ".join(argv) + "\n")

    if argv[:1] == ["--version"]:
        print("smolvm 1.13.1")
        return 0

    if argv[:1] != ["machine"] or len(argv) < 2:
        print(f"unsupported command: {argv}", file=sys.stderr)
        return 2

    verb = argv[1]
    name = value_after(argv, "--name")
    state = load()

    if verb == "status":
        if name not in state:
            print(f"machine '{name}' not found", file=sys.stderr)
            return 1
        print(json.dumps({"name": name, "state": state[name]}))
        return 0

    if verb == "create":
        if name in state:
            print(f"machine '{name}' already exists", file=sys.stderr)
            return 1
        state[name] = "created"
        save(state)
        return 0

    if verb == "start":
        if name not in state:
            print(f"machine '{name}' not found", file=sys.stderr)
            return 1
        state[name] = "running"
        save(state)
        return 0

    if verb == "stop":
        if name not in state:
            print(f"machine '{name}' not found", file=sys.stderr)
            return 1
        state[name] = "stopped"
        save(state)
        return 0

    if verb == "delete":
        # SmolVM 1.32 asks for confirmation, and refuses without a terminal.
        if "--force" not in argv:
            print(f"machine '{name}' needs confirmation but stdin is not a terminal", file=sys.stderr)
            return 1
        state.pop(name, None)
        save(state)
        return 0

    if verb in ("shell", "exec"):
        if state.get(name) != "running":
            print(f"machine '{name}' is not running", file=sys.stderr)
            return 1
        # machine shell takes no command.
        if verb == "shell" and "--" in argv:
            print("error: unexpected argument '--' found", file=sys.stderr)
            return 2
        if "--" in argv:
            command = argv[argv.index("--") + 1 :]
            if command:
                print(" ".join(command))
            # `exit N` stands in for a guest command that fails with status N.
            if len(command) == 2 and command[0] == "exit":
                return int(command[1])
        return 0

    print(f"unsupported machine subcommand: {verb}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
