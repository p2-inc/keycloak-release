#!/usr/bin/env python3
"""Regenerate the CRDB entries in rolling-upgrades-supported-changes.json.

Keycloak's db-compatibility-verifier plugin (misc/db-compatibility-verifier,
bound to model/jpa's `test` phase) parses every jpa-changelog*.xml on the
classpath and fails the build unless each changeSet it finds is recorded in
either rolling-upgrades-supported-changes.json or ...-unsupported-changes.json.
Adding a jpa-changelog-<v>-crdb.xml therefore obliges us to record its
changeSets, and the plugin runs even under `-DskipTests` (it is gated on
`db.verify.skip`), so a mistake here fails CI rather than shipping.

Both upstream and we append to the same list, which is why a text merge of this
file conflicts on every release that adds a changeSet. So we do not merge it:
we take upstream's file at the tag verbatim and re-derive our additions from the
*-crdb.xml files. That turns a recurring conflict into a generated artifact.

Output is written in Jackson's DefaultPrettyPrinter style -- the same writer
upstream's `snapshot` goal uses -- so upstream's entries round-trip byte for
byte and the diff against the tag shows only our appended entries. The
round-trip is asserted, not assumed: if the re-serialized upstream prefix does
not match the input exactly, this exits non-zero rather than committing a file
whose whole body reads as changed.

Usage:
  sync-rolling-upgrades.py --repo <checkout> --upstream-ref <tag> [--check]

  --check   report what would change, write nothing, exit 1 if out of date
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

META = "model/jpa/src/main/resources/META-INF"
SUPPORTED = f"{META}/rolling-upgrades-supported-changes.json"
LIQUIBASE_NS = "{http://www.liquibase.org/xml/ns/dbchangelog}"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# --- Jackson DefaultPrettyPrinter -----------------------------------------
# Objects break across lines at a 2-space indent with " : " between key and
# value; arrays stay on the line they open, wrapped in "[ " / " ]", with
# elements separated by ", "; an empty array is "[ ]". Reproducing this exactly
# is what keeps the diff to just our own entries.
def jackson(value, indent=0):
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{ }"
        items = [f'{inner}{json.dumps(k)} : {jackson(v, indent + 1)}'
                 for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[ ]"
        # Elements are rendered at this same indent level: Jackson does not add
        # a level for the array itself, which is why "}, {" sits at the object
        # indent rather than one deeper.
        items = [jackson(v, indent) for v in value]
        return "[ " + ", ".join(items) + " ]"
    return json.dumps(value)


def dumps(doc):
    # No trailing newline: Jackson's writer does not emit one, and upstream's
    # file is committed without it. Adding one would show the last line as
    # changed on every release.
    return jackson(doc, 0)


# --- inputs ---------------------------------------------------------------
def git_show(repo, ref, path):
    try:
        return subprocess.run(
            ["git", "-C", str(repo), "show", f"{ref}:{path}"],
            check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        die(f"cannot read {path} at {ref}: {e.stderr.strip()}")


def version_key(name):
    """Sort jpa-changelog-26.10.0-crdb.xml after -26.9.0-, not before."""
    m = re.search(r"jpa-changelog-(.+?)-crdb\.xml$", name)
    parts = []
    if m:
        for chunk in re.split(r"[.\-]", m.group(1)):
            parts.append((0, int(chunk), "") if chunk.isdigit() else (1, 0, chunk))
    return parts


def crdb_changesets(repo):
    """Every changeSet in every jpa-changelog-*-crdb.xml, in include order.

    Ordered by changelog version and then by document order within the file, so
    the generated block is stable across runs and reviewable as a diff.
    """
    meta = pathlib.Path(repo) / META
    files = sorted(meta.glob("jpa-changelog-*-crdb.xml"), key=lambda p: version_key(p.name))
    # master-crdb.xml is the include list, not a changelog; it has no changeSets
    # of its own and must not be scanned as one.
    files = [f for f in files if f.name != "jpa-changelog-master-crdb.xml"]

    entries = []
    for f in files:
        try:
            root = ET.parse(f).getroot()
        except ET.ParseError as e:
            die(f"{f.name} is not valid XML: {e}")
        found = root.findall(f"{LIQUIBASE_NS}changeSet") or root.findall("changeSet")
        if not found:
            print(f"warning: {f.name} declares no changeSets", file=sys.stderr)
        for cs in found:
            cid, author = cs.get("id"), cs.get("author")
            if not cid or not author:
                die(f"{f.name}: changeSet missing id or author attribute")
            entries.append({"id": cid, "author": author,
                            "filename": f"META-INF/{f.name}"})
    return entries, [f.name for f in files]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--upstream-ref", required=True,
                    help="tag/ref holding the pristine upstream JSON")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo)
    target = repo / SUPPORTED
    if not target.parent.is_dir():
        die(f"{repo} does not look like a Keycloak checkout ({META} missing)")

    raw = git_show(repo, args.upstream_ref, SUPPORTED)
    try:
        upstream = json.loads(raw)
    except json.JSONDecodeError as e:
        die(f"upstream {SUPPORTED} at {args.upstream_ref} is not valid JSON: {e}")

    # Assert the writer is faithful before trusting it with real output.
    if dumps(upstream) != raw:
        die("the Jackson-style serializer does not round-trip upstream's file "
            "byte for byte; refusing to rewrite it. Upstream may have changed "
            "its formatting -- compare dumps(upstream) with the file at "
            f"{args.upstream_ref}:{SUPPORTED}")

    if "changeSets" not in upstream:
        die(f"upstream {SUPPORTED} has no 'changeSets' key")

    entries, files = crdb_changesets(repo)

    # Upstream's own list is authoritative and must not be edited: our entries
    # are appended, so the diff against the tag is purely additive.
    upstream_ids = {(c["id"], c["filename"]) for c in upstream["changeSets"]}
    for e in entries:
        if (e["id"], e["filename"]) in upstream_ids:
            die(f"changeSet {e['id']} in {e['filename']} is already recorded "
                "upstream; a -crdb changelog must not reuse an upstream id")

    seen = set()
    for e in entries:
        key = (e["id"], e["filename"])
        if key in seen:
            die(f"duplicate changeSet id {e['id']} in {e['filename']}")
        seen.add(key)

    doc = dict(upstream)
    doc["changeSets"] = list(upstream["changeSets"]) + entries
    new = dumps(doc)

    old = target.read_text() if target.exists() else ""
    changed = new != old

    print(f"{len(upstream['changeSets'])} upstream + {len(entries)} crdb "
          f"= {len(doc['changeSets'])} changeSets", file=sys.stderr)
    for f in files:
        n = sum(1 for e in entries if e["filename"].endswith(f))
        print(f"  {f}: {n}", file=sys.stderr)

    if args.check:
        print("out of date" if changed else "up to date", file=sys.stderr)
        sys.exit(1 if changed else 0)

    if changed:
        target.write_text(new)
        print(f"wrote {SUPPORTED}", file=sys.stderr)
    else:
        print(f"{SUPPORTED} already up to date", file=sys.stderr)


if __name__ == "__main__":
    main()
