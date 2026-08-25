#!/usr/bin/env python3
"""Static checks on the caller/callee contract between our workflows.

Both checks here exist because a real bug got through actionlint, a passing
test suite, and two green end-to-end runs -- and then failed as a
`startup_failure`: no log, no job, just "This run likely failed because of a
workflow file issue".

  1. Every `inputs.X` a workflow references must be declared for every trigger
     the workflow can be invoked through.
  2. A caller must hold at least the permissions its callees declare.

Both faults share the property that makes them nasty: they are invisible to the
path you are most likely to test. Declaring `publish` under `workflow_dispatch`
only means direct dispatch works perfectly while every `workflow_call` from the
poller dies at startup. Likewise a caller with `contents: read` calling a
workflow that declares `contents: write` fails only through the calling path,
never when that workflow is dispatched directly.

Exit status: 0 clean, 1 problems found.
"""
import pathlib
import re
import sys

import yaml

TRIGGERS = ("workflow_call", "workflow_dispatch")

# read < write, and none < read. Compared per scope.
RANK = {"none": 0, "read": 1, "write": 2}


def triggers_of(doc):
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = doc.get("on", doc.get(True))
    if not isinstance(on, dict):
        return {}
    return {t: (on[t] or {}).get("inputs") or {} for t in TRIGGERS if t in on}


def perms_of(doc):
    p = doc.get("permissions")
    if p is None:
        return None
    if isinstance(p, str):          # `permissions: read-all` / `write-all`
        return {"__all__": p.replace("-all", "")}
    return p


def callees(text):
    """Local reusable workflows this file calls."""
    return set(re.findall(r"uses:\s*\./(\.github/workflows/[\w.-]+\.ya?ml)", text))


def main():
    root = pathlib.Path(__file__).resolve().parents[2]
    files = sorted((root / ".github/workflows").glob("*.yml"))
    problems = 0
    docs = {}
    for f in files:
        try:
            docs[f] = yaml.safe_load(f.read_text())
        except yaml.YAMLError:
            pass

    for f in files:
        text = f.read_text()
        try:
            doc = yaml.safe_load(text)
        except yaml.YAMLError as e:
            print(f"{f.name}: cannot parse: {e}")
            problems += 1
            continue

        declared = triggers_of(doc)
        if not declared:
            continue

        referenced = set(re.findall(r"inputs\.([A-Za-z_][A-Za-z0-9_-]*)", text))
        if not referenced:
            continue

        for trigger, inputs in declared.items():
            missing = sorted(referenced - set(inputs))
            if missing:
                print(f"{f.name}: referenced but not declared under {trigger}: "
                      + ", ".join(missing))
                problems += 1

    # --- 2. caller permissions must cover the callees ---------------------
    for f, doc in docs.items():
        if not isinstance(doc, dict):
            continue
        caller = perms_of(doc)
        for rel in callees(f.read_text()):
            callee_path = root / rel
            callee = docs.get(callee_path)
            if not isinstance(callee, dict):
                print(f"{f.name}: calls {rel}, which was not parsed")
                problems += 1
                continue
            needed = perms_of(callee) or {}
            have = caller or {}
            for scope, level in needed.items():
                mine = have.get("__all__", have.get(scope, "none"))
                if RANK.get(str(level), 0) > RANK.get(str(mine), 0):
                    print(f"{f.name}: calls {pathlib.Path(rel).name} which needs "
                          f"{scope}: {level}, but the caller only has {scope}: {mine}")
                    problems += 1

    if problems:
        print(f"\n{problems} problem(s). Either would fail as a startup_failure "
              "through the calling path only, so direct dispatch would keep "
              "looking fine.", file=sys.stderr)
        return 1
    print(f"checked {len(files)} workflow(s): inputs declared for every trigger, "
          "caller permissions cover their callees")
    return 0


if __name__ == "__main__":
    sys.exit(main())
