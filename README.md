# p2-ci — release automation for the CockroachDB fork

This branch is not Keycloak. It holds only the automation that publishes our
CockroachDB branches and images, and it is the repository's default branch so
that scheduled and manually dispatched workflows can run from it.

Nothing here is ever merged into a `*_crdb` branch. Those stay exactly what they
have always been: one commit on top of an upstream tag, carrying the CockroachDB
patch and nothing else.

```
main                     pristine upstream mirror, untouched
26.7.2_crdb, ...         one commit on the tag — the published patch
p2-ci                    ← you are here: workflows and scripts only
```

## What it does

**Every six hours** `p2-upstream-poll.yml` asks upstream for its tag list, works
out what is missing, and dispatches the work. A fork gets no events when upstream
pushes a tag, so polling is the only option.

**Vanilla images** — every new tag is built and pushed to
`quay.io/phasetwo/keycloak`. Upstream cuts tags it never publishes an image for
(CVE backports especially); this catches them. It also gives us a base image we
control, so `ubi9-micro` can be swapped for Wolfi without waiting on upstream.

**CRDB ports** — a new tag in a stream that already has a `_crdb` branch, or the
first tag of a brand-new minor or major, gets the CockroachDB patch cherry-picked
onto it, built, smoke-tested against a real CockroachDB, and published as
`<version>_crdb` plus `quay.io/phasetwo/keycloak-crdb`.

## Why a cherry-pick, and what that bought

Every `*_crdb` branch is exactly one commit on its tag — checked across 26.4.12,
26.6.5, 26.6.6, 26.7.0 and 26.7.2. So the port is `git cherry-pick`, not
`git diff | git apply`. That gets real three-way merging with the tag as merge
base, carries the binary JDBC driver jar across on its own, and leaves conflict
markers on what it genuinely cannot decide instead of failing the whole patch.

Two of the three conflicts a minor bump used to produce are now gone by
construction, because they were never real:

| file | why it conflicted | what we do |
|---|---|---|
| `openapi.yaml`/`.json` | build output, committed by accident. Carries the version string the build stamped in, so it conflicts every release — and upstream renamed `.yaml` to `.json` in 26.7.0, making it a modify/delete | dropped from the patch entirely; the build regenerates it |
| `rolling-upgrades-supported-changes.json` | upstream appends to the same list we append to | regenerated from the `*-crdb.xml` changeSets, never merged |

Measured on real tags: `26.6.5_crdb → 26.6.6` cherry-picks clean and lands
identical to the hand-built branch apart from those two. `26.6.6_crdb → 26.7.0`
went from three conflicts to one — the genuine upstream drift in
`DatabasePropertyMappers.java` — plus the new `26.7.0` changelog to port.

## When it stops for a human

Conflicts or a new changelog mean judgement is needed. An agent
(`p2/prompts/resolve-crdb-port.md`) resolves it, and the result is **still
built and smoke-tested** — but never auto-published. Instead it opens a PR whose
diff *is* the CockroachDB patch:

```
review/<version>_base    the upstream tag, unmodified   ← PR base
review/<version>_crdb    the port                       ← PR head
```

Branch naming there is a safety property. Anything called `<version>_crdb` is
treated as publishable — `phasetwo-containers` resolves that exact ref to decide
what to build — so creating it early, even as an empty PR base, would have that
repo build an unpatched Keycloak and ship it as the CockroachDB image. Review
happens entirely under `review/`, which nothing resolves. Merging the PR
publishes nothing; the PR body carries the command that does.

## What gets verified before anything is published

`p2/scripts/smoke-test.sh` brings the built image up against a real CockroachDB
and checks four things, because the patch is mostly Liquibase changelogs and a
JDBC dialect and *compiling exercises none of it*:

1. Keycloak reaches `/health/ready` — it booted and migrated.
2. The `-crdb` changeSets are in `DATABASECHANGELOG` — the CockroachDB changelogs
   actually ran. This is the one that justifies the exercise: a `master-crdb.xml`
   that lost its includes in a merge yields a server that boots perfectly on an
   empty database and is silently wrong.
3. An admin token can be minted — the schema is usable.
4. It survives a restart with an unchanged changeSet count — migrations are
   idempotent, so upgrades work.

## Layout

```
.github/workflows/
  p2-upstream-poll.yml      schedule + dispatch: find work, dispatch it
  p2-crdb-release.yml       port → verify → publish, or open a review PR
  p2-crdb-publish.yml       publish an existing branch (after a review, or a rebuild)
  p2-vanilla-release.yml    unpatched image for a tag
  p2-selftest.yml           CI for this branch
.github/actions/keycloak-dist/
                            release asset if there is one, else build from source
p2/
  config.sh                 all policy and naming, env-overridable
  baseline-tags.txt         tags that existed at activation — the "don't backfill" floor
  docker/                   smoke-test stack; wolfi/ for the future base swap
  prompts/                  the agent brief
  scripts/                  see below
```

| script | what it does |
|---|---|
| `detect-work.sh` | decides what needs building; emits Actions matrices |
| `prepare-source.sh` | blobless clone + the exact refs a port needs (~20s, ~150MB) |
| `port-crdb.sh` | cherry-pick and the mechanical fixups |
| `finalize-crdb.sh` | commit after resolution, then check the shape of the result |
| `sync-rolling-upgrades.py` | regenerate the changeSet ledger from the `-crdb` changelogs |
| `changelog-gaps.py` | changelogs this release added that `master-crdb.xml` misses |
| `smoke-test.sh` / `smoke-vanilla.sh` | verify an image before it ships |
| `image-tags.sh` | tag list, including whether `latest` should move |
| `open-review-pr.sh` | the review PR |
| `setup-repo.sh` | switch the automation on |
| `test-all.sh` / `test-detect.sh` | everything testable without a runner |

## Policy

All of it lives in `p2/config.sh`, and every setting is env-overridable so a
dispatch or a test can change one knob without editing the file.

A stream is *tracked* if it already has a `*_crdb` branch — derived from the
fork's refs, not listed anywhere, so adopting a stream is a consequence of
publishing its first branch. Two things qualify it out:

- `CRDB_DORMANT_STREAMS="26.2 26.4"` — these have `_crdb` branches but we stopped
  maintaining them. At activation both were several backports behind (26.4.13,
  .14, .15 and 26.2.14, .15, .16 were all skipped by hand), so treating them as
  tracked would have resurrected six ports nobody asked for. Delete a stream from
  the list to pick it back up.
- `p2/baseline-tags.txt` — the 176 tags that existed when this was switched on.
  The poller exists to catch what upstream publishes *from now on*; without this
  floor its first run would have tried to build years of history.

`latest` moves only when a version is the highest ever published to that
repository. Upstream backports into several streams at once, so tags do not
arrive in version order — 26.4.15 was published after 26.7.2 — and this is the
same rule the manual process applied by hand.

## Running it by hand

```bash
# what would the poller do right now? (changes nothing)
gh workflow run p2-upstream-poll.yml -f dry_run=true

# port, build and smoke test, publishing nothing
gh workflow run p2-crdb-release.yml -f version=26.7.3 -f dry_run=true

# for real
gh workflow run p2-crdb-release.yml -f version=26.7.3
gh workflow run p2-vanilla-release.yml -f version=26.7.3

# publish a reviewed port, or rebuild an image whose branch is fine
gh workflow run p2-crdb-publish.yml -f version=26.7.3 -f from_ref=review/26.7.3_crdb

# backfill something older than the baseline
gh workflow run p2-upstream-poll.yml -f version=26.4.15 -f ignore_baseline=true
```

Before changing anything here:

```bash
p2/scripts/test-all.sh     # ~1s; also what p2-selftest.yml runs
```

## Setup

`p2/scripts/setup-repo.sh` reports by default and changes nothing without
`--apply`. Read its header comment before running it — the ordering is
deliberate. In short: this fork carries all 21 of upstream's workflows, all
marked active, and the only reason none has ever run is that Actions is disabled
at the repository level. Enabling Actions without first moving the default branch
would start upstream's nightly schedules here, and make any human push to a
`*_crdb` branch trigger a full Keycloak CI run.

Secrets to set (the script reports which are missing but never sets them):

| secret | for |
|---|---|
| `QUAY_USERNAME`, `QUAY_ROBOT_TOKEN` | pushing images — same values as `phasetwo-containers` |
| `ANTHROPIC_API_KEY` *or* `CLAUDE_CODE_OAUTH_TOKEN` | resolving ports that need judgement |

Issues are disabled on this repository, so PRs are the only in-repo notification
surface. If you want to be pushed at rather than polled, a Slack step is a small
addition to `p2-crdb-release.yml`.

## Known rough edges

- **Multi-arch builds use QEMU**, matching what the manual process did. The
  `dnf`/`ubi-null.sh` steps are slow under emulation. Splitting into native
  `ubuntu-latest` + `ubuntu-24.04-arm` jobs joined with
  `docker buildx imagetools create` would be considerably faster, and is free on
  a public repo — deliberately left for after the first green run.
- **The distribution is always built on amd64.** It embeds one platform-specific
  `brotli4j` native jar, chosen by OS-activated Maven profiles in brotli4j's own
  pom and not overridable from the command line. Upstream builds on linux/amd64,
  so both architectures' images are assembled from that one tarball, exactly as
  upstream's own are.
- **`js/pom.xml`** carries a `--config.confirmModulesPurge=false` fix that is
  absent from `26.7.0_crdb`, suggesting upstream fixed it. The cherry-pick will
  keep resurrecting it until someone confirms it can be dropped.
- **`quarkus/container/docker-compose.yml`** on the `_crdb` branches still has a
  `caddy` service reverse-proxying a hard-coded public hostname
  (`s01.villamiramar.fr`). The smoke test uses its own stack and is unaffected,
  but that file is worth a tidy-up next time it is touched.
