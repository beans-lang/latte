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
    local negative="$ROOT/tests/_wasm_negative.b"
    if [[ ! -f "$probe" ]]; then
        echo "SKIP wasm-core: tests/_wasm_core.b does not exist yet (W1 writes it)"
        skipped=$((skipped + 1))
        return 0
    fi

    # `wasm32-unknown-unknown` has no operating system, so it needs the
    # freestanding runtime, and THAT is what refuses an OS-bound import — by
    # name, at check time: "'std.net' needs sockets, which the freestanding
    # runtime does not have". Printing is not one of the refused capabilities:
    # freestanding routes output through the embedder's `beans_host_write`
    # hook, so std.io is legal there and this leg has never been able to say
    # anything about it. What it does say is that the core imports no
    # filesystem, sockets, poller, processes or threads.
    if (cd "$ROOT" && "$BEANSC" check --target wasm32-unknown-unknown \
            --runtime freestanding "$probe") >"$tmp/wasm.log" 2>&1; then
        echo "ok wasm-core/check — the core needs no OS capability"
    else
        echo "--- wasm-core FAILED: the core no longer checks without an OS ---" >&2
        echo "    something under the module root grew an OS-bound import. See PLAN.md, D4." >&2
        cat "$tmp/wasm.log" >&2
        failed=1
        return 0
    fi

    # The negative control. Without it this leg goes green the day the refusal
    # stops working, and then it is green forever (RULES.md 5).
    if [[ ! -f "$negative" ]]; then
        echo "--- wasm-core FAILED: tests/_wasm_negative.b is missing ---" >&2
        echo "    the leg cannot tell a working refusal from a broken one without it." >&2
        failed=1
        return 0
    fi
    if (cd "$ROOT" && "$BEANSC" check --target wasm32-unknown-unknown \
            --runtime freestanding "$negative") >"$tmp/wasm_neg.log" 2>&1; then
        echo "--- wasm-core FAILED: the negative control was ACCEPTED ---" >&2
        echo "    tests/_wasm_negative.b imports std.net and std.fs and must be refused." >&2
        echo "    The whole leg proves nothing while that is true." >&2
        failed=1
        return 0
    fi
    echo "ok wasm-core/control — std.net and std.fs are still refused for wasm"

    # Real code generation for a 32-bit-pointer target with no OS, when a Clang
    # with the wasm32 backend is around. BEANS_WASM_CC names one; this is the
    # same knob beans/test/wasm.sh uses.
    local wasm_cc=${BEANS_WASM_CC:-}
    if [[ -z "$wasm_cc" ]]; then
        for candidate in /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang clang; do
            if command -v "$candidate" >/dev/null 2>&1 && \
               "$candidate" --print-targets 2>/dev/null | grep -q 'wasm32'; then
                wasm_cc="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$wasm_cc" ]]; then
        echo "SKIP wasm-core/codegen: no Clang with a wasm32 backend (set BEANS_WASM_CC)"
        skipped=$((skipped + 1))
        return 0
    fi
    if (cd "$ROOT" && "$BEANSC" build --target wasm32-unknown-unknown \
            --runtime freestanding --emit obj --cc "$wasm_cc" \
            "$probe" -o "$tmp/wasm_core.o") >"$tmp/wasm_obj.log" 2>&1; then
        echo "ok wasm-core/codegen — the core emits a wasm32 object ($wasm_cc)"
    else
        echo "--- wasm-core FAILED: the core does not emit wasm32 code ---" >&2
        cat "$tmp/wasm_obj.log" >&2
        failed=1
        return 0
    fi

    # A full link additionally needs wasm-ld, which Homebrew's llvm does not
    # ship unless the `lld` formula is installed. Say so rather than passing
    # quietly: --emit obj proves codegen, not that the module links with no
    # host symbols beyond the five `beans_host_*` hooks.
    if ! command -v "$(dirname "$wasm_cc")/wasm-ld" >/dev/null 2>&1 && \
       ! command -v wasm-ld >/dev/null 2>&1; then
        echo "SKIP wasm-core/link: no wasm-ld beside $wasm_cc (brew install lld)"
        skipped=$((skipped + 1))
        return 0
    fi
    if (cd "$ROOT" && "$BEANSC" build --target wasm32-unknown-unknown \
            --runtime freestanding --emit shared --cc "$wasm_cc" \
            "$probe" -o "$tmp/wasm_core.wasm") >"$tmp/wasm_link.log" 2>&1; then
        echo "ok wasm-core/link — the core links as a browser module"
    else
        echo "--- wasm-core FAILED: the core does not link without an OS ---" >&2
        cat "$tmp/wasm_link.log" >&2
        failed=1
    fi
}

if [[ $wasm_only -eq 1 ]]; then
    run_wasm_leg
    [[ $failed -eq 0 ]] || { echo "latte: FAILED" >&2; exit 1; }
    exit 0
fi

# The module root must CHECK, always, suites or no suites.
#
# This is here because the first latte.b shipped with `pub let version` at
# module scope — `error: expected a declaration`, it is `pub const` — and the
# gate printed "no suites yet" and exited 0 for hours. Two lanes tripped over
# it independently and each fixed it in passing. A suite-only gate says nothing
# about a package nothing imports yet, which is exactly the state a new package
# is in for its whole first day.
root_sources=("$ROOT"/*.b)
if [[ ${#root_sources[@]} -gt 0 ]]; then
    root_bad=0
    for source in "${root_sources[@]}"; do
        (cd "$ROOT" && "$BEANSC" check "$source") >"$tmp/root.log" 2>&1 && continue
        echo "--- module-root FAILED: $(basename "$source") does not check ---" >&2
        cat "$tmp/root.log" >&2
        root_bad=1
    done
    if [[ $root_bad -eq 0 ]]; then
        echo "ok module-root — all ${#root_sources[@]} .b file(s) at the module root check"
    else
        failed=1
    fi
else
    echo "SKIP module-root: no .b files at the module root yet"
    skipped=$((skipped + 1))
fi

# The build-time compiler must CHECK too. `examples/latte_bx.b` is latte-bx's
# entry — a `kind library` module may only hold a program entry under
# examples/ or tests/ — and nothing else in this gate reaches it: the suites
# import the `latte.bx` package, not the binary's main. Without this block a
# broken CLI is green.
shopt -s nullglob
example_sources=("$ROOT"/examples/*.b)
if [[ ${#example_sources[@]} -gt 0 ]]; then
    example_bad=0
    for source in "${example_sources[@]}"; do
        (cd "$ROOT" && "$BEANSC" check "$source") >"$tmp/example.log" 2>&1 && continue
        echo "--- examples FAILED: $(basename "$source") does not check ---" >&2
        cat "$tmp/example.log" >&2
        example_bad=1
    done
    if [[ $example_bad -eq 0 ]]; then
        echo "ok examples — all ${#example_sources[@]} .b file(s) under examples/ check"
    else
        failed=1
    fi
else
    echo "SKIP examples: no .b files under examples/ yet"
    skipped=$((skipped + 1))
fi

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
