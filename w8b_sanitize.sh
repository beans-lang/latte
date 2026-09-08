#!/usr/bin/env bash
# w8b_sanitize.sh — PLAN.md gate 11, the sanitizer half.
#
#   "the whole thing on both backends, with the circuit, component and upload
#    suites also under macOS `leaks` and the sanitizer build."
#
# Latte drives fibers, OS threads, a TCP socket and a C runtime it does not
# own. `test.sh` proves those programs print the right bytes; this proves the
# machine underneath printed them without a memory error. The workspace bar
# says it plainly: `make test-sanitize` is the only place ARC and the cycle
# collector are checked for real memory errors rather than for the right
# answer.
#
# **The build goes through the driver, not a hand link.** `BEANS_SANITIZE` is
# read in `beans/src/driver.b` and accepts exactly two strings —
# `address,undefined` and `thread` — and the driver puts them on every
# compilation it runs: the generated IR, `beans_rt.c`, the FFI shim, and the
# net, websocket and zlib bridges a circuit actually calls. The older hand-link
# recipe in `beans/test/sanitize.sh` only knew about sockx, "which left the
# protocol bridges unsanitized even when their Beans fuzzers passed" — latte's
# whole live path is those bridges.
#
# **Passing the flag on the IR is not the same as instrumenting the IR**, and
# control B below is what says so out loud. LLVM's AddressSanitizer pass only
# touches functions marked `sanitize_address`, `beansc` 0.1.40 marks none, so
# the Beans half of every binary here is uninstrumented while the C half is
# fully instrumented. BLOCKERS.md B15. Everything this script reports is
# reported inside that boundary, and it names the boundary every run.
#
# **Three things this script insists on.**
#
#   1. **The sanitized run must still print the golden.** A sanitizer that
#      says nothing about a program that now prints the wrong answer has told
#      you nothing worth having. Every ASan run below is diffed against
#      `tests/<name>.out`, byte for byte, the same file the gate uses.
#
#   2. **Two controls, because passing a flag is not evidence the check ran.**
#      This is the exact lesson `beans/test/sanitize.sh` writes down about
#      `-fsanitize=function`: "Apple's clang accepts -fsanitize=function and
#      emits nothing for it ... a full macOS `make test-sanitize` reported
#      EXIT=0 with no skip line to read." Control A frees a block twice and
#      ASan is REQUIRED to catch it — that is the runtime being present at
#      all. Control B reads past the end of a block, which needs the LOAD to
#      have been instrumented; it is not, and that is a named skip rather
#      than a pretend pass.
#
#   3. **A skip is loud and names what went unchecked.** RULES.md 5.
#
#   ./w8b_sanitize.sh            asan then tsan, every suite
#   ./w8b_sanitize.sh --asan     ASan/UBSan only
#   ./w8b_sanitize.sh --tsan     TSan only
#   ./w8b_sanitize.sh circuit    one suite, both sanitizers
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

# Apple's ASan runtime aborts when leak detection is asked for, so leaks are
# `w8b_leaks.sh`'s job on this host and ASan's on Linux. Stated, not silent:
# a `detect_leaks=0` nobody wrote down reads as coverage that is not there.
asan_detect_leaks=1
[[ "$(uname -s)" == Darwin ]] && asan_detect_leaks=0

# The suites gate 11 names, plus the live ones. `circuit_live`, `w7_live` and
# `w4_upgrade` are the only programs in this repo that open a real socket,
# brew fibers around it, run an OS thread beside it and tear all of it down,
# and they are the only place the net, websocket and zlib bridges are reached
# at all — so they are the whole reason this script builds through the driver.
# `w4_upgrade` joined them on main: it is the only one that drives handshakes
# the endpoint REFUSES, which takes a `net.TcpStream`, writes a response by
# hand and drops it without a framer ever owning it.
SUITES=(circuit circuit_live w7_live components w6_upload w4_upgrade)

# Everything gated that this sweep does NOT instrument, by test.sh's own rule
# for what a suite is. Unlike the leaks sweep, this list is deliberately small
# — an instrumented build and run costs 20-40x a plain one, and while
# BLOCKERS.md B15 stands the extra suites would only re-exercise `beans_rt.c`,
# which these six already cover. But "deliberately small" and "silently stale"
# print the same summary, so the names are listed once at the end of a run and
# counted in the summary line. A suite added after this list was written then
# appears there instead of nowhere.
gated_suites() {
    local case name
    for case in "$ROOT"/tests/*.b; do
        name=$(basename "$case" .b)
        case "$name" in _*|probe*) continue ;; esac
        [[ -f "$ROOT/tests/$name.out" ]] || continue
        printf '%s\n' "$name"
    done
}

uninstrumented() {
    local name done_it
    while IFS= read -r name; do
        done_it=0
        for s in "${SUITES[@]}"; do [[ "$s" == "$name" ]] && done_it=1; done
        [[ $done_it -eq 0 ]] && printf '%s\n' "$name"
    done < <(gated_suites)
}

do_asan=1
do_tsan=1
only=""
for arg in "$@"; do
    case "$arg" in
        --asan) do_tsan=0 ;;
        --tsan) do_asan=0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) only="$arg" ;;
    esac
done

out="$ROOT/build/w8b/sanitize"
mkdir -p "$out"
failed=0
skipped=0
ran=0

# The reports that mean something went wrong, whichever sanitizer produced it.
BAD='AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|ThreadSanitizer|runtime error:'

# ---- the controls --------------------------------------------------------
#
# Two questions, two programs, because they fail for different reasons and one
# of them is a compiler gap this repo cannot close from here.
#
#   A. Is the ASan RUNTIME under the build? A double free is caught by ASan's
#      allocator, which replaces malloc and free the moment
#      `libclang_rt.asan` is linked in, with no instrumented load anywhere.
#      If this is not caught, nothing below means anything: hard FAILURE.
#
#   B. Does the sanitizer REACH the code `beansc` emitted? An out-of-bounds
#      read is caught only if the load itself was instrumented, and LLVM's
#      AddressSanitizer pass instruments only functions carrying the
#      `sanitize_address` attribute. `beansc` 0.1.40 emits none -- zero
#      occurrences in every `.ll` under `build/` -- so it is not, and reading
#      32 KiB past a 32-byte block is silent. That is BLOCKERS.md B15, it is a
#      compiler change, and it is not latte's to make. So this one is a LOUD
#      SKIP that names what went unchecked, and it turns into an `ok` by
#      itself on the day the emitter marks its functions.
#
#   C. The same question for TSan, asked separately because it is a separate
#      attribute (`sanitize_thread`) and the answer could differ. It does not:
#      400,000 unsynchronised writes to one word from two OS threads are not
#      reported either. So the TSan lines below mean "no race in beans_rt.c,
#      beans_fiber.c and the bridges", which is real coverage and is not the
#      whole of what "TSan clean" sounds like.
build_control() {                # <source stem>; builds and runs into $out
    local stem=$1
    local src="$ROOT/tests/$stem.b"
    if [[ ! -f "$src" ]]; then
        echo "--- w8b-sanitize FAILED: tests/$stem.b is missing ---" >&2
        failed=1
        return 1
    fi
    if ! (cd "$ROOT" && BEANS_SANITIZE=address,undefined \
            "$BEANSC" build "$src" -o "$out/$stem") >"$out/$stem.build" 2>&1; then
        echo "--- w8b-sanitize FAILED: tests/$stem.b would not build under ASan ---" >&2
        sed -n '1,40p' "$out/$stem.build" >&2
        failed=1
        return 1
    fi
    # Control A aborts ON PURPOSE — that is what ASan does to a double free —
    # and bash announces a child killed by a signal on ITS OWN stderr, as
    # "line N: 12345 Abort trap: 6". In an otherwise green gate run that line
    # reads like something broke, and a gate that trains its readers to skip
    # a line is a gate whose skip lines stop being read (RULES.md 5).
    #
    # The announcement comes from THIS shell, not from the child, so a
    # redirect on the child cannot catch it; the script's own stderr is put
    # aside for exactly this one command and restored immediately. Nothing is
    # lost — the child's stdout and stderr are captured in files above and
    # below, and they are what every assertion here reads.
    set +e
    exec 3>&2 2>/dev/null
    (cd "$ROOT" && ASAN_OPTIONS="detect_leaks=0:halt_on_error=1" BEANS_NO_POOL=1 \
        "$out/$stem") >"$out/$stem.stdout" 2>"$out/$stem.stderr"
    exec 2>&3 3>&-
    set -e
    return 0
}

asan_runtime_control() {
    build_control _w8b_sanitize_control || return
    if ! grep -q 'AddressSanitizer: attempting double-free' \
        "$out/_w8b_sanitize_control.stderr"; then
        echo "--- w8b-sanitize FAILED: the control frees one heap block twice and ASan" \
             "did not report a double-free ---" >&2
        echo "    the AddressSanitizer runtime is not under this build: the flag was" >&2
        echo "    accepted and nothing is being checked. No result below is meaningful." >&2
        sed -n '1,30p' "$out/_w8b_sanitize_control.stderr" >&2
        failed=1
        return
    fi
    echo "ok w8b-sanitize control A — ASan's allocator caught the deliberate double-free, so the sanitizer runtime IS under this build"
}

tsan_reach_control() {
    local stem=_w8b_tsan_reach
    local src="$ROOT/tests/$stem.b"
    if [[ ! -f "$src" ]]; then
        echo "--- w8b-sanitize FAILED: tests/$stem.b is missing ---" >&2
        failed=1
        return
    fi
    if ! (cd "$ROOT" && BEANS_SANITIZE=thread \
            "$BEANSC" build "$src" -o "$out/$stem") >"$out/$stem.build" 2>&1; then
        echo "--- w8b-sanitize FAILED: tests/$stem.b would not build under TSan ---" >&2
        sed -n '1,40p' "$out/$stem.build" >&2
        failed=1
        return
    fi
    set +e
    (cd "$ROOT" && TSAN_OPTIONS="halt_on_error=0" BEANS_NO_POOL=1 \
        "$out/$stem") >"$out/$stem.stdout" 2>"$out/$stem.stderr"
    set -e
    if grep -q 'WARNING: ThreadSanitizer: data race' "$out/$stem.stderr"; then
        echo "ok w8b-sanitize control C — TSan caught a data race in Beans-generated code (BLOCKERS.md B15 is fixed; this note can go)"
        return
    fi
    echo "SKIP w8b-sanitize control C: beansc 0.1.40 emits no \`sanitize_thread\` attribute, so"
    echo "   ThreadSanitizer instruments NONE of the code the compiler generated."
    echo "   NOT CHECKED anywhere in this sweep: races between two pieces of BEANS code —"
    echo "   the control ran 400,000 unsynchronised writes to one word from two OS"
    echo "   threads and TSan said nothing. See BLOCKERS.md B15."
    echo "   STILL CHECKED: every race inside beans_rt.c and beans_fiber.c — the ARC"
    echo "   counters, the cycle collector, the allocator, the netpoller — and inside"
    echo "   the net, websocket and zlib bridges, all of which ARE compiled from C"
    echo "   and instrumented. That is where this workspace's last two runtime races"
    echo "   lived, so the leg is worth running; it is just not everything."
    skipped=$((skipped + 1))
}

asan_reach_control() {
    build_control _w8b_sanitize_reach || return
    if grep -q 'AddressSanitizer: heap-buffer-overflow' \
        "$out/_w8b_sanitize_reach.stderr"; then
        echo "ok w8b-sanitize control B — ASan caught an out-of-bounds read in Beans-generated code (BLOCKERS.md B15 is fixed; this note can go)"
        return
    fi
    echo "SKIP w8b-sanitize control B: beansc 0.1.40 emits no \`sanitize_address\` attribute, so"
    echo "   AddressSanitizer instruments NONE of the code the compiler generated."
    echo "   NOT CHECKED anywhere in this sweep: out-of-bounds loads and stores, and"
    echo "   use-after-free reads, in Beans code — the control read 32 KiB past a"
    echo "   32-byte heap block and lived. See BLOCKERS.md B15."
    echo "   STILL CHECKED: everything ASan does without instrumenting a load —"
    echo "   double free, invalid free, and the bounds of every intercepted"
    echo "   memcpy/memmove/memset — plus the whole of beans_rt.c and the net,"
    echo "   websocket and zlib bridges, which ARE compiled from C and instrumented."
    skipped=$((skipped + 1))
}

# ---- ASan / UBSan --------------------------------------------------------
run_asan() {
    local name=$1
    local src="$ROOT/tests/$name.b"
    local want="$ROOT/tests/$name.out"
    if [[ ! -f "$src" || ! -f "$want" ]]; then
        echo "--- w8b-sanitize FAILED: tests/$name.b or its golden is missing ---" >&2
        failed=1
        return
    fi
    if ! (cd "$ROOT" && BEANS_SANITIZE=address,undefined \
            "$BEANSC" build "$src" -o "$out/${name}_asan") \
            >"$out/${name}_asan.build" 2>&1; then
        echo "--- w8b-sanitize FAILED: tests/$name.b would not build under ASan/UBSan ---" >&2
        sed -n '1,40p' "$out/${name}_asan.build" >&2
        failed=1
        return
    fi
    set +e
    (cd "$ROOT" && ASAN_OPTIONS="detect_leaks=$asan_detect_leaks:halt_on_error=1" \
        BEANS_NO_POOL=1 "$out/${name}_asan") \
        >"$out/${name}_asan.stdout" 2>"$out/${name}_asan.stderr"
    local status=$?
    set -e
    ran=$((ran + 1))
    if [[ $status -ne 0 ]] || grep -Eq "$BAD" "$out/${name}_asan.stderr"; then
        echo "--- w8b-sanitize FAILED: tests/$name.b under ASan/UBSan (exit $status) ---" >&2
        sed -n '1,120p' "$out/${name}_asan.stderr" >&2
        failed=1
        return
    fi
    # Rule 1: the instrumented program must still be right.
    if ! diff -u "$want" "$out/${name}_asan.stdout" >"$out/${name}_asan.diff"; then
        echo "--- w8b-sanitize FAILED: tests/$name.b prints DIFFERENT bytes under ASan ---" >&2
        echo "    a sanitized build that changes the answer is a finding, not noise" >&2
        head -60 "$out/${name}_asan.diff" >&2
        failed=1
        return
    fi
    echo "ok w8b-sanitize/asan tests/$name.b — clean, and byte-identical to the golden"
}

# ---- TSan ----------------------------------------------------------------
#
# What TSan can and cannot see here has to be said, because the answer is not
# "everything". The Beans runtime switches fiber stacks and does NOT call
# `__tsan_switch_to_fiber` — there is no `__tsan` anywhere in `runtime/` — so
# TSan models a fiber switch as ordinary execution on one thread. For latte
# that is the *conservative* direction on the two live suites: work that ran on
# two fibers of one worker looks like one thread to TSan, so a race between
# them is not reported. What it does check, and what nothing else in this repo
# checks at all, is every REAL thread boundary: the OS-thread client beside the
# server, the accept loop against the connection fibers' shared state, and the
# runtime's own locks, ARC counters and collector.
run_tsan() {
    local name=$1
    local src="$ROOT/tests/$name.b"
    local want="$ROOT/tests/$name.out"
    if [[ ! -f "$src" || ! -f "$want" ]]; then
        echo "--- w8b-sanitize FAILED: tests/$name.b or its golden is missing ---" >&2
        failed=1
        return
    fi
    if ! (cd "$ROOT" && BEANS_SANITIZE=thread \
            "$BEANSC" build "$src" -o "$out/${name}_tsan") \
            >"$out/${name}_tsan.build" 2>&1; then
        # A build that will not link under TSan is a FAILURE, not a skip: the
        # toolchain is present (it just built the ASan leg) and something in
        # this program refused it.
        echo "--- w8b-sanitize FAILED: tests/$name.b would not build under TSan ---" >&2
        sed -n '1,40p' "$out/${name}_tsan.build" >&2
        failed=1
        return
    fi
    set +e
    (cd "$ROOT" && TSAN_OPTIONS="halt_on_error=0" BEANS_NO_POOL=1 \
        "$out/${name}_tsan") >"$out/${name}_tsan.stdout" 2>"$out/${name}_tsan.stderr"
    local status=$?
    set -e
    ran=$((ran + 1))
    if grep -q 'WARNING: ThreadSanitizer' "$out/${name}_tsan.stderr"; then
        echo "--- w8b-sanitize FAILED: TSan reported a race in tests/$name.b ---" >&2
        sed -n '1,200p' "$out/${name}_tsan.stderr" >&2
        failed=1
        return
    fi
    # TSan aborting at start-up is the runtime refusing to map its shadow, not
    # a fault in the program. It is a SKIP and it says so; a real race prints
    # WARNING and is caught above, before this.
    if grep -q 'ThreadSanitizer: CHECK failed' "$out/${name}_tsan.stderr"; then
        echo "SKIP w8b-sanitize/tsan tests/$name.b: ThreadSanitizer could not start on this host."
        echo "   NOT CHECKED: races across the real thread boundaries in tests/$name.b."
        sed -n '1,6p' "$out/${name}_tsan.stderr" >&2
        return
    fi
    if [[ $status -ne 0 ]]; then
        echo "--- w8b-sanitize FAILED: tests/$name.b exited $status under TSan ---" >&2
        sed -n '1,80p' "$out/${name}_tsan.stderr" >&2
        failed=1
        return
    fi
    if ! diff -u "$want" "$out/${name}_tsan.stdout" >"$out/${name}_tsan.diff"; then
        echo "--- w8b-sanitize FAILED: tests/$name.b prints DIFFERENT bytes under TSan ---" >&2
        head -60 "$out/${name}_tsan.diff" >&2
        failed=1
        return
    fi
    echo "ok w8b-sanitize/tsan tests/$name.b — no race reported, and byte-identical to the golden"
}

if [[ $do_asan -eq 1 ]]; then
    asan_runtime_control
    asan_reach_control
    for name in "${SUITES[@]}"; do
        [[ -z "$only" || "$only" == "$name" ]] || continue
        run_asan "$name"
    done
fi
if [[ $do_tsan -eq 1 ]]; then
    tsan_reach_control
    for name in "${SUITES[@]}"; do
        [[ -z "$only" || "$only" == "$name" ]] || continue
        run_tsan "$name"
    done
fi

if [[ $ran -eq 0 ]]; then
    echo "no suite matched \"$only\"" >&2
    exit 1
fi
if [[ $failed -ne 0 ]]; then
    echo "w8b-sanitize: FAILED" >&2
    exit 1
fi
note=""
[[ $skipped -gt 0 ]] && note=" — $skipped control(s) SKIPPED, read the SKIP lines above"
if [[ -z "$only" ]]; then
    outside=$(uninstrumented)
    outside_count=$(printf '%s' "$outside" | grep -c . || true)
    if [[ $outside_count -gt 0 ]]; then
        echo "NOT INSTRUMENTED by w8b-sanitize — $outside_count gated suite(s):"
        echo "   $(printf '%s ' $outside)"
        echo "   A chosen subset, not an oversight: an instrumented run costs 20-40x a"
        echo "   plain one and, while BLOCKERS.md B15 stands, these would only re-cover"
        echo "   beans_rt.c. Printed so that a suite added later is visible here rather"
        echo "   than absent from a summary that looks complete."
        note="$note — $outside_count gated suite(s) NOT instrumented, named above"
    fi
fi
echo "ok w8b-sanitize — $ran instrumented run(s), every one clean and byte-identical to its golden${note}"
