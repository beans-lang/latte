#!/usr/bin/env bash
# w8b_leaks.sh — PLAN.md gate 11, the `leaks` half.
#
#   "the whole thing on both backends, with the circuit, component and upload
#    suites also under macOS `leaks` and the sanitizer build."
#
# Why this is a separate tool and not a stanza in the gate's suite loop: the
# gate diffs a suite's OUTPUT against a golden, and a program that prints the
# right bytes and keeps every one of them is green there. Nothing else in this
# repo looks at what the process still owns when it exits.
#
# Three rules, each of which is a way this check silently reports nothing.
#
#   1. **`BEANS_NO_POOL=1` or the answer is worthless.** The Beans runtime
#      allocates small objects out of registered slabs, and a slab is one
#      malloc block that `leaks` sees as live and in use for the whole run. A
#      leaked object inside a pooled slab is INVISIBLE — `leaks` reports zero
#      and means it. `BEANS_NO_POOL=1` sends every allocation to malloc/free,
#      which is the only configuration in which a zero here is evidence.
#      `beans/test/sanitize.sh` sets it for the same reason.
#
#   2. **Serially, one process at a time.** A concurrent `test-core` starves
#      macOS `leaks`: it stops the target to walk its heap, and under load it
#      gives up and reports nothing useful. This script never runs two.
#
#   3. **The tool must be seen to have run.** `leaks` answers 0 both when it
#      found nothing and when it could not examine the process at all. So the
#      report line is REQUIRED to be present and to parse; a run whose output
#      carries no "N leaks for M total leaked bytes" line is a FAILURE here,
#      not a pass and not a skip.
#
# Off macOS there is no `leaks`, and this says so on its own line and exits 0 —
# loudly, naming what went unchecked (RULES.md 5).
#
#   ./w8b_leaks.sh              every suite in the list
#   ./w8b_leaks.sh circuit      one of them
#   ./w8b_leaks.sh --list       print the list and stop
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
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-}  && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}   && -d "$BEANS_ROOT/stdlib/std"        ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding"  ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}      && -d "$BEANS_ROOT/runtime/net"       ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}      && -d "$BEANS_ROOT/runtime/log"       ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi

# The suites gate 11 names, plus the two that reach the same machinery over a
# real socket. `circuit_live` and `w7_live` are the only programs in this repo
# where the runtime opens a TCP connection, brews fibers around it and tears
# the lot down, which is where this workspace's last runtime leak lived (the
# CC husk leak: every threaded server leaking ~150 B per request because husks
# were never freed while workers were live).
SUITES=(
    circuit          # gate 11: "the circuit ... suite"
    circuit_live     # the same machinery with a real server, socket and fibers
    w7_live          # the same again with permessage-deflate negotiated
    components       # gate 11: "the component ... suite"
    w6_upload        # gate 11: "the upload suite"
    # Past the three gate 11 names, because the whole sweep costs about
    # sixteen seconds and each of these reaches a different way to lose
    # memory. Not a shotgun: one line each says why.
    w1_faults        # panics and unwinds — where this workspace's leaks lived
    apply            # thousands of random trees and mutations: the densest
                     # allocation churn in the repo
    w6_stream        # a chunked body cut at every byte boundary
    w6_virtual       # a window scrolled to the end and back, rows in and out
    pages            # the routing and mount path, and every refusal on it
    w4_forms         # binding, validation and the antiforgery refusals
    # Landed on main after this sweep was first written. Each one is here for
    # the same reason as the lines above it and not because it is new.
    w4_upgrade       # handshakes REFUSED on the socket path — a stream taken,
                     # answered and dropped without ever becoming a circuit,
                     # which is the one socket path circuit_live never walks
    w8_threats       # every refusal in the repo, driven at once
    w8_hostile       # thousands of generated hostile shapes through the
                     # markup and attribute path
)

# Every gated suite, by test.sh's own definition: tests/*.b, no leading "_",
# no leading "probe", and a golden beside it.
#
# **This exists because a hand-written list can only fail in one direction.**
# A renamed or deleted suite is caught below — a missing tests/<name>.b is a
# hard FAILURE, deliberately, so the layout moving is loud. A suite that is
# ADDED is the direction the list cannot see: it simply is not swept, nothing
# says so, and the summary looks exactly like a full sweep. Three suites sat
# outside this sweep that way between one lane and the next. So the names not
# in SUITES are printed at the end of every run, with the count in the summary
# line, and adding one here is then a decision somebody made rather than an
# omission nobody could see.
gated_suites() {
    local case name
    for case in "$ROOT"/tests/*.b; do
        name=$(basename "$case" .b)
        case "$name" in _*|probe*) continue ;; esac
        [[ -f "$ROOT/tests/$name.out" ]] || continue
        printf '%s\n' "$name"
    done
}

unswept() {
    local name swept
    while IFS= read -r name; do
        swept=0
        for s in "${SUITES[@]}"; do [[ "$s" == "$name" ]] && swept=1; done
        [[ $swept -eq 0 ]] && printf '%s\n' "$name"
    done < <(gated_suites)
}

if [[ ${1:-} == "--list" ]]; then
    printf '%s\n' "${SUITES[@]}"
    exit 0
fi
if [[ ${1:-} == "--unswept" ]]; then
    unswept
    exit 0
fi
only=${1:-}

if [[ "$(uname -s)" != Darwin ]]; then
    echo "SKIP w8b-leaks: macOS \`leaks\` exists only on Darwin, and this host is $(uname -s)."
    echo "   NOT CHECKED: whether ${SUITES[*]} still own heap memory at exit."
    echo "   On Linux the equivalent is LeakSanitizer, which rides the ASan build in w8b_sanitize.sh."
    exit 0
fi
if ! command -v leaks >/dev/null 2>&1; then
    echo "SKIP w8b-leaks: no \`leaks\` on PATH (it ships with the Xcode command line tools)."
    echo "   NOT CHECKED: whether ${SUITES[*]} still own heap memory at exit."
    exit 0
fi

out="$ROOT/build/w8b/leaks"
mkdir -p "$out"

failed=0
ran=0
total_bytes=0

# ---- the control ---------------------------------------------------------
#
# Rule 3 again, and the half a report line alone cannot cover. `leaks` says
# "0 leaks for 0 total leaked bytes" both when a program is clean and when it
# examined a process it could not read — and on this host every report carries
#
#     Process N is not debuggable. Due to security restrictions, leaks can
#     only show or save contents of readonly memory of restricted processes.
#
# so "it printed a report" is not "it can find a leak". `tests/_w8b_leak_control.b`
# leaks on purpose through the same build, the same BEANS_NO_POOL=1 and the
# same `leaks --atExit`. If the tool cannot find THAT, every zero beside it is
# worthless, and this fails rather than reporting five clean suites.
#
# The floors, not the exact numbers: the control asks for 8 blocks of 4096
# bytes and the tool reported 7 leaks for 35840 bytes here — one block is still
# reachable from a register at exit, and a 4096-byte request lands in a
# 5120-byte malloc class. Both are the allocator's business. What is asserted
# is that most of the blocks and most of the bytes were found.
CONTROL_MIN_LEAKS=4
CONTROL_MIN_BYTES=16384

run_control() {
    local src="$ROOT/tests/_w8b_leak_control.b"
    if [[ ! -f "$src" ]]; then
        echo "--- w8b-leaks FAILED: tests/_w8b_leak_control.b is missing, so nothing" \
             "proves \`leaks\` can find a leak on this host ---" >&2
        failed=1
        return
    fi
    if ! (cd "$ROOT" && "$BEANSC" build "$src" -o "$out/_control") >"$out/_control.build" 2>&1; then
        echo "--- w8b-leaks FAILED: the leak control would not build ---" >&2
        sed -n '1,40p' "$out/_control.build" >&2
        failed=1
        return
    fi
    set +e
    BEANS_NO_POOL=1 MallocStackLogging=1 \
        leaks --atExit -- "$out/_control" >"$out/_control.leaks" 2>&1
    set -e
    local report
    report=$(grep -Eo '[0-9]+ leaks? for [0-9]+ total leaked bytes' "$out/_control.leaks" | tail -1 || true)
    if [[ -z "$report" ]]; then
        echo "--- w8b-leaks FAILED: the leak control produced no \`leaks\` report at all ---" >&2
        tail -30 "$out/_control.leaks" >&2
        failed=1
        return
    fi
    local count bytes
    count=$(printf '%s' "$report" | awk '{ print $1 }')
    bytes=$(printf '%s' "$report" | awk '{ print $4 }')
    if (( count < CONTROL_MIN_LEAKS || bytes < CONTROL_MIN_BYTES )); then
        echo "--- w8b-leaks FAILED: the control leaks 8 blocks of 4096 bytes on purpose" \
             "and \`leaks\` reported \"$report\" ---" >&2
        echo "    the tool is not finding leaks on this host, so every clean result" >&2
        echo "    below would be meaningless. Nothing is reported as checked." >&2
        failed=1
        return
    fi
    echo "ok w8b-leaks control — the deliberate leak was found: $report (floor ${CONTROL_MIN_LEAKS}/${CONTROL_MIN_BYTES})"
}

# The control runs whatever suite was named, because a single-suite run has
# exactly the same question to answer.
run_control

for name in "${SUITES[@]}"; do
    [[ -z "$only" || "$only" == "$name" ]] || continue
    src="$ROOT/tests/$name.b"
    if [[ ! -f "$src" ]]; then
        # A suite that has moved or been renamed is a FAILURE. This is the
        # exact shape RULES.md 5 warns about: skip it and the day the layout
        # moves, everything is green forever.
        echo "--- w8b-leaks FAILED: tests/$name.b is missing ---" >&2
        failed=1
        continue
    fi
    bin="$out/$name"
    if ! (cd "$ROOT" && "$BEANSC" build "$src" -o "$bin") >"$out/$name.build" 2>&1; then
        echo "--- w8b-leaks FAILED: tests/$name.b would not build natively ---" >&2
        sed -n '1,40p' "$out/$name.build" >&2
        failed=1
        continue
    fi

    # `--atExit` runs the program to completion and walks the heap on the way
    # out, so this is "what did the process still own when main returned",
    # not a sample of a running one. Suite stdout is kept: a suite that
    # printed FAIL lines under MallocStackLogging is a different bug and must
    # not read as a leak result.
    set +e
    BEANS_NO_POOL=1 MallocStackLogging=1 \
        leaks --atExit -- "$bin" >"$out/$name.leaks" 2>&1
    status=$?
    set -e
    ran=$((ran + 1))

    report=$(grep -Eo '[0-9]+ leaks? for [0-9]+ total leaked bytes' "$out/$name.leaks" | tail -1 || true)
    if [[ -z "$report" ]]; then
        # Rule 3. No report line means `leaks` did not examine the process —
        # it was starved, the target died early, or the tool refused. Never a
        # pass.
        echo "--- w8b-leaks FAILED: \`leaks\` printed no report for tests/$name.b (exit $status) ---" >&2
        echo "    the tool did not run; this is not a clean result" >&2
        tail -30 "$out/$name.leaks" >&2
        failed=1
        continue
    fi
    bytes=$(printf '%s' "$report" | awk '{ print $4 }')
    count=$(printf '%s' "$report" | awk '{ print $1 }')
    total_bytes=$((total_bytes + bytes))

    if grep -q 'FAIL' "$out/$name.leaks"; then
        echo "--- w8b-leaks FAILED: tests/$name.b printed FAIL lines under \`leaks\` ---" >&2
        grep -n 'FAIL' "$out/$name.leaks" | head -20 >&2
        failed=1
        continue
    fi
    if [[ "$count" != "0" || "$bytes" != "0" ]]; then
        echo "--- w8b-leaks FAILED: tests/$name.b leaked $bytes bytes in $count allocation(s) ---" >&2
        sed -n '/leaks Report Version/,$p' "$out/$name.leaks" | head -60 >&2
        failed=1
        continue
    fi
    echo "ok w8b-leaks tests/$name.b — $report (BEANS_NO_POOL=1, leaks --atExit)"
done

if [[ $ran -eq 0 ]]; then
    echo "no suite matched \"$only\"" >&2
    exit 1
fi
if [[ $failed -ne 0 ]]; then
    echo "w8b-leaks: FAILED" >&2
    exit 1
fi
# The other direction of rule 5, printed whether or not anything failed.
missing=$(unswept)
missing_count=$(printf '%s' "$missing" | grep -c . || true)
note=""
if [[ $missing_count -gt 0 ]]; then
    echo "NOT SWEPT by w8b-leaks — $missing_count gated suite(s) run under no leak check at all:"
    echo "   $(printf '%s ' $missing)"
    echo "   Nothing is wrong with that by itself; the sweep is a chosen list. It is"
    echo "   printed because a suite added after this list was written is invisible to"
    echo "   it, and a summary that did not say so would read like a full sweep."
    note=" — $missing_count gated suite(s) NOT swept, named above"
fi
echo "ok w8b-leaks — $ran suite(s), $total_bytes total leaked bytes, every one reported by the tool${note}"
