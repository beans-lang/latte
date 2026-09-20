#!/usr/bin/env bash
# Does Latte build with no Cortado anywhere?
#
# Latte's canvas runtime began as a copy of Cortado's. A copy that still needed
# the thing it was copied from would be a fork with extra steps, and the way
# that happens is never deliberate: one `require path "../../cortado"` left in a
# manifest, one `#include` of a header two directories up, one generated file
# nobody regenerated. None of those fail on a machine that has both.
#
# So this builds Latte in a tree that has beans and Latte and **nothing else**:
# the working copy is exported from git — so an uncommitted file cannot make it
# pass — into a scratch directory with no sibling but the compiler, and the
# canvas suites are run there.
#
# It also greps, which the build cannot: a path that is only read at run time,
# or named in a comment as though it were a dependency, would not fail a
# compile.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
if [[ -z ${BEANS_ROOT:-} || ! -x "$BEANS_ROOT/build/beansc" ]]; then
    echo "--- isolated FAILED: no beans checkout to build against ---" >&2
    echo "    set BEANS_ROOT to one with build/beansc in it." >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-isolated.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/community-libs/latte"
# Exported from git rather than copied: an uncommitted file is not part of what
# anybody else would get, and a check that passed because of one would be
# measuring this machine.
(cd "$ROOT" && git archive HEAD) | tar -x -C "$tmp/community-libs/latte"

# The compiler, and nothing else beside it.
ln -s "$BEANS_ROOT" "$tmp/beans"

if [[ -e "$tmp/community-libs/cortado" ]]; then
    echo "--- isolated FAILED: the scratch tree has a cortado in it ---" >&2
    exit 1
fi

echo "ok isolated/tree — latte and beans, and no cortado"

# --- what the exported tree still names ---------------------------------
#
# A build cannot catch a path read at run time, or a manifest row for a
# platform this machine is not. `build/` is skipped because it is scratch and
# `docs/` and `NOTICE.md` because recording where the copy came from is the
# point.
# The pattern is a *reference*, not the word: a cortado is a coffee, and the
# examples order one. What would matter is an import, a path, a manifest row or
# a C symbol — `cortado.something`, `../cortado`, `beans-lang/cortado`,
# `cortado_host.h`.
offenders=$(cd "$tmp/community-libs/latte" && grep -rIlE \
    "cortado\.[a-z_]+|[./]cortado[/]|beans-lang/cortado|cortado_[a-z_]+\.h|require[^\n]*cortado" \
    --exclude-dir=build --exclude-dir=node_modules --exclude-dir=.git \
    --exclude=NOTICE.md --exclude=check_isolated.sh . 2>/dev/null |
    grep -v "^./docs/source-copy.md$" || true)
if [[ -n "$offenders" ]]; then
    echo "--- isolated FAILED: these files reach for cortado ---" >&2
    echo "$offenders" | sed 's/^/    /' >&2
    echo "    Only NOTICE.md and docs/source-copy.md may name it, and they record" >&2
    echo "    where the copy came from rather than reaching for it." >&2
    exit 1
fi
echo "ok isolated/names — nothing reaches for cortado"

# --- and it builds ------------------------------------------------------
cd "$tmp/community-libs/latte"
export BEANS_ROOT="$tmp/beans"
export BEANSC="$tmp/beans/build/beansc"
export BEANS_RUNTIME="$tmp/beans/runtime/beans_rt.c"
export BEANS_STDLIB="$tmp/beans/stdlib/std"
export BEANS_ENCODING="$tmp/beans/runtime/encoding"
export BEANS_NET="$tmp/beans/runtime/net"
export BEANS_LOG="$tmp/beans/runtime/log"

ran=0
for case in tests/canvas/*.b; do
    name=$(basename "$case" .b)
    case "$name" in _*) continue ;; esac
    [[ -f "tests/canvas/expected/$name.out" ]] || continue
    if ! "$BEANSC" run "$case" >"$tmp/$name.out" 2>&1; then
        echo "--- isolated FAILED: $name did not run ---" >&2
        cat "$tmp/$name.out" >&2
        exit 1
    fi
    if ! diff -u "tests/canvas/expected/$name.out" "$tmp/$name.out" >"$tmp/$name.diff"; then
        echo "--- isolated FAILED: $name differs from its expected output ---" >&2
        head -30 "$tmp/$name.diff" >&2
        exit 1
    fi
    ran=$((ran + 1))
done

if [[ $ran -eq 0 ]]; then
    echo "--- isolated FAILED: no canvas suite ran ---" >&2
    exit 1
fi
echo "ok isolated/build — $ran canvas suite(s) run in a tree with no cortado"

# The showcase too: a program rather than a suite, and the thing a person would
# actually try.
if ! "$BEANSC" check examples/showcase/main.b >"$tmp/showcase.log" 2>&1; then
    echo "--- isolated FAILED: the showcase does not check ---" >&2
    cat "$tmp/showcase.log" >&2
    exit 1
fi
echo "ok isolated/showcase — examples/showcase checks"
