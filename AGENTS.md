# Working on this branch

`p2-ci` is the release automation for the CockroachDB fork, and nothing else. It
is the repository's default branch so scheduled and dispatched workflows run
from it. Read `README.md` for what the system does and why; this file is the
short version of what will bite you.

**Before you push anything here:**

```bash
p2/scripts/test-all.sh     # ~1s, no network beyond a few ls-remotes
```

That is also what `p2-selftest.yml` runs, so a red suite is a red branch.

## Invariants

Break one of these and the failure is silent or expensive, not obvious.

1. **`<version>_crdb` means "published and consumable".** `phasetwo-containers`
   resolves that exact ref to decide what to build, so creating it early — even
   empty, even as a PR base — makes that repo build an unpatched Keycloak and
   ship it as the CockroachDB image. Work in progress goes under `review/`;
   inter-job handoff goes under `refs/p2/staging/`.

2. **Every `*_crdb` branch is exactly one commit on its tag.** The port asserts
   this before cherry-picking and `finalize-crdb.sh` asserts it after. If you
   ever need a second commit, the porting model needs rethinking, not a squash.

3. **Two files in the patch are generated. Never hand-edit them.**
   `rolling-upgrades-supported-changes.json` is derived from the `*-crdb.xml`
   changeSets by `sync-rolling-upgrades.py`; `js/libs/keycloak-admin-client/
   openapi.*` is build output that must stay *out* of the patch entirely.
   Both used to conflict on every single release. That is why they are generated.

4. **Nothing on this branch is ever merged into a `*_crdb` branch.** The
   published patch stays exactly what it has always been. The CI agent gets
   `p2/prompts/resolve-crdb-port.md` instead — which also means an agent working
   directly on a `*_crdb` checkout will not see this file.

5. **Policy lives in `p2/config.sh`**, every setting env-overridable. A stream is
   *tracked* if it has a `*_crdb` branch — derived from refs, not listed. Adding
   a config knob is usually the wrong answer; check whether the state can be
   derived instead.

## Traps

Each of these cost real debugging time here.

**Workflow contracts.** An `inputs.X` referenced in a job `if:` must be declared
for *every* trigger the workflow can be invoked through, and a caller must hold
at least the permissions its callees declare. Get either wrong and the run dies
as `startup_failure` — no log, no job, just "This run likely failed because of a
workflow file issue" — and *only through the calling path*, so direct dispatch
keeps looking perfect. `actionlint` does not catch either. The poller was broken
this way from the start, twice over. `p2/scripts/check-workflow-contracts.py`
guards both; it runs in `test-all.sh`.

**`bash` is 3.2 on macOS.** No `mapfile`. And a heredoc inside `$(...)` is
mis-parsed as soon as the body contains an apostrophe — pass a file with
`--body-file` rather than building a big string. CI runs bash 5, so `bash -n`
locally is the stricter check.

**`gh api --jq` prints the error body to *stdout* on failure.** A 403 therefore
looks like a populated list of one very strange element. Branch on exit status,
never on emptiness.

**`git ls-remote --heads origin X_crdb` also matches `review/X_crdb`.** Use the
full `refs/heads/X_crdb` when you mean one ref. `fork_crdb_versions` globs
`*_crdb` and is only safe because `TAG_PATTERN` filters the results — there is a
test pinning that.

**`-DskipTests` does not skip the changeSet ledger check.** `model/jpa` binds
Keycloak's `db-compatibility-verifier` to the `test` phase, gated on
`db.verify.skip`. This is a feature: a wrong `sync-rolling-upgrades.py` output
fails the build with the missing changeSet named. Do not "fix" a failure there
by editing the JSON.

**Size is not integrity.** An interrupted tarball download is almost the right
length and a valid prefix, so it passes a size check and then fails deep inside
`docker build` as `unpigz: corrupted`. `gzip -t` it.

**The agent needs Bash.** `--permission-mode acceptEdits` auto-approves file
writes but still *asks* for Bash, and non-interactively asking means denied. A
run configured that way spent all 80 turns collecting 21 denials. The brief tells
the agent to read both sides of a conflict with git and to compile what it
changed; it must actually be able to.

**Multi-arch is QEMU today.** The `dnf`/`ubi-null.sh` steps are slow under
emulation. Native `ubuntu-latest` + `ubuntu-24.04-arm` joined with
`docker buildx imagetools create` is the upgrade, free on a public repo. The
distribution itself is always built on amd64 on purpose — it embeds one
arch-specific `brotli4j` native jar chosen by OS-activated Maven profiles that
cannot be overridden from the command line, and upstream builds on amd64 too.

## Security posture

This is a **public fork that carries all of upstream's workflows on every
`*_crdb` branch**, including two `pull_request_target` ones — the trigger that
runs in *this* repo's context, with secrets, from a PR opened by anyone.
`setup-repo.sh` disables every workflow whose path is not
`.github/workflows/p2-*`, but *disabling is per path*, so a workflow upstream
adds later arrives enabled.

Because a denylist cannot be relied on to stay current, **credentials live in
environments, not in repo or organization secrets**:

| environment | holds | readable by |
|---|---|---|
| `agent` | `ANTHROPIC_API_KEY` | the `port` job of `p2-crdb-release` |
| `publish` | `QUAY_USERNAME`, `QUAY_ROBOT_TOKEN` | the jobs that push images |

Both are pinned by deployment branch policy to `p2-ci`. Only a job that declares
the environment can read its secrets, and only when running on that branch — so
an upstream workflow satisfies neither condition, and `toJSON(secrets)` returns
nothing useful to it. There are deliberately **no repo-wide or org-granted
secrets on this repository**; keep it that way.

Consequences to respect:

- A new job that needs to push an image must declare `environment: publish`, or
  the registry login will fail with empty credentials.
- Don't add `secrets: inherit` to a reusable-workflow call. Environment secrets
  are resolved per job by the job that declares the environment; passing things
  down a call chain is what we are deliberately not doing.
- Still re-run `p2/scripts/setup-repo.sh` after any upstream sync and treat "a
  new non-`p2-*` workflow is active" as a finding. Environments remove the
  secret-exfiltration risk, not the wasted-CI-minutes one.

## Layout

`README.md` has the full table. The short version: `.github/workflows/p2-*.yml`
are the workflows, `.github/actions/keycloak-dist` builds or downloads the
distribution, `p2/config.sh` is all policy, `p2/scripts/` is the logic,
`p2/prompts/` is the CI agent's brief, `p2/baseline-tags.txt` is the
"don't backfill history" floor.
