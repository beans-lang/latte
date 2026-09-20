#!/usr/bin/env bash
# Does `latte init` write a project that `latte build` actually builds?
#
# Everything the command line decides without touching a disk is in
# tests/cli.b, which runs on both backends. This is the other half and it can
# only be a script: it scaffolds both targets into a scratch directory and
# builds them for real, so a template with a bad import, a manifest row the
# compiler refuses, or a wasm flag that stopped being passed fails here rather
# than in somebody's new project.
#
# It builds against THIS checkout — `init --latte` writes path rows — because
# what is being checked is the tree, not the last published release.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
BEANSC=${BEANSC:-${BEANS_ROOT:+$BEANS_ROOT/build/beansc}}
BEANSC=${BEANSC:-$(command -v beansc || true)}
if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-} && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}  && -d "$BEANS_ROOT/stdlib/std"        ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding" ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}     && -d "$BEANS_ROOT/runtime/net"       ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}     && -d "$BEANS_ROOT/runtime/log"       ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi
export BEANSC

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

latte="$ROOT/build/latte"
"$BEANSC" build "$ROOT/examples/latte_cli.b" -o "$latte" >"$tmp/build.log" 2>&1 || {
    echo "--- cli FAILED: the binary did not build ---" >&2
    cat "$tmp/build.log" >&2
    exit 1
}
echo "ok cli/binary — examples/latte_cli.b builds"

status=0
note() { echo "--- cli FAILED: $1 ---" >&2; status=1; }

# --- one target, from nothing to an artifact ---------------------------
one_target() {
    local target=$1 name=$2 artifact=$3
    local work="$tmp/$target"
    mkdir -p "$work"
    (cd "$work" && "$latte" init "$name" --target "$target" --latte "$ROOT") \
        >"$tmp/$target-init.log" 2>&1 || {
        note "'latte init --target $target' refused"
        cat "$tmp/$target-init.log" >&2
        return 0
    }
    # generated/ is NOT written by init: the first build writes it, and a
    # scaffolder that wrote it too would be a second mirror rule.
    if [[ -d "$work/$name/generated" ]]; then
        note "init wrote generated/, which is the build's to write"
        return 0
    fi
    (cd "$work/$name" && "$latte" build) >"$tmp/$target-build.log" 2>&1 || {
        note "'latte build' refused a project 'latte init --target $target' wrote"
        cat "$tmp/$target-build.log" >&2
        return 0
    }
    if [[ ! -f "$work/$name/$artifact" ]]; then
        note "the $target build wrote no $artifact"
        return 0
    fi
    # And it is regenerated from the markup, not left where init put it.
    if [[ ! -f "$work/$name/generated/site/shell.b" ]]; then
        note "the $target build generated no shell.b from shell.bx"
        return 0
    fi
    # A second build must be a no-op for the markup: a generator that rewrote
    # every file identically would make every build a full rebuild.
    (cd "$work/$name" && "$latte" build) >"$tmp/$target-build2.log" 2>&1 || {
        note "the second $target build refused"
        return 0
    }
    if ! grep -q "generated 0 file" "$tmp/$target-build2.log"; then
        if grep -q "generated .* file" "$tmp/$target-build2.log"; then
            note "the second $target build regenerated markup that had not changed"
            cat "$tmp/$target-build2.log" >&2
            return 0
        fi
    fi
    # The drift check must agree with what the build just wrote.
    (cd "$work/$name" && "$latte" check --drift) >"$tmp/$target-drift.log" 2>&1 || {
        note "'latte check --drift' calls a freshly built $target project stale"
        cat "$tmp/$target-drift.log" >&2
        return 0
    }
    echo "ok cli/$target — init, build, $artifact, and no drift"
}

one_target html shopfront build/debug/shopfront
one_target canvas drawpad build/debug/drawpad.wasm

# The canvas build's other half: a page and everything it asks for. A module
# with no page is not an application, and every one of these is a 404 that
# would show as a blank canvas with nothing in the console about the cause.
canvas_out="$tmp/canvas/drawpad/build/debug"
if [[ -d "$canvas_out" ]]; then
    for wanted in index.html canvaskit/canvaskit.js canvaskit/canvaskit.wasm \
                  latte/latte-page.js latte/latte-runtime.js latte/latte-canvaskit.js \
                  latte/latte-semantics.js latte/latte-editing.js latte/latte-input.js \
                  latte/latte-link.js latte/latte-floats.js fonts/latte-regular.ttf; do
        [[ -f "$canvas_out/$wanted" ]] || note "the canvas build staged no $wanted"
    done
    # Every script the page imports has to be one of the staged ones. A module
    # latte grew and this list did not is a 404 in the browser and nothing here.
    while IFS= read -r imported; do
        [[ -f "$canvas_out/latte/$imported" ]] || \
            note "the page's latte/$imported was not staged — add it to cli/assets.b"
    done < <(grep -ohE 'from "\./[a-z-]+\.js"' "$canvas_out"/latte/*.js 2>/dev/null |
             sed 's|from "\./||; s|"||' | sort -u)
    [[ $status -eq 0 ]] && echo "ok cli/page — the page and every module it imports are staged"
fi

# --- the refusals ------------------------------------------------------
#
# Each with the accepted case beside it above: without that, a tool that refused
# everything would pass this section. And each asserts its OWN message, because
# a refusal that fires earlier for a different reason looks identical to the one
# being checked — `init html/shopfront` refuses the *name*, never reaching the
# "already there" it was written to cover.
refuses() {
    local what=$1 where=$2 saying=$3; shift 3
    if (cd "$where" && "$@") >"$tmp/refusal.log" 2>&1; then
        note "$what was ACCEPTED"
        return 0
    fi
    if ! grep -qF "$saying" "$tmp/refusal.log"; then
        note "$what was refused, but for another reason"
        echo "    wanted: $saying" >&2
        sed 's/^/    got:    /' "$tmp/refusal.log" >&2
        return 0
    fi
    echo "ok cli/refuses — $what"
}
mkdir -p "$tmp/empty"
refuses "a name that cannot be a module" "$tmp" \
    "cannot be a module name" "$latte" init 9lives
refuses "init over a project that is already there" "$tmp/html" \
    "beans.pot is already there" "$latte" init shopfront
refuses "a target latte has not" "$tmp" \
    "is not a target" "$latte" init newthing --target svg
refuses "an option latte has not" "$tmp" \
    "is not an option latte has" "$latte" build --fast
refuses "a build with no project above it" "$tmp/empty" \
    "no beans.pot here or above" "$latte" build
refuses "markup no folder covers" "$tmp/canvas/drawpad" \
    "is outside every markup folder" sh -c \
    'mkdir -p parts && cp site/shell.bx parts/stray.bx && "$0" generate; s=$?; rm -rf parts; exit $s' "$latte"

exit $status
