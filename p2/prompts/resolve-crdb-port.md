# Finish the CockroachDB port of Keycloak $VERSION

You are completing a mechanical port that got as far as it could on its own.
The Keycloak checkout is at `./src`; work there. Everything else in the
workspace is automation — do not modify it.

## Context

`p2-inc/keycloak` is a fork of Keycloak that publishes one branch per upstream
tag, `<version>_crdb`, carrying a patch that makes Keycloak run on CockroachDB.
Each branch is **exactly one commit on top of its tag**, so porting to a new
release is a cherry-pick of that commit. `p2/scripts/port-crdb.sh` has already:

- created branch `${VERSION}_crdb` at tag `$VERSION`
- cherry-picked `${BASE}_crdb` onto it, with `--no-commit`
- discarded the generated `openapi.yaml`/`.json` (build output — it must **not**
  come back into the patch)
- regenerated `rolling-upgrades-supported-changes.json`
- updated the `docker-compose.yml` image tag

Two things may be left for you. You may have one, both, or neither.

## Task 1: unresolved merge conflicts

$CONFLICT_SECTION

These are upstream drift in the ~10 files the patch touches. Resolve each one so
that **both** intents survive: upstream's change for this release, and the
CockroachDB patch's addition. The patch is almost entirely additive — it adds a
`COCKROACH` enum constant, some property mappers, a changelog switch — so the
usual correct resolution is to keep upstream's new code *and* re-apply our
addition alongside it, not to choose a side.

Use `git log`, `git show $BASE..${BASE}_crdb -- <file>` and
`git diff $BASE $VERSION -- <file>` to see exactly what each side did. That
second command is the one that tells you what upstream changed and why the
conflict exists.

Do not resolve a conflict by deleting our side. If our addition genuinely no
longer applies — upstream implemented it themselves, or removed the extension
point — say so explicitly in your final report rather than silently dropping it.

## Task 2: changelogs this release added

$GAP_SECTION

`model/jpa/src/main/resources/META-INF/jpa-changelog-master-crdb.xml` is our
parallel Liquibase include list. Liquibase picks it instead of
`jpa-changelog-master.xml` when the database is a `CockroachDatabase` (see
`LiquibaseJpaUpdaterProvider.CHANGELOG_CRDB` and the `instanceof` in
`DefaultLiquibaseConnectionProvider`). For every changelog upstream includes,
ours names either the same file or a `-crdb` variant.

When a release adds a changelog, decide which:

**If every changeSet in it is CockroachDB-safe** — add
`<include file="META-INF/jpa-changelog-<v>.xml"/>` to `master-crdb.xml` in the
same position it holds upstream. That is the common case and the right default;
do not create a variant you don't need.

**If some changeSet is not** — copy upstream's whole changelog to
`jpa-changelog-<v>-crdb.xml`, fix the offending changeSets, and include the
variant *instead of* upstream's file. Conventions, all of which you can verify
against the existing variants:

- **Copy the entire changelog, not just the divergent changeSets.** The variant
  replaces upstream's file wholesale, so anything you omit never runs.
- **Suffix every changeSet id with `-crdb`.** All 22 ids in
  `jpa-changelog-26.7.0-crdb.xml` are `<upstream-id>-crdb`. Ids must stay unique
  across the whole changelog set.
- **Record why at the top of the file, and above each changed changeSet** —
  what CockroachDB does instead, and ideally the upstream CockroachDB issue
  number. `jpa-changelog-26.7.0-crdb.xml` is the model to follow here.

### Known CockroachDB incompatibilities

Grounded in the four variants that already exist — read them before deciding:

- **Dropping and re-adding a primary key as separate statements** is
  unimplemented (cockroachdb#48026: *"primary key dropped without subsequent
  addition of new primary key in same transaction"*). Use
  `ALTER TABLE ... ALTER PRIMARY KEY USING COLUMNS (...)` in a `<sql>` element.
  Precedent: `26.7.0-9686-dynamic-scopes-consent-crdb`. Note the two
  consequences documented there: CockroachDB keeps the old key columns as a
  non-unique secondary index, and names the result `<table>_pkey` rather than
  the constraint name upstream chose.
- **`dbms` preconditions and `modifySql` blocks keyed on `postgresql` do not
  fire on CockroachDB.** Liquibase's `CockroachDatabase` has its own short name,
  so a changeSet whose correctness depends on a `<modifySql dbms="postgresql">`
  rewrite will execute its *generic* SQL instead. This is a silent trap — the
  changeSet appears to apply. Precedent: `20.0.0-crdb` drops upstream's
  `GROUP_ATTRIBUTE` expression index, whose `VALUE(255)` placeholder is only
  made valid by such a rewrite.
- **`modifyDataType` narrowing an existing column** (e.g. to `TINYINT`) is not
  supported the way the other engines take it. Precedent: `21.1.0-crdb` keeps
  only the alternative changeSet and drops the `modifyDataType` one.

This list is what we have hit so far, not a complete account of CockroachDB's
DDL limits. If a new changeSet uses DDL you are unsure about, say so in your
report rather than guessing — a wrong guess here produces a broken schema that
the build will not catch.

## Rules

- Work only inside `./src`, and keep the patch minimal: touch only what the
  conflict or the changelog gap requires.
- **Do not commit, amend, or push.** `p2/scripts/finalize-crdb.sh` makes the
  commit, regenerates `rolling-upgrades-supported-changes.json` (so a changelog
  you add gets recorded automatically), and re-checks the result.
- Leave no conflict markers. Finalize refuses to commit a file containing them.
- Do not re-add `openapi.yaml` or `openapi.json`.
- Do not edit `rolling-upgrades-supported-changes.json` by hand; it is generated.
- Do not touch `.github/`, `p2/`, or anything outside `./src`.

## Verifying your work

Compile what you changed — it is much cheaper than the full build the workflow
runs next, and catches the common mistake:

```
cd src && ./mvnw -q -B -ntp -o compile -pl quarkus/config-api,quarkus/runtime,model/jpa
```

(Drop `-o` if the offline repository is missing something.) For changelog work,
`xmllint --noout <file>` confirms the XML at least parses.

## Report

Finish with a short account of: each conflict and how you resolved it; whether
you added a changelog include or a `-crdb` variant and why; and anything you
were unsure about. A human reviews this before it ships — flag doubt rather than
smoothing it over.
