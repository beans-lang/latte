#!/usr/bin/env bash
# test.sh — the gate.
#
# Every suite runs on both backends and both must print the golden file, byte
# for byte. The golden is what `beansc run` produced when the suite was
# written; the native binary is diffed against the same file, never against
# the interpreter's fresh output.
#
# The two legs are not redundant. Nearly every compiler fault this workspace
# has found showed up as one backend disagreeing with the other — a List
# stride, an Option compared by address, a struct equality that was silently
# false natively. An interpreter-only gate would have caught none of them.
#
#   ./test.sh              both legs, every suite
#   ./test.sh --interp     the interpreter only (fast; what an edit loop wants)
#   ./test.sh diff         one suite, both legs
#   ./test.sh --wasm       the core-imports-no-I/O leg, on its own
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
if [[ -z ${BEANSC:-} ]]; then
    if [[ -n ${BEANS_ROOT:-} && -x "$BEANS_ROOT/build/beansc" ]]; then
        BEANSC="$BEANS_ROOT/build/beansc"
    else
        BEANSC=$(command -v beansc || true)
    fi
fi

if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi

# A beansc built in the tree finds its C runtime at "runtime/beans_rt.c"
# *relative to the working directory*, so building from here fails with
# "cannot find the Beans C runtime". An installed beansc knows its own prefix
# and needs none of this. The interpreter leg never touches the runtime, which
# is why an interpreter-only gate could not have told you it was missing.
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-}  && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}   && -d "$BEANS_ROOT/stdlib/std"        ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding"  ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}      && -d "$BEANS_ROOT/runtime/net"       ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}      && -d "$BEANS_ROOT/runtime/log"       ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi

# The compiler must be 0.1.40. Latte uses permessage-deflate, Deflater, and
# encode_response_head_append, none of which exist in 0.1.39, and a 0.1.39
# failure reads as a latte bug. Refuse rather than mislead.
version_line=$("$BEANSC" --version 2>/dev/null || true)
case "$version_line" in
    *"0.1.40"*) ;;
    *) echo "latte needs beansc 0.1.40; this one says: ${version_line:-<no answer>}" >&2
       echo "  build it: cd $BEANS_ROOT && rm -f build/beansc && make BEANSC_BOOT=\$HOME/.beans/bin/beansc" >&2
       exit 1 ;;
esac

# Which beansc produced this result. `--version` cannot tell you: two builds
# that differ by a real bug fix both answer "beansc 0.1.40". A green whose
# author you cannot name is not evidence.
compiler_line() {
    local real="$BEANSC"
    [[ -x "${BEANSC}.real" ]] && real="${BEANSC}.real"
    local id
    id=$(shasum -a 256 "$real" 2>/dev/null | cut -c1-12)
    [[ -n "$id" ]] || id="unhashable"
    printf '%s (%s)' "$BEANSC" "$id"
}

native=1
wasm_only=0
only=""
for arg in "$@"; do
    case "$arg" in
        --interp) native=0 ;;
        --wasm)   wasm_only=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) only="$arg" ;;
    esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failed=0
suites=0
legs=0
skipped=0

# --- the core-imports-no-I/O leg -----------------------------------------
# The core (frames, builder, serializer, differ) must import nothing that
# needs an operating system, because that is the whole reason a WebAssembly
# render mode stays possible (PLAN.md, D4). A build for
# wasm32-unknown-unknown is the check: std.fs or std.net in the core fails it.
# It is stated here rather than reviewed, because a review does not run.
run_wasm_leg() {
    local probe="$ROOT/tests/_wasm_core.b"
    if [[ ! -f "$probe" ]]; then
        echo "SKIP wasm-core: tests/_wasm_core.b does not exist yet (W1 writes it)"
        skipped=$((skipped + 1))
        return 0
    fi
    if (cd "$ROOT" && "$BEANSC" build --target wasm32-unknown-unknown "$probe" \
            -o "$tmp/wasm_core.wasm") >"$tmp/wasm.log" 2>&1; then
        echo "ok wasm-core — the core builds for wasm32-unknown-unknown, so it imports no I/O"
    else
        echo "--- wasm-core FAILED: the core no longer builds without an OS ---" >&2
        echo "    something under the module root grew an I/O import. See PLAN.md, D4." >&2
        cat "$tmp/wasm.log" >&2
        failed=1
    fi
}

if [[ $wasm_only -eq 1 ]]; then
    run_wasm_leg
    [[ $failed -eq 0 ]] || { echo "latte: FAILED" >&2; exit 1; }
    exit 0
fi

shopt -s nullglob
for case in "$ROOT"/tests/*.b; do
    name=$(basename "$case" .b)
    # Scratch drivers are allowed in tests/ and are not gated: a name starting
    # with "_" or "probe" is a probe, not a suite.
    case "$name" in _*|probe*) continue ;; esac
    if [[ -n "$only" && "$name" != "$only" ]]; then continue ; fi
    want="$ROOT/tests/$name.out"
    if [[ ! -f "$want" ]]; then
        echo "no golden file for $name" >&2
        failed=1
        continue
    fi
    suites=$((suites + 1))

    # --- the interpreter -------------------------------------------------
    if ! (cd "$ROOT" && "$BEANSC" run "$case") >"$tmp/$name.interp" 2>"$tmp/$name.err"; then
        echo "--- $name failed to run under the interpreter ---" >&2
        cat "$tmp/$name.err" >&2
        failed=1
        continue
    fi
    if diff -u "$want" "$tmp/$name.interp"; then
        legs=$((legs + 1))
    else
        echo "--- $name: interpreter output differs from the golden ---" >&2
        failed=1
    fi

    [[ $native -eq 1 ]] || continue

    # --- the native binary -----------------------------------------------
    # Built and run from ROOT: a suite that opens a file names it relative to
    # the module root, and a binary run from elsewhere would fail for a reason
    # that has nothing to do with the backend.
    if ! (cd "$ROOT" && "$BEANSC" build "$case" -o "$tmp/$name.bin") >"$tmp/$name.build" 2>&1; then
        echo "--- $name failed to build natively ---" >&2
        cat "$tmp/$name.build" >&2
        failed=1
        continue
    fi
    if ! (cd "$ROOT" && "$tmp/$name.bin") >"$tmp/$name.native" 2>"$tmp/$name.nerr"; then
        echo "--- $name failed to run natively ---" >&2
        cat "$tmp/$name.nerr" >&2
        failed=1
        continue
    fi
    if diff -u "$want" "$tmp/$name.native"; then
        legs=$((legs + 1))
    else
        echo "--- $name: NATIVE output differs from the golden ---" >&2
        echo "    the two backends disagree; that is a compiler fault until" >&2
        echo "    proven otherwise. See RULES.md." >&2
        failed=1
    fi
done

[[ -n "$only" ]] || run_wasm_leg

if [[ $suites -eq 0 && -n "$only" ]]; then
    echo "no suite matched \"$only\"" >&2
    exit 1
fi
if [[ $failed -ne 0 ]]; then
    echo "latte: FAILED" >&2
    exit 1
fi

# Say what was skipped. A gate that skips on a missing input dies silently
# when the layout moves, and then everything is green forever (RULES.md 5).
note=""
[[ $skipped -gt 0 ]] && note=" — $skipped leg(s) SKIPPED, read the SKIP lines above"
if [[ $suites -eq 0 ]]; then
    echo "latte: no suites yet — the tree is scaffolding${note}"
elif [[ $native -eq 1 ]]; then
    echo "ok latte — $suites suites, $legs legs (interpreter + native), all byte-identical to the goldens${note}"
else
    echo "ok latte — $suites suites, interpreter only (--interp); the native leg did not run${note}"
fi
echo "   beansc: $(compiler_line)"
