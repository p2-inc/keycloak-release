#!/usr/bin/env bash
#
# Every check that can run without a GitHub runner, a Quay credential, or a
# thirty-minute Maven build. This is what CI runs on this branch, and what to run
# before pushing a change to any of it.
#
# Optional extras, skipped unless the tool is on PATH:
#   - shellcheck: bash bugs in the scripts
#   - actionlint: workflow syntax, expressions, and contexts
#
# Usage:
#   p2/scripts/test-all.sh
#
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT" || exit 1

FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[90mskip\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "bash syntax"
for f in p2/scripts/*.sh p2/config.sh; do
    if out=$(bash -n "$f" 2>&1); then ok "$f"; else bad "$f"; echo "$out" | sed 's/^/       /'; fi
done

head_ "python syntax"
for f in p2/scripts/*.py; do
    if out=$(python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f" 2>&1); then
        ok "$f"; else bad "$f"; echo "$out" | sed 's/^/       /'; fi
done

head_ "executables are executable"
# lib.sh and config.sh are sourced, never run, so they are deliberately not
# executable -- marking them so would invite someone to execute them.
for f in p2/scripts/*.sh p2/scripts/*.py; do
    case "$(basename "$f")" in lib.sh) continue ;; esac
    [ -x "$f" ] && ok "$f" || bad "$f is not executable (chmod +x)"
done
for f in p2/scripts/lib.sh p2/config.sh; do
    [ -x "$f" ] && bad "$f is executable but is a sourced library" || ok "$f is not executable (correct)"
done

head_ "YAML parses"
if python3 -c 'import yaml' 2>/dev/null; then
    for f in .github/workflows/*.yml .github/actions/*/action.yml p2/docker/*.yml; do
        [ -f "$f" ] || continue
        if out=$(python3 -c "import yaml,sys;yaml.safe_load(open(sys.argv[1]))" "$f" 2>&1); then
            ok "$f"; else bad "$f"; echo "$out" | sed 's/^/       /'; fi
    done
else
    skip "pyyaml not installed"
fi

head_ "shellcheck"
if command -v shellcheck >/dev/null; then
    if out=$(shellcheck -x -S warning -e SC1091 p2/scripts/*.sh p2/config.sh 2>&1); then
        ok "no warnings"; else bad "warnings found"; echo "$out" | sed 's/^/       /'; fi
else
    skip "shellcheck not on PATH"
fi

head_ "actionlint"
if command -v actionlint >/dev/null; then
    args=()
    command -v shellcheck >/dev/null && args=(-shellcheck "$(command -v shellcheck)")
    if out=$(actionlint "${args[@]+"${args[@]}"}" 2>&1) && [ -z "$out" ]; then
        ok "no findings"; else bad "findings"; echo "$out" | sed 's/^/       /'; fi
else
    skip "actionlint not on PATH"
fi

head_ "config and library load"
if out=$(bash -c '. p2/scripts/lib.sh; [ -n "$CRDB_IMAGE" ] && [ -n "$VANILLA_IMAGE" ]' 2>&1); then
    ok "lib.sh sources and config is populated"
else
    bad "lib.sh failed to load"; echo "$out" | sed 's/^/       /'
fi

head_ "version helpers"
run_case() {
    local desc=$1 expect=$2 got
    got=$(bash -c ". p2/scripts/lib.sh 2>/dev/null; $3" 2>&1)
    [ "$got" = "$expect" ] && ok "$desc" || bad "$desc (want '$expect', got '$got')"
}
run_case "stream_of 26.7.2"          "26.7"    'stream_of 26.7.2'
run_case "stream_of 27.0.0"          "27.0"    'stream_of 27.0.0'
run_case "version_max sorts numerically" "26.10.0" 'printf "26.9.0\n26.10.0\n26.7.2\n" | version_max'
run_case "version_lt 26.9.0 26.10.0" "yes"     'version_lt 26.9.0 26.10.0 && echo yes || echo no'
run_case "version_lt 26.10.0 26.9.0" "no"      'version_lt 26.10.0 26.9.0 && echo yes || echo no'
run_case "version_lt equal"          "no"      'version_lt 26.9.0 26.9.0 && echo yes || echo no'
run_case "is_release_tag accepts"    "yes"     'is_release_tag 26.7.2 && echo yes || echo no'
run_case "is_release_tag rejects rc" "no"      'is_release_tag 26.8.0-rc1 && echo yes || echo no'
run_case "is_release_tag rejects Final" "no"   'is_release_tag 4.8.3.Final && echo yes || echo no'
run_case "in_list space-separated"   "yes"     'in_list 26.4 "26.2 26.4" && echo yes || echo no'
run_case "in_list newline-separated" "yes"     'in_list 26.4 "$(printf "26.2\n26.4")" && echo yes || echo no'
run_case "in_list no substring match" "no"     'in_list 6.4 "26.2 26.4" && echo yes || echo no'
# assert_version rejects by exiting, so each call needs its own subshell.
run_case "assert_version accepts a real version" "accepted" \
    '( assert_version "26.7.2" ) 2>/dev/null && echo accepted || echo rejected'
run_case "assert_version rejects a shell injection" "rejected" \
    '( assert_version "26.7.2; rm -rf /" ) 2>/dev/null && echo accepted || echo rejected'
run_case "assert_version rejects a path traversal" "rejected" \
    '( assert_version "../../etc/passwd" ) 2>/dev/null && echo accepted || echo rejected'
run_case "assert_version rejects a command substitution" "rejected" \
    '( assert_version "26.7.2\$(id)" ) 2>/dev/null && echo accepted || echo rejected'
run_case "assert_version rejects empty" "rejected" \
    '( assert_version "" ) 2>/dev/null && echo accepted || echo rejected'

head_ "scope policy suite"
if out=$(p2/scripts/test-detect.sh 2>&1); then
    ok "$(printf '%s' "$out" | tail -1)"
else
    bad "policy suite"; printf '%s\n' "$out" | grep -E "FAIL|passed" | sed 's/^/       /'
fi

head_ "baseline"
if [ -f p2/baseline-tags.txt ]; then
    n=$(grep -cvE '^\s*(#|$)' p2/baseline-tags.txt || true)
    [ "${n:-0}" -gt 50 ] && ok "$n tags recorded" \
        || bad "only ${n:-0} tags in the baseline -- the first poll would try to build history"
else
    bad "p2/baseline-tags.txt is missing"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mall checks passed\033[0m\n'
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$FAIL"
fi
exit $((FAIL > 0))
