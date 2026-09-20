#!/usr/bin/env bash
# Regenerates every checked-in file that latte-bx writes.
#
# Two trees today:
#
#   templates/*.bx          the canvas runtime's control templates
#     -> generated/templates/
#   examples/showcase/site/*.bx   the showcase's screens
#     -> examples/showcase/generated/site/
#
# The output is checked in and `tools/check_generated.sh` regenerates into a
# scratch directory and diffs. That is why this script exists rather than a
# line in a README: a generated file that is edited by hand, or left stale
# after its source changed, is a file whose behaviour nobody can read off the
# markup — and the only way to know is to generate it again and compare.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

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

out_root=${1:-$ROOT}
bx=${LATTE_BX:-}
if [[ -z "$bx" ]]; then
    # Built rather than interpreted: this runs over every markup file in the
    # tree and the interpreter is about twenty times slower at it.
    "$BEANSC" build examples/latte_bx.b -o "$ROOT/build/latte-bx" >/dev/null
    bx="$ROOT/build/latte-bx"
fi

generate_tree() {
    local target=$1 sources=$2 destination=$3
    shopt -s nullglob
    local files=("$ROOT/$sources"/*.bx)
    if [[ ${#files[@]} -eq 0 ]]; then
        # Not a skip. A tree named here and empty means the layout moved, and
        # a generator that shrugged would leave the drift check comparing
        # nothing against nothing forever.
        echo "--- generate FAILED: $sources has no .bx files ---" >&2
        return 1
    fi
    mkdir -p "$out_root/$destination"
    for source in "${files[@]}"; do
        local stem
        stem=$(basename "$source" .bx)
        "$bx" build --target "$target" \
            "${sources}/$(basename "$source")" \
            -o "$out_root/$destination/$stem.b"
    done
    echo "ok generate/$sources — ${#files[@]} file(s) for the $target target"
}

# Not guarded on the directory existing. A tree named here and absent means the
# layout moved, and a generator that shrugged would leave the drift check blind.
generate_tree canvas templates generated/templates
generate_tree canvas examples/showcase/site examples/showcase/generated/site
