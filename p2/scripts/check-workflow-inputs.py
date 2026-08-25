#!/usr/bin/env python3
"""Check that every `inputs.X` a workflow references is declared for every
trigger the workflow can be invoked through.

An expression referencing an input that the invoking trigger has not declared
fails GitHub's static validation, and it fails as a `startup_failure` before any
job runs, with no log and only "This run likely failed because of a workflow
file issue" to go on. Worse, it is invisible to the path you are most likely to
test: declaring `publish` under `workflow_dispatch` only means direct dispatch
works perfectly while every `workflow_call` from the poller dies at startup.
That is exactly what happened here, and actionlint does not catch it.

Exit status: 0 clean, 1 problems found.
"""
import pathlib
import re
import sys

import yaml

TRIGGERS = ("workflow_call", "workflow_dispatch")


def triggers_of(doc):
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = doc.get("on", doc.get(True))
    if not isinstance(on, dict):
        return {}
    return {t: (on[t] or {}).get("inputs") or {} for t in TRIGGERS if t in on}


def main():
    root = pathlib.Path(__file__).resolve().parents[2]
    files = sorted((root / ".github/workflows").glob("*.yml"))
    problems = 0

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

    if problems:
        print(f"\n{problems} workflow(s) reference an input a trigger does not "
              "declare. Declare it for every trigger, or the invocations through "
              "the others fail as startup_failure.", file=sys.stderr)
        return 1
    print(f"checked {len(files)} workflow(s): every referenced input is declared "
          "for every trigger")
    return 0


if __name__ == "__main__":
    sys.exit(main())
