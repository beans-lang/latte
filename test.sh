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
# The component-type leg stages two generated files inside tests/, because a
# generated file has to sit in the latte module for `import … from latte` to
# resolve. It removes them on every path it returns on; the trap is for the run
# that is interrupted between the two, so a Ctrl-C never leaves a .b file in
# tests/ that nobody wrote. .gitignore lists them as well.
W2_COMPONENT_STAGED=("$ROOT/tests/_w2_component_ok.b" "$ROOT/tests/_w2_component_bad.b")
trap 'rm -rf "$tmp"; rm -f "${W2_COMPONENT_STAGED[@]}"' EXIT

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

# --- the component-type leg ----------------------------------------------
#
# latte-bx cannot type-check. So a `<Tag>` whose type is not a `Component` is
# refused by **beansc**, against a free function latte-bx emits once per
# distinct component tag:
#
#     fn _latte_component_<stem>_<Tag>(value: Tag) -> Component { return value }
#
# `Builder.component<T>` puts no bound on `T` — it activates through reflection
# and pushes "X is not a Component" onto `faults` at run time — so that free
# function is the only place the mistake is caught before the page ships. It is
# also the one refusal in bx/'s list that no Beans suite can run: the answer is
# the real compiler's, and nothing in the stdlib reads an environment variable,
# so tests/markup_refusals.b cannot find beansc. It runs here, where $BEANSC is
# already resolved.
#
# **Both halves or nothing.** `component_ok.bx` and `component_bad.bx` are one
# file with `extends Component` struck off two classes and nothing else changed.
# The good one must check CLEAN; the bad one must fail with the upcast error and
# with no other error. A leg holding only the bad half goes green the day
# `latte-bx build` breaks for an unrelated reason — a generator that refuses
# everything makes "it did not check" read as success. RULES.md, "The refusal
# that never runs".
#
# Nothing here SKIPs. A missing fixture is a failure, not a shrug: a leg that
# skips on a missing input dies silently the day the layout moves (RULES.md 5).
run_component_type_leg() {
    local missing=0
    local half
    for half in ok bad; do
        [[ -f "$ROOT/tests/w2cases/component_$half.bx" ]] && continue
        echo "--- component-type FAILED: tests/w2cases/component_$half.bx is missing ---" >&2
        missing=1
    done
    if [[ $missing -ne 0 ]]; then
        echo "    the leg needs both halves; with one it proves nothing. See RULES.md," >&2
        echo "    \"The refusal that never runs\"." >&2
        failed=1
        return 0
    fi

    # The tree interpreter always generates. The native binary generates too
    # unless --interp, and then the two outputs must be byte-identical: without
    # that, the check below is reading whichever backend this run happened to
    # use, and RULES.md 3 is the rule most bugs in this workspace have broken.
    local how="the tree interpreter"
    if [[ $native -eq 1 ]]; then
        # The real binary, built and run. The `examples` block above only
        # *checks* latte_bx.b, and a CLI that checks but does not link is
        # still broken.
        if ! (cd "$ROOT" && "$BEANSC" build examples/latte_bx.b -o "$tmp/latte-bx") >"$tmp/latte_bx.build" 2>&1; then
            echo "--- component-type FAILED: latte-bx does not build ---" >&2
            cat "$tmp/latte_bx.build" >&2
            failed=1
            return 0
        fi
        how="both backends, byte-identical"
    fi

    # The generated file has to sit inside the latte module or `import … from
    # latte` is "unknown package 'latte' — local packages need a beans.pot".
    # tests/ is an entry directory and the suite loop skips a name starting
    # with "_", so these two are scratch that beansc can still resolve. They
    # are removed on the way out and are in .gitignore for the runs that die
    # before they get there.
    rm -f "${W2_COMPONENT_STAGED[@]}"
    for half in ok bad; do
        if ! (cd "$ROOT" && "$BEANSC" run examples/latte_bx.b -- build \
                "tests/w2cases/component_$half.bx" -o "$tmp/component_$half.interp.b") \
                >"$tmp/gen_$half.log" 2>&1; then
            echo "--- component-type FAILED: latte-bx refused component_$half.bx ---" >&2
            echo "    both fixtures must COMPILE. The difference between them is beansc's" >&2
            echo "    to find, not latte-bx's." >&2
            cat "$tmp/gen_$half.log" >&2
            failed=1
            rm -f "${W2_COMPONENT_STAGED[@]}"
            return 0
        fi
        if [[ $native -eq 1 ]]; then
            if ! (cd "$ROOT" && "$tmp/latte-bx" build "tests/w2cases/component_$half.bx" \
                    -o "$tmp/component_$half.native.b") >"$tmp/gen_${half}_native.log" 2>&1; then
                echo "--- component-type FAILED: the native latte-bx refused component_$half.bx ---" >&2
                cat "$tmp/gen_${half}_native.log" >&2
                failed=1
                rm -f "${W2_COMPONENT_STAGED[@]}"
                return 0
            fi
            if ! cmp -s "$tmp/component_$half.interp.b" "$tmp/component_$half.native.b"; then
                echo "--- component-type FAILED: the backends generate different Beans for component_$half.bx ---" >&2
                echo "    that is a compiler fault until proven otherwise. See RULES.md 3." >&2
                diff -u "$tmp/component_$half.interp.b" "$tmp/component_$half.native.b" >&2 || true
                failed=1
                rm -f "${W2_COMPONENT_STAGED[@]}"
                return 0
            fi
        fi
        cp "$tmp/component_$half.interp.b" "$ROOT/tests/_w2_component_$half.b"

        # One assertion per DISTINCT tag. Each fixture names Card twice and
        # Card, Widget and Panel once each, so three is the answer that says
        # `note_component` deduplicates AND that every tag reaches it —
        # including the one inside a `$if` arm. Nought would leave beansc
        # nothing to refuse and the halves below nothing to prove.
        local asserts
        asserts=$(grep -c '^fn _latte_component_' "$ROOT/tests/_w2_component_$half.b" || true)
        if [[ "$asserts" != "3" ]]; then
            echo "--- component-type FAILED: component_$half.bx generated $asserts upcast assertions, wanted 3 ---" >&2
            echo "    one per distinct component tag: Card, Widget, Panel." >&2
            grep -n '_latte_component_' "$ROOT/tests/_w2_component_$half.b" >&2 || true
            failed=1
            rm -f "${W2_COMPONENT_STAGED[@]}"
            return 0
        fi
    done

    # The positive control. Every tag IS a Component, so the file checks clean.
    if ! (cd "$ROOT" && "$BEANSC" check tests/_w2_component_ok.b) >"$tmp/component_ok.check" 2>&1; then
        echo "--- component-type FAILED: the POSITIVE control does not check ---" >&2
        echo "    component_ok.bx names three real Components. Generated Beans that beansc" >&2
        echo "    refuses here means the other half is being refused for the wrong reason," >&2
        echo "    and the leg is decoration." >&2
        cat "$tmp/component_ok.check" >&2
        failed=1
        rm -f "${W2_COMPONENT_STAGED[@]}"
        return 0
    fi

    # The refusal. Three tags, none of them a Component; beansc must say so
    # about each one, and about nothing else.
    if (cd "$ROOT" && "$BEANSC" check tests/_w2_component_bad.b) >"$tmp/component_bad.check" 2>&1; then
        echo "--- component-type FAILED: a <Tag> that is not a Component was ACCEPTED ---" >&2
        echo "    tests/_w2_component_bad.b names Card, Widget and Panel and none of them" >&2
        echo "    extends Component. beansc checked it clean, so the upcast assertion in" >&2
        echo "    bx/compile.b is no longer doing anything and a page with a mistyped tag" >&2
        echo "    ships as a blank subtree and a runtime fault." >&2
        cat "$tmp/component_bad.check" >&2
        failed=1
        rm -f "${W2_COMPONENT_STAGED[@]}"
        return 0
    fi
    local errors upcasts
    errors=$(grep -c 'error:' "$tmp/component_bad.check" || true)
    upcasts=$(grep -cE 'error: expected latte\.Component, got [^ ]*\.(Card|Widget|Panel)$' "$tmp/component_bad.check" || true)
    if [[ "$upcasts" != "3" || "$errors" != "3" ]]; then
        echo "--- component-type FAILED: the bad file was refused for the wrong reason ---" >&2
        echo "    wanted exactly three 'expected latte.Component, got …' errors — one each" >&2
        echo "    for Card, Widget and Panel — and no others; got $errors error(s), of" >&2
        echo "    which $upcasts were upcasts. A refusal that fires on a different fault" >&2
        echo "    is not the one this leg is for." >&2
        cat "$tmp/component_bad.check" >&2
        failed=1
        rm -f "${W2_COMPONENT_STAGED[@]}"
        return 0
    fi

    rm -f "${W2_COMPONENT_STAGED[@]}"
    echo "ok component-type — a <Tag> that is not a Component is refused by beansc, 3 tags each; one that is checks clean ($how)"
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


# --- the refusal-coverage leg --------------------------------------------
#
# Every `self.faults.push(...)` in builder.b must have a case in tests/frames.b
# § 13 — a trip with the exact fault text, a positive control that must be
# accepted, and a name the deletion pass can map back to the site.
#
# § 13 already asserts that IT reached 24 distinct sites. What it cannot see is
# builder.b growing a 25th, because a refusal nothing feeds raises nothing and
# is counted by nobody. So this compares the two numbers, and it is the whole
# reason a new refusal cannot be added here and quietly go untested — the
# failure mode RULES.md calls "the refusal that never runs", which in this repo
# has already produced one control that could not fire and one that never ran.
#
# Nothing here SKIPs. Both inputs are files in this repo; if either is missing
# or shaped differently, the audit has moved and that is a failure, not a shrug.
run_refusal_coverage_leg() {
    local source="$ROOT/builder.b"
    local recorded="$ROOT/tests/frames.out"
    if [[ ! -f "$source" || ! -f "$recorded" ]]; then
        echo "--- refusal-coverage FAILED: builder.b or tests/frames.out is missing ---" >&2
        failed=1
        return 0
    fi

    local sites listed
    sites=$(grep -c 'self\.faults\.push' "$source" || true)
    # The tally § 13 prints, one line per distinct site, between its header and
    # the assertion that closes it.
    listed=$(awk '/^-- the sites, and how many shapes reach each$/ {on=1; next}
                  /^ok every fault site in builder\.b has a case$/ {on=0}
                  on && /^   [0-9]+x /  {n++}
                  END {print n + 0}' "$recorded")

    if [[ "$listed" -eq 0 ]]; then
        echo "--- refusal-coverage FAILED: tests/frames.out has no site tally ---" >&2
        echo "    § 13 of tests/frames.b prints one line per fault site it reached." >&2
        echo "    An empty tally means the audit moved and this leg is now blind." >&2
        failed=1
        return 0
    fi
    if [[ "$sites" -ne "$listed" ]]; then
        echo "--- refusal-coverage FAILED: builder.b has $sites report sites, the audit covers $listed ---" >&2
        echo "    A new refusal needs a case in tests/frames.b § 13: an input that trips" >&2
        echo "    it with the exact fault text, and a positive control beside it that must" >&2
        echo "    be ACCEPTED. Then add its label to probes/delete_faults.sh, in file" >&2
        echo "    order, and run that script — a refusal whose deletion changes nothing is" >&2
        echo "    either untested or unreachable, and neither shows up in a green run." >&2
        failed=1
        return 0
    fi
    echo "ok refusal-coverage — all $sites report sites in builder.b have a case and a control"
}

# latte-bx generates, beansc refuses. Run before the suite loop, because the leg
# stages two scratch files in tests/ and removes them again, and the loop globs
# that directory. Skipped only when a single suite was named, like the wasm leg.
[[ -n "$only" ]] || run_component_type_leg

# Reads two files and always runs, even for a single named suite: a check that
# cannot be skipped cannot rot.
run_refusal_coverage_leg

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
