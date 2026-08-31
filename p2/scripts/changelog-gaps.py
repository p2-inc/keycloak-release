#!/usr/bin/env python3
"""Report changelogs a release added that our CRDB master doesn't account for.

jpa-changelog-master-crdb.xml is our parallel include list. For each changelog
it names either upstream's file (its DDL is CockroachDB-safe) or a -crdb variant
(it isn't -- see jpa-changelog-26.7.0-crdb.xml, which replaces a DROP+ADD of a
primary key with ALTER PRIMARY KEY, because CockroachDB does not implement the
former as separate statements).

It is deliberately NOT a full mirror of upstream's master.xml: it starts at
jpa-changelog-17.0.0-crdb.xml, a consolidated 268-changeSet baseline that
subsumes every pre-17 changelog, and skips others (18.0.15) on purpose. So
comparing the two lists wholesale reports ~54 false gaps. The question that
actually matters is narrower:

    which changelogs does upstream include at the NEW tag that it did not
    include at the BASE tag, and are those accounted for?

Those are the ones a cherry-picked master-crdb has never seen. Miss one and the
release's migrations silently do not run on CockroachDB -- invisible to the
compiler and to the db-compatibility-verifier, surfacing only as a broken schema
at runtime. Whether a new changelog needs a -crdb variant, and what goes in it,
is a judgement call: it goes to an agent and then to review.

Exit status: 0 clean, 2 gaps found, 1 error.

Usage:
  changelog-gaps.py --repo <checkout> --base-ref <tag> --new-ref <tag>
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

META = "model/jpa/src/main/resources/META-INF"
MASTER = f"{META}/jpa-changelog-master.xml"
CRDB_MASTER = f"{META}/jpa-changelog-master-crdb.xml"
NS = "{http://www.liquibase.org/xml/ns/dbchangelog}"


def parse_includes(text, what):
    """The changelog filenames a master file includes, in order.

    Parsed as XML rather than grepped so commented-out includes are ignored:
    master-crdb.xml carries at least one (the 26.0.6 changelog upstream
    withdrew in 26.1.0), and treating it as live would be wrong.
    """
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        sys.exit(f"error: cannot parse {what}: {e}")
    found = root.findall(f"{NS}include") or root.findall("include")
    return [pathlib.PurePosixPath(f).name
            for f in (inc.get("file") for inc in found) if f]


def git_show(repo, ref, path):
    r = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{path}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"error: cannot read {path} at {ref}: {r.stderr.strip()}")
    return r.stdout


def base_name(name):
    """jpa-changelog-26.7.0-crdb.xml -> jpa-changelog-26.7.0.xml"""
    return re.sub(r"-crdb\.xml$", ".xml", name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--base-ref", required=True,
                    help="the tag the CRDB branch was ported from")
    ap.add_argument("--new-ref", required=True,
                    help="the tag being ported to")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo)
    meta = repo / META
    crdb_master = repo / CRDB_MASTER
    if not crdb_master.is_file():
        sys.exit(f"error: {CRDB_MASTER} not found in {repo}; "
                 "run this after the cherry-pick, not before")

    old_up = parse_includes(git_show(repo, args.base_ref, MASTER),
                            f"{MASTER} at {args.base_ref}")
    new_up = parse_includes(git_show(repo, args.new_ref, MASTER),
                            f"{MASTER} at {args.new_ref}")
    ours = parse_includes(crdb_master.read_text(), CRDB_MASTER)

    added = [n for n in new_up if n not in set(old_up)]
    dropped = [n for n in old_up if n not in set(new_up)]

    # What our list covers, keyed by the upstream changelog it stands in for.
    covered = {base_name(n): n for n in ours}

    gaps = [n for n in added if n not in covered]
    handled = [(n, covered[n]) for n in added if n in covered]
    # Upstream withdrew a changelog that we still include: our schema would keep
    # applying something upstream retired.
    stale = [covered[n] for n in dropped if n in covered]
    # An include naming a file that isn't there fails at runtime, not build time.
    broken = [n for n in ours if not (meta / n).is_file()]

    def section(title, rows):
        if rows:
            print(f"\n{title}")
            for r in rows:
                print(f"  {r}")

    print(f"upstream changelogs: {len(old_up)} at {args.base_ref} -> "
          f"{len(new_up)} at {args.new_ref}")
    print(f"master-crdb.xml includes {len(ours)}")
    if not added and not dropped:
        print(f"{args.new_ref} adds no changelogs over {args.base_ref}")

    section(f"added by {args.new_ref}, already accounted for:",
            [f"{a} -> {b}" for a, b in handled])
    section(f"added by {args.new_ref}, NOT accounted for (needs a decision):", gaps)
    section(f"withdrawn by {args.new_ref} but still included by master-crdb.xml:", stale)
    section("included by master-crdb.xml but missing on disk:", broken)

    if args.github_output and (out := os.environ.get("GITHUB_OUTPUT")):
        with open(out, "a") as fh:
            fh.write(f"gaps={' '.join(gaps)}\n")
            fh.write(f"gap_count={len(gaps)}\n")
            fh.write(f"stale={' '.join(stale)}\n")
            fh.write(f"broken={' '.join(broken)}\n")

    if broken:
        print("\nerror: master-crdb.xml includes files that do not exist",
              file=sys.stderr)
        return 1
    if gaps:
        print(f"\n{len(gaps)} changelog(s) need a CockroachDB decision: include "
              "upstream's file as-is if its DDL is CockroachDB-safe, or add a "
              "-crdb variant and include that instead.", file=sys.stderr)
        return 2
    print("\nno gaps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
