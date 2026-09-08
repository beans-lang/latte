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
#   ./test.sh --examples   the examples leg, on its own
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
examples_only=0
only=""
for arg in "$@"; do
    case "$arg" in
        --interp) native=0 ;;
        --wasm)   wasm_only=1 ;;
        --examples) examples_only=1 ;;
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
# The examples leg stages one file per nested module under examples/, for the
# same reason and with the same promise: it is named here so an interrupted run
# cannot leave a .b file inside a shipped example module.
EXAMPLES_STAGED=()
trap 'rm -rf "$tmp"; rm -f "${W2_COMPONENT_STAGED[@]}"; [[ ${#EXAMPLES_STAGED[@]} -eq 0 ]] || rm -f "${EXAMPLES_STAGED[@]}"' EXIT

failed=0
suites=0
legs=0
skipped=0
examples_ran=0

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

# --- the examples leg ----------------------------------------------------
#
# Every example is BUILT, RUN on both backends, and diffed against a golden.
#
# It used to only `beansc check` them, and that was a hole with a name: an
# example that compiled and printed garbage was green. The examples are the
# one part of this repo a reader copies verbatim, and `check` says only that
# the types line up — it says nothing about the HTML that comes out.
#
# **The contract, per entry.** An entry is a `.b` file anywhere under
# `examples/` that declares `package main`. Non-entry files (a nested module's
# packages) are reached through the entry that imports them.
#
#   examples/<name>.b        the entry
#   examples/<name>.out      REQUIRED — its stdout, byte for byte
#   examples/<name>.err      optional — its stderr; absent means stderr must be EMPTY
#   examples/<name>.args     optional — one argument per line
#   examples/<name>.status   optional — the expected exit status; absent means 0
#
# stderr is not ignored. Latte reports a refused page on stderr, so a leg that
# watched stdout alone would call a page that printed nothing but a complaint
# a pass, as long as the complaint was silent enough to leave stdout empty.
#
# `examples/latte_bx.b` is here because a `kind library` module may only hold a
# program entry under examples/ or tests/, so latte-bx's command line has
# nowhere else to live. Its golden is its own usage text — the one part of that
# CLI nothing else in this gate reads. (The compile path is covered by the
# component-type leg, which builds the binary and runs both backends through
# it.) Its stdout golden is empty and its stderr golden is not, which is the
# shape the empty-on-both-streams refusal above exists to distinguish from.
#
# **Nothing here SKIPs, and the two ways to silence a golden gate are both
# failures:**
#
#   * A missing `.out` is a FAILURE, not a skip. A gate that skips on a
#     missing input dies silently the day the layout moves and is green for
#     ever after (RULES.md 5) — and "just don't write the golden" is the
#     cheapest way to get there.
#   * Goldens that are EMPTY on both streams are a FAILURE. That is the other
#     cheap way — `touch examples/foo.out` — and an example that prints
#     nothing cannot tell a working program from a broken one.
#
# **The summary names every entry and its golden's size**, so "3 examples ran"
# can never be read the same as "3 examples ran and one of them asserted
# nothing". RULES.md, "A green count can mean two different things".
#
# Both legs are diffed against the GOLDEN, never against each other. Two
# backends agreeing on the wrong answer is the failure a golden exists for,
# and diffing native against a fresh interpreter run would call it a pass.

# Every .b file under examples/, sorted, scratch names dropped. A name
# starting with "_" or "probe" is scratch here for the same reason it is in
# tests/.
examples_sources() {
    find "$ROOT/examples" -name '*.b' -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
        case "$(basename "$file")" in _*|probe*) continue ;; esac
        printf '%s\n' "$file"
    done
}

# One entry, one backend. Compares stdout, stderr and the exit status, each
# against the golden. Returns non-zero on a mismatch and says which stream.
compare_example_leg() {
    local rel=$1 how=$2 got_out=$3 got_err=$4 got_status=$5
    local want_out=$6 want_err=$7 want_status=$8
    local bad=0

    if [[ "$got_status" != "$want_status" ]]; then
        echo "--- examples FAILED: $rel exited $got_status under $how, wanted $want_status ---" >&2
        echo "    (an expected status other than 0 lives in $(basename "${want_out%.out}.status"))" >&2
        sed -n '1,20p' "$got_err" >&2
        bad=1
    fi
    if ! diff -u "$want_out" "$got_out" >"$tmp/example_diff" 2>&1; then
        echo "--- examples FAILED: $rel stdout differs from the golden under $how ---" >&2
        cat "$tmp/example_diff" >&2
        bad=1
    fi
    if [[ -f "$want_err" ]]; then
        if ! diff -u "$want_err" "$got_err" >"$tmp/example_diff" 2>&1; then
            echo "--- examples FAILED: $rel stderr differs from the golden under $how ---" >&2
            cat "$tmp/example_diff" >&2
            bad=1
        fi
    elif [[ -s "$got_err" ]]; then
        echo "--- examples FAILED: $rel wrote to stderr under $how, and has no .err golden ---" >&2
        echo "    An example prints its page and nothing else. If the noise is wanted," >&2
        echo "    record it in $(basename "${want_out%.out}.err"); if it is not, it is a bug" >&2
        echo "    the leg just caught." >&2
        sed -n '1,20p' "$got_err" >&2
        bad=1
    fi
    return $bad
}

# Every package of every nested module under examples/, compiled.
#
# A nested module — a directory under `examples/` with its own `beans.pot` — is
# how a component library is shipped and how a consumer of one is written, so
# `examples/` grows whole modules and not only files. Two of their shapes defeat
# the plain `beansc check` above:
#
#   * a file deeper than the manifest (`shelf/cards/card.b`) cannot be pointed
#     at directly — `error: entry file must sit next to beans.pot`;
#   * a `kind library` module may hold a program entry only under `tests/` or
#     `examples/`, so there is nowhere else to put one.
#
# So the leg writes one: a `package main` file under `<module>/tests/` that
# dot-path imports **every package directory the module has**, found by looking
# on disk and not by reading anybody's imports. An unused import still compiles
# the package — proved by breaking `shelf/atoms/badge.b` and watching this
# check name the line — so a package that nothing imports is compiled here and
# nowhere else. That is the whole point: without it, adding an orphan package
# to a shipped library is invisible, and `examples/` is the part of this repo a
# reader copies.
#
# The staged file is removed on every path, including the interrupted one — the
# EXIT trap lists it — so a Ctrl-C never leaves a .b file in a module nobody
# wrote.
examples_nested_modules() {
    find "$ROOT/examples" -name beans.pot -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r pot; do
        printf '%s\n' "$(dirname "$pot")"
    done
}

# The package directories of one module: every directory holding a .b file,
# except the module root itself (that is the root package, checked directly)
# and its `tests/` and `examples/` trees (those hold entries, not packages).
module_package_dirs() {
    local module=$1
    find "$module" -name '*.b' -type f 2>/dev/null | while IFS= read -r file; do
        printf '%s\n' "$(dirname "$file")"
    done | LC_ALL=C sort -u | while IFS= read -r dir; do
        [[ "$dir" == "$module" ]] && continue
        local rel=${dir#"$module"/}
        case "$rel" in tests|tests/*|examples|examples/*) continue ;; esac
        printf '%s\n' "$rel"
    done
}

cover_nested_modules() {
    local module
    while IFS= read -r module; do
        [[ -n "$module" ]] || continue
        local name
        name=$(awk '$1 == "module" { print $2; exit }' "$module/beans.pot")
        if [[ -z "$name" ]]; then
            echo "--- examples FAILED: ${module#"$ROOT"/}/beans.pot has no 'module' row ---" >&2
            failed=1
            continue
        fi

        local dirs=()
        local rel
        while IFS= read -r rel; do
            [[ -n "$rel" ]] && dirs+=("$rel")
        done < <(module_package_dirs "$module")

        # A module whose only .b files sit next to its manifest has no package
        # to reach this way; the loop above already checked them by name.
        [[ ${#dirs[@]} -gt 0 ]] || continue

        local staged="$module/tests/_examples_cover.b"
        mkdir -p "$module/tests"
        {
            echo "// Written by test.sh and deleted by it. It imports every package"
            echo "// directory $name has, so a package nothing imports is still compiled."
            echo "package main"
            for rel in "${dirs[@]}"; do
                echo "import $name.${rel//\//.}"
            done
            echo "fn main() {}"
        } >"$staged"
        EXAMPLES_STAGED+=("$staged")

        if ! (cd "$ROOT" && "$BEANSC" check "${staged#"$ROOT"/}") >"$tmp/cover.log" 2>&1; then
            echo "--- examples FAILED: a package of ${module#"$ROOT"/} does not check ---" >&2
            echo "    Every package directory of a nested module is compiled through a" >&2
            echo "    staged entry that imports all of them, because beansc cannot be" >&2
            echo "    pointed at a file that is not next to a beans.pot. The staged" >&2
            echo "    file was:" >&2
            sed -e 's/^/        /' "$staged" >&2
            cat "$tmp/cover.log" >&2
            failed=1
        else
            echo "ok examples/packages — ${#dirs[@]} package(s) of $name compile: ${dirs[*]}"
        fi
        rm -f "$staged"
        rmdir "$module/tests" 2>/dev/null || true
    done < <(examples_nested_modules)
}

run_examples_leg() {
    local entries=()
    local others=()
    local file
    while IFS= read -r file; do
        if grep -q '^package main' "$file"; then entries+=("$file"); else others+=("$file"); fi
    done < <(examples_sources)

    # A .b under examples/ that is NOT an entry belongs to a package some entry
    # imports. Running the entry compiles it, so this only catches the file
    # nothing imports yet — which is exactly the file a reader is most likely
    # to copy and least likely to have compiled.
    #
    # **`beansc check` can only be pointed at a file that sits next to a
    # `beans.pot`.** A file deeper inside a module answers
    # `error: entry file must sit next to beans.pot` and never reaches type
    # checking, so the loop below would report a nested library's every package
    # file as broken. That is not a reason to skip them: skipping is how this
    # guard would stop covering the files it exists for. They are covered by
    # `cover_nested_modules` instead, which stages an entry that imports every
    # package directory the module has — including one nothing imports.
    # The test is the COMPILER'S OWN answer and not a guess about the layout:
    # a file it cannot be pointed at says so in one exact sentence, and only
    # that sentence is allowed to excuse a file from this check. Deciding it
    # here by looking for a `beans.pot` beside the file would quietly skip
    # every non-entry file directly under `examples/` — latte's manifest is at
    # the repo root, not in `examples/` — and that guard would be dead the day
    # somebody adds one.
    local other
    if [[ -z "$only" ]]; then
        for other in ${others[@]+"${others[@]}"}; do
            (cd "$ROOT" && "$BEANSC" check "${other#"$ROOT"/}") >"$tmp/example_check.log" 2>&1 && continue
            if grep -q 'entry file must sit next to beans.pot' "$tmp/example_check.log"; then
                continue    # a nested module's package file; cover_nested_modules has it
            fi
            echo "--- examples FAILED: ${other#"$ROOT"/} does not check ---" >&2
            cat "$tmp/example_check.log" >&2
            failed=1
        done
        cover_nested_modules
    fi

    # --- .bx sources against the .b files checked in beside them ----------
    #
    # PLAN.md, "Shipping a library": a package ships its `.bx` sources AND the
    # Beans latte-bx generated from them, both checked in, so a consumer adds
    # one `require` row and needs no build step and no markup compiler. The
    # price of checking a generated file in is that it can go stale, and a
    # stale one is invisible — it compiles, it runs, and it renders the markup
    # somebody edited last week. So the gate regenerates and diffs.
    #
    # A `.bx` with no `.b` beside it is a FAILURE for the same reason a missing
    # golden is: the check would otherwise vanish the moment the file it
    # watches is renamed.
    if [[ -z "$only" ]]; then
        local bx
        while IFS= read -r bx; do
            local generated="${bx%.bx}.b"
            local stem; stem=$(basename "${bx%.bx}")
            if [[ ! -f "$generated" ]]; then
                echo "--- examples FAILED: ${bx#"$ROOT"/} has no generated .b beside it ---" >&2
                echo "    A .bx ships with the Beans it compiles to, checked in, so a" >&2
                echo "    consumer needs no markup compiler:" >&2
                echo "        beansc run examples/latte_bx.b -- build ${bx#"$ROOT"/} -o ${generated#"$ROOT"/}" >&2
                failed=1
                continue
            fi
            if ! (cd "$ROOT" && "$BEANSC" run examples/latte_bx.b -- build \
                    "${bx#"$ROOT"/}" -o "$tmp/bxgen_$stem.b") >"$tmp/bxgen_$stem.log" 2>&1; then
                echo "--- examples FAILED: latte-bx refused ${bx#"$ROOT"/} ---" >&2
                cat "$tmp/bxgen_$stem.log" >&2
                failed=1
                continue
            fi
            if ! diff -u "$generated" "$tmp/bxgen_$stem.b" >"$tmp/bxgen_$stem.diff" 2>&1; then
                echo "--- examples FAILED: ${generated#"$ROOT"/} is stale ---" >&2
                echo "    It no longer matches what latte-bx makes of ${bx#"$ROOT"/}." >&2
                echo "    Regenerate it and read the diff before committing." >&2
                cat "$tmp/bxgen_$stem.diff" >&2
                failed=1
                continue
            fi
            echo "ok examples/markup — ${generated#"$ROOT"/} is what latte-bx makes of ${bx#"$ROOT"/}"
        done < <(find "$ROOT/examples" -name '*.bx' -type f 2>/dev/null | LC_ALL=C sort)
    fi

    # An examples/ with no entry is a failure once there is anything in it at
    # all: latte-bx's CLI lives there and so do the counter and todo examples,
    # and a glob that quietly matches nothing is how this leg would stop
    # running without anyone noticing.
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "--- examples FAILED: no .b file under examples/ declares 'package main' ---" >&2
        echo "    The leg builds and runs every entry there. Matching nothing is not a pass." >&2
        failed=1
        return 0
    fi

    local ran=0
    local summary=""
    local entry
    for entry in "${entries[@]}"; do
        local rel=${entry#"$ROOT"/}
        local name=${rel#examples/}; name=${name%.b}
        if [[ -n "$only" && "$name" != "$only" ]]; then continue; fi
        local slug=${name//\//_}
        local base=${entry%.b}
        local want_out="$base.out"
        local want_err="$base.err"

        if [[ ! -f "$want_out" ]]; then
            echo "--- examples FAILED: $rel has no golden ($(basename "$want_out")) ---" >&2
            echo "    Every example is RUN, on both backends, and diffed against its" >&2
            echo "    golden. A missing golden is a failure and not a skip: a gate that" >&2
            echo "    skips on a missing input is green for ever after (RULES.md 5), and" >&2
            echo "    not writing the golden is the cheapest way to get there." >&2
            echo "    Write it:   (cd \"$ROOT\" && beansc run $rel [args]) > ${want_out#"$ROOT"/}" >&2
            echo "    and READ it before committing — a golden nobody read is a" >&2
            echo "    screenshot of whatever the program did that day." >&2
            failed=1
            continue
        fi

        local golden_bytes
        golden_bytes=$(wc -c <"$want_out" | tr -d ' ')
        if [[ -f "$want_err" ]]; then
            golden_bytes=$(( golden_bytes + $(wc -c <"$want_err" | tr -d ' ') ))
        fi
        if [[ $golden_bytes -eq 0 ]]; then
            echo "--- examples FAILED: $rel's goldens are empty on both streams ---" >&2
            echo "    An example that prints nothing cannot tell a working program from" >&2
            echo "    a broken one, and an empty golden is the second way to silence this" >&2
            echo "    leg. Print the page." >&2
            failed=1
            continue
        fi

        local args=()
        if [[ -f "$base.args" ]]; then
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                args+=("$line")
            done <"$base.args"
        fi
        local want_status=0
        if [[ -f "$base.status" ]]; then
            want_status=$(tr -d '[:space:]' <"$base.status")
        fi

        # Both legs always run, and a bad entry is reported by BOTH before the
        # loop moves on. Stopping at the first mismatch would answer "the
        # example is wrong" when the question worth answering here is "which
        # backend is wrong" — and it would also mean a red run never proves the
        # native leg executed at all.
        local entry_bad=0

        # --- the interpreter ---------------------------------------------
        local run_cmd=("$BEANSC" run "$rel")
        if [[ ${#args[@]} -gt 0 ]]; then run_cmd+=(--); run_cmd+=("${args[@]}"); fi
        local status=0
        (cd "$ROOT" && "${run_cmd[@]}") \
            >"$tmp/ex_$slug.interp.out" 2>"$tmp/ex_$slug.interp.err" || status=$?
        compare_example_leg "$rel" "the interpreter" \
            "$tmp/ex_$slug.interp.out" "$tmp/ex_$slug.interp.err" "$status" \
            "$want_out" "$want_err" "$want_status" || entry_bad=1

        # --- the native binary -------------------------------------------
        # Built and run from ROOT, like the suites: an example that opens a
        # file names it relative to the module root, and a binary run from
        # elsewhere would fail for a reason that is not the backend's.
        if [[ $native -eq 1 ]]; then
            if ! (cd "$ROOT" && "$BEANSC" build "$rel" -o "$tmp/ex_$slug.bin") \
                    >"$tmp/ex_$slug.build" 2>&1; then
                echo "--- examples FAILED: $rel does not build natively ---" >&2
                cat "$tmp/ex_$slug.build" >&2
                entry_bad=1
            else
                local native_cmd=("$tmp/ex_$slug.bin")
                if [[ ${#args[@]} -gt 0 ]]; then native_cmd+=("${args[@]}"); fi
                status=0
                (cd "$ROOT" && "${native_cmd[@]}") \
                    >"$tmp/ex_$slug.native.out" 2>"$tmp/ex_$slug.native.err" || status=$?
                compare_example_leg "$rel" "the native binary" \
                    "$tmp/ex_$slug.native.out" "$tmp/ex_$slug.native.err" "$status" \
                    "$want_out" "$want_err" "$want_status" || entry_bad=1
                # The two backends against each other, on top of the two
                # against the golden. It is redundant while both goldens are
                # right and it is not redundant the day someone re-records one
                # of them from the wrong backend: this line names the split
                # even then.
                if ! cmp -s "$tmp/ex_$slug.interp.out" "$tmp/ex_$slug.native.out" || \
                   ! cmp -s "$tmp/ex_$slug.interp.err" "$tmp/ex_$slug.native.err"; then
                    echo "--- examples FAILED: $rel prints different bytes on the two backends ---" >&2
                    echo "    That is a compiler fault until proven otherwise. See RULES.md 3." >&2
                    diff -u "$tmp/ex_$slug.interp.out" "$tmp/ex_$slug.native.out" >&2 || true
                    diff -u "$tmp/ex_$slug.interp.err" "$tmp/ex_$slug.native.err" >&2 || true
                    entry_bad=1
                fi
            fi
        fi

        if [[ $entry_bad -ne 0 ]]; then
            failed=1
            continue
        fi
        ran=$((ran + 1))
        summary="$summary, $name (${golden_bytes} B)"
    done

    examples_ran=$ran
    if [[ $ran -eq 0 ]]; then
        if [[ -n "$only" ]]; then return 0; fi
        echo "--- examples FAILED: no example ran ---" >&2
        failed=1
        return 0
    fi

    local how="both backends"
    [[ $native -eq 1 ]] || how="the interpreter only (--interp)"
    # The sizes are in the line on purpose. "3 examples ran" reads the same
    # whether all three asserted a page or one of them asserted a newline.
    echo "ok examples — $ran entry(ies) built, RUN and byte-identical to their goldens on $how:${summary#,}"
}

if [[ $examples_only -eq 1 ]]; then
    run_examples_leg
    [[ $failed -eq 0 ]] || { echo "latte: FAILED" >&2; exit 1; }
    exit 0
fi

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

shopt -s nullglob
run_examples_leg


# --- the refusal-coverage leg --------------------------------------------
#
# Every `self.faults.push(...)` in latte's core must have a case in the suite
# that audits that file — a trip with the exact fault text, a positive control
# that must be accepted, and a name the deletion pass can map back to the site:
#
#   builder.b     tests/frames.b    § 13
#   apply.b       tests/w1_faults.b § 1
#   serialize.b   tests/w1_faults.b § 3
#
# Each of those sections already asserts that IT reached N distinct sites. What
# none of them can see is its source file growing one MORE, because a refusal
# nothing feeds raises nothing and is counted by nobody. So this compares the
# two numbers, per file, and it is the whole reason a new refusal cannot be
# added and quietly go untested — the failure mode RULES.md calls "the refusal
# that never runs", which in this repo has already produced one control that
# could not fire and one that never ran.
#
# Nothing here SKIPs. Every input is a file in this repo; if one is missing or
# shaped differently, the audit has moved and that is a failure, not a shrug.
refusal_coverage_for() {
    local file="$1" golden="$2" suite="$3"
    local source="$ROOT/$file"
    local recorded="$ROOT/$golden"
    if [[ ! -f "$source" || ! -f "$recorded" ]]; then
        echo "--- refusal-coverage FAILED: $file or $golden is missing ---" >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi

    local sites listed
    sites=$(grep -c 'self\.faults\.push' "$source" || true)
    # The tally the audit prints, one line per distinct site, from its header
    # until the first line that is not a tally row.
    listed=$(awk -v want="-- the sites in $file, and how many shapes reach each" '
                  $0 == want { on = 1; n = 0; next }
                  on && /^   [0-9]+x / { n++; next }
                  on { on = 0 }
                  END { print n + 0 }' "$recorded")

    if [[ "$listed" -eq 0 ]]; then
        echo "--- refusal-coverage FAILED: $golden has no site tally for $file ---" >&2
        echo "    $suite prints one line per fault site it reached, under" >&2
        echo "    \"-- the sites in $file, and how many shapes reach each\"." >&2
        echo "    An empty tally means the audit moved and this leg is now blind." >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi
    if [[ "$sites" -ne "$listed" ]]; then
        echo "--- refusal-coverage FAILED: $file has $sites report sites, the audit covers $listed ---" >&2
        echo "    A new refusal needs a case in $suite: an input that trips it with the" >&2
        echo "    exact fault text, and a positive control beside it that must be" >&2
        echo "    ACCEPTED. Then add its label to probes/delete_faults.sh, in file order," >&2
        echo "    and run that script — a refusal whose deletion changes nothing is either" >&2
        echo "    untested or unreachable, and neither shows up in a green run." >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi
    covered=$((covered + sites))
    return 0
}

# A source file that is supposed to have NO report sites at all. `frames.b` is
# pure functions and `diff.b` has a `faults` field it never writes to, so every
# `differ.faults.len() == 0` in the suites is a tautology today. That is fine
# and it is also invisible: the day one of them grows a refusal, nothing above
# would notice, because a file with no tally has nothing to compare against.
# This is what notices.
refusal_coverage_none() {
    local file="$1"
    local source="$ROOT/$file"
    if [[ ! -f "$source" ]]; then
        echo "--- refusal-coverage FAILED: $file is missing ---" >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi
    local sites
    sites=$(grep -c 'self\.faults\.push' "$source" || true)
    if [[ "$sites" -ne 0 ]]; then
        echo "--- refusal-coverage FAILED: $file has $sites report site(s) and no audit ---" >&2
        echo "    $file had none when this leg was written, so it has no tally to" >&2
        echo "    compare against. A refusal needs a trip case with the exact fault" >&2
        echo "    text, a positive control beside it, and a label in" >&2
        echo "    probes/delete_faults.sh — then give $file a row in" >&2
        echo "    run_refusal_coverage_leg instead of this one." >&2
        failed=1
        uncovered=$((uncovered + 1))
    fi
}

# A file whose report sites are known and NOT audited yet. It cannot get worse
# quietly: the count is recorded here, and a new site fails the gate with the
# same instructions as everywhere else. `render.b` is W4's, and its two sites
# are the only ones in latte's core with no case — lanes/W1.md, SIXTH AGENT.
refusal_coverage_pending() {
    local file="$1" recorded="$2"
    local source="$ROOT/$file"
    if [[ ! -f "$source" ]]; then
        echo "--- refusal-coverage FAILED: $file is missing ---" >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi
    local sites
    sites=$(grep -c 'self\.faults\.push' "$source" || true)
    if [[ "$sites" -ne "$recorded" ]]; then
        echo "--- refusal-coverage FAILED: $file has $sites report sites, $recorded were recorded and none are audited ---" >&2
        echo "    Add a trip case with the exact fault text and a positive control" >&2
        echo "    beside it, a label in probes/delete_faults.sh, and a row in" >&2
        echo "    run_refusal_coverage_leg — or update the recorded count here. Do" >&2
        echo "    not add a refusal nobody exercises." >&2
        failed=1
        uncovered=$((uncovered + 1))
        return 0
    fi
    pending=$((pending + sites))
}

run_refusal_coverage_leg() {
    local covered=0
    local uncovered=0
    local pending=0
    refusal_coverage_for builder.b   tests/frames.out    "tests/frames.b § 13"
    refusal_coverage_for apply.b     tests/w1_faults.out "tests/w1_faults.b § 1"
    refusal_coverage_for serialize.b tests/w1_faults.out "tests/w1_faults.b § 3"
    refusal_coverage_none frames.b
    refusal_coverage_none diff.b
    refusal_coverage_pending render.b 2
    # One line, and only when all three files passed. A partial "ok … all 16"
    # printed beside a FAILED line for a fourth file is exactly the shape
    # RULES.md calls out under "a green count can mean two different things":
    # a reader grepping for `ok refusal-coverage` would find one either way.
    if [[ $uncovered -eq 0 ]]; then
        echo "ok refusal-coverage — all $covered report sites in builder.b, apply.b and serialize.b have a case and a control; frames.b and diff.b still have none; render.b's $pending are recorded and NOT audited (lanes/W1.md)"
    else
        echo "--- refusal-coverage FAILED: $uncovered of the 6 core source files are not covered ---" >&2
    fi
}

# latte-bx generates, beansc refuses. Run before the suite loop, because the leg
# stages two scratch files in tests/ and removes them again, and the loop globs
# that directory. Skipped only when a single suite was named, like the wasm leg.
[[ -n "$only" ]] || run_component_type_leg

# Reads two files and always runs, even for a single named suite: a check that
# cannot be skipped cannot rot.
run_refusal_coverage_leg

# Every recorded refusal in probes/*_bad/, re-checked against today's compiler.
#
# This existed as a hand-run script for three lanes and `test.sh` never called
# it, which is the exact shape RULES.md refuses: a guard that only runs when
# someone remembers is a guard that reports nothing the day it matters. A
# probe's answer is half "this works" and half "this is refused, and here is
# the message" — the second half rots silently when a compiler starts accepting
# a shape the design was built around.
#
# The count is pinned here on purpose. check_refusals.sh finds probes by shape,
# so it stays green after a `*_bad/` directory is deleted — it would simply
# check fewer and still say ok. Pinning means removing a refusal is a decision
# someone has to write down here, not something a `rm -rf` does quietly.
RECORDED_REFUSALS=3
run_recorded_refusals_leg() {
    local script="$ROOT/probes/check_refusals.sh"
    # Missing is a FAILURE, never a skip: the whole point is that it cannot
    # be absent without anyone noticing.
    if [[ ! -f "$script" ]]; then
        echo "--- recorded-refusals FAILED: probes/check_refusals.sh is gone ---" >&2
        failed=1
        return
    fi
    local out
    if ! out=$(BEANSC="$BEANSC" bash "$script" 2>&1); then
        echo "--- recorded-refusals FAILED: a shape the design was built around is no longer refused ---" >&2
        echo "$out" >&2
        failed=1
        return
    fi
    local n
    n=$(printf '%s\n' "$out" | sed -n 's/^ok — \([0-9][0-9]*\) recorded refusal(s).*/\1/p')
    if [[ "$n" != "$RECORDED_REFUSALS" ]]; then
        echo "--- recorded-refusals FAILED: checked ${n:-0}, expected $RECORDED_REFUSALS ---" >&2
        echo "    A refusal was added or removed. If that was deliberate, change" >&2
        echo "    RECORDED_REFUSALS in test.sh and say why in the commit." >&2
        echo "$out" >&2
        failed=1
        return
    fi
    echo "ok recorded-refusals — all $n recorded refusal(s) in probes/*_bad/ are still refused, with their recorded message"
}

# Always runs, for the same reason as the leg above.
run_recorded_refusals_leg

# The browser half of gate 3. `tests/js_cases.b` is a gated suite already — it
# prints a JavaScript fixture file, and both backends agree on it byte for
# byte. That proves the ENCODER is consistent with itself. This leg is the
# other half: it takes that same fixture into a real browser and requires the
# real `js/latte.js` to land on the same HTML and the same frame dump as the
# Beans applier, and to produce the same fault text on the same malformed
# edits. A text test says the stream is self-consistent; only this says the two
# appliers MEAN the same thing.
#
# Chrome absent is a SKIP and it says so on its own line, because a machine
# without Chrome is a real thing. Chrome PRESENT and anything else wrong is a
# FAILURE — an empty extraction, a fixture that will not generate, a diff. The
# distinction is the one RULES.md draws under "a green count can mean two
# different things", and it is why the verdict is diffed whole rather than
# grepped for a count: the golden's last line is "338 checks, 0 bad", so a
# harness that silently ran nine of them fails on the body long before the
# count line.
find_chrome() {
    local c
    for c in "${CHROME:-}" \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "$(command -v google-chrome 2>/dev/null || true)" \
        "$(command -v chromium 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

run_browser_apply_leg() {
    local want="$ROOT/tests/js_apply.out"
    local harness="$ROOT/tests/js_apply.js"
    local applier="$ROOT/js/latte.js"

    # Inputs missing is a FAILURE, never a skip. A gate that skips when its
    # subject disappears is the shape this repo keeps getting bitten by.
    local f
    for f in "$want" "$harness" "$applier"; do
        if [[ ! -f "$f" ]]; then
            echo "--- browser-apply FAILED: ${f#$ROOT/} is missing ---" >&2
            failed=1
            return
        fi
    done

    local chrome
    if ! chrome=$(find_chrome); then
        echo "SKIP browser-apply: no Chrome or Chromium found (set CHROME=/path/to/chrome). js/latte.js is NOT checked in this run."
        skipped=$((skipped + 1))
        return
    fi

    local d="$tmp/browser"
    mkdir -p "$d"
    if ! (cd "$ROOT" && "$BEANSC" run tests/js_cases.b) >"$d/fixtures.js" 2>"$d/gen.err"; then
        echo "--- browser-apply FAILED: tests/js_cases.b would not generate the fixture ---" >&2
        cat "$d/gen.err" >&2
        failed=1
        return
    fi
    cp "$applier" "$harness" "$d/"
    printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"></head><body>' \
        '<script src="latte.js"></script><script src="fixtures.js"></script>' \
        '<script src="js_apply.js"></script></body></html>' > "$d/page.html"

    "$chrome" --headless=new --disable-gpu --no-sandbox --dump-dom \
        "file://$d/page.html" >"$d/dom.html" 2>"$d/chrome.err" || true

    # The verdict is printed into a <pre>, so the DOM dump carries it escaped.
    sed -n '/@@LATTE-BEGIN@@/,/@@LATTE-END@@/p' "$d/dom.html" \
        | sed -e '1d' -e '$d' \
        | sed -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&amp;/\&/g' \
        > "$d/got.txt"

    # An empty extraction means the page threw before printing anything — a
    # JavaScript error in latte.js reads exactly like this and must not be
    # mistaken for "no differences".
    if [[ ! -s "$d/got.txt" ]]; then
        echo "--- browser-apply FAILED: the page printed no verdict (latte.js threw, or the markers moved) ---" >&2
        echo "    chrome: $chrome" >&2
        sed -n '1,20p' "$d/chrome.err" >&2
        failed=1
        return
    fi

    if diff -u "$want" "$d/got.txt" >"$d/diff.txt"; then
        echo "ok browser-apply — js/latte.js lands on the Beans applier's HTML, frame dump and fault text in $("$chrome" --version 2>/dev/null | head -1)"
        legs=$((legs + 1))
    else
        echo "--- browser-apply FAILED: the browser applier and the Beans applier disagree ---" >&2
        head -60 "$d/diff.txt" >&2
        failed=1
    fi
}

# Runs even for a single named suite, like the two legs above.
run_browser_apply_leg

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

if [[ $suites -eq 0 && $examples_ran -eq 0 && -n "$only" ]]; then
    echo "no suite or example matched \"$only\"" >&2
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
