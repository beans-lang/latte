#!/usr/bin/env bash
# w8b_budgets.sh — PLAN.md gate 11's four timing budgets.
#
#   "Budgets pinned in W8: render plus diff of a virtualised 50,000-row table,
#    event round trip at p50, bytes per batch before and after deflate,
#    resident memory per idle circuit."
#
# **This is NOT part of `test.sh` and must not become part of it.** Every
# number here is a duration or a byte count on one machine, and neither is a
# golden. A gate that asserted a ceiling would go red on a loaded machine for a
# reason that is not a bug and — worse — would stay green on a fast one after a
# real regression. So this prints numbers and the conditions they were taken
# under; `lanes/W8b.md` records them; a reader compares.
#
# **It refuses to call a number a measurement on a busy machine.** The first
# thing it does is read the load average and the top processes, print them, and
# say plainly whether the machine was quiet. A number taken under load looks
# exactly like data and is noise, and the only defence is that the conditions
# are printed beside it every time. `--anyway` takes the numbers regardless and
# stamps every line as taken under load.
#
#   ./w8b_budgets.sh              refuse if the machine is busy
#   ./w8b_budgets.sh --anyway     take them anyway, and say so
#   ./w8b_budgets.sh --load       print the machine's state and stop
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

anyway=0
load_only=0
for arg in "$@"; do
    case "$arg" in
        --anyway) anyway=1 ;;
        --load)   load_only=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

cpus=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1) )

# The one-minute load average, as an integer of hundredths, so bash can compare
# it without a floating-point shell.
load_hundredths() {
    local raw
    raw=$(uptime | sed -E 's/.*load averages?: *//' | awk '{ print $1 }' | tr -d ',')
    awk -v v="$raw" 'BEGIN { printf "%d", v * 100 }'
}

say_machine() {
    echo "machine: $(uname -s) $(uname -m), $cpus CPUs"
    echo "machine: $(uptime | sed -E 's/^ *//')"
    echo "machine: busiest processes right now —"
    ps -Ao pcpu,comm -r 2>/dev/null | sed -n '2,6p' | while read -r pct cmd; do
        echo "machine:   ${pct}%  $(basename "$cmd")"
    done
}

say_machine
load=$(load_hundredths)
# Half a core per CPU, as the line between "something else is running" and "the
# machine is mine". It is a threshold and not a law: what matters is that the
# number is printed above and the verdict is printed below, so a reader can
# disagree with it knowing what it was.
ceiling=$(( cpus * 50 ))
quiet=1
if (( load > ceiling )); then quiet=0; fi
if (( quiet == 1 )); then
    echo "machine: QUIET — 1-minute load $((load / 100)).$((load % 100)) on $cpus CPUs is under the $((ceiling / 100)).00 line"
else
    echo "machine: BUSY — 1-minute load $((load / 100)).$((load % 100)) on $cpus CPUs is over the $((ceiling / 100)).00 line"
fi
echo ""

if (( load_only == 1 )); then exit 0; fi
if (( quiet == 0 && anyway == 0 )); then
    echo "REFUSED: the machine is busy, so nothing here would be a measurement."
    echo "   NOT MEASURED: render plus diff of a virtualised 50,000-row table,"
    echo "   event round trip at p50, bytes per batch before and after deflate,"
    echo "   resident memory per idle circuit."
    echo "   Wait for the machine to settle, or run with --anyway and read every"
    echo "   number as an upper bound taken under the load printed above."
    exit 0
fi
stamp="machine QUIET"
if (( quiet == 0 )); then stamp="MACHINE BUSY — every number below is an upper bound, not a measurement"; fi

out="$ROOT/build/w8b/budgets"
mkdir -p "$out"

# ---- B1, B2, B3 -----------------------------------------------------------
echo "=== B1 / B2 / B3 — $stamp ==="
if ! (cd "$ROOT" && "$BEANSC" build --release tests/_w8b_budget.b -o "$out/budget") \
        >"$out/budget.build" 2>&1; then
    echo "--- w8b-budgets FAILED: tests/_w8b_budget.b would not build ---" >&2
    sed -n '1,40p' "$out/budget.build" >&2
    exit 1
fi
(cd "$ROOT" && "$out/budget")
echo ""

# ---- B4 -------------------------------------------------------------------
#
# Two `ps` samples around a program that holds still between them. The program
# announces each point on stderr and then blocks on stdin; this end reads the
# announcement, samples, and writes a line back. No sleeps: a sleep long enough
# to be safe on a loaded machine is slow and one short enough to be quick is
# wrong.
echo "=== B4  resident memory per idle circuit — $stamp ==="
if ! (cd "$ROOT" && "$BEANSC" build --release tests/_w8b_rss.b -o "$out/rss") \
        >"$out/rss.build" 2>&1; then
    echo "--- w8b-budgets FAILED: tests/_w8b_rss.b would not build ---" >&2
    sed -n '1,40p' "$out/rss.build" >&2
    exit 1
fi

fifo="$out/rss.in"
rm -f "$fifo" "$out/rss.err"
mkfifo "$fifo"
(cd "$ROOT" && "$out/rss") <"$fifo" >"$out/rss.out" 2>"$out/rss.err" &
rss_pid=$!
# Hold the write end open for the life of the run: a fifo whose only writer
# closes gives the reader EOF, and the program would run straight through both
# waits with nothing sampled.
exec 4>"$fifo"
cleanup_rss() {
    exec 4>&- || true
    kill "$rss_pid" 2>/dev/null || true
    wait "$rss_pid" 2>/dev/null || true
    rm -f "$fifo"
}
trap cleanup_rss EXIT

wait_for() {                     # <marker>; up to 60s
    local marker=$1 i
    for i in $(seq 1 1200); do
        grep -q "$marker" "$out/rss.err" 2>/dev/null && return 0
        kill -0 "$rss_pid" 2>/dev/null || return 1
        sleep 0.05
    done
    return 1
}
sample() { ps -o rss= -p "$rss_pid" 2>/dev/null | tr -d ' '; }

if ! wait_for W8B-RSS-BASE; then
    echo "--- w8b-budgets FAILED: the RSS probe never reached its base point ---" >&2
    cat "$out/rss.err" >&2
    exit 1
fi
base_kb=$(sample)
echo "B4: base RSS $base_kb KB, with the set and the factory built and no circuits open"
echo "" >&4

if ! wait_for W8B-RSS-OPEN; then
    echo "--- w8b-budgets FAILED: the RSS probe never opened its circuits ---" >&2
    cat "$out/rss.err" >&2
    exit 1
fi
open_kb=$(sample)
opened=$(awk -F'circuits=' '/W8B-RSS-OPEN/ { split($2, a, " "); print a[1]; exit }' "$out/rss.err")
held=$(awk -F'held=' '/W8B-RSS-OPEN/ { split($2, a, " "); print a[1]; exit }' "$out/rss.err")
echo "B4: open RSS $open_kb KB, with $opened circuit(s) open and $held held"
echo "" >&4
wait_for W8B-RSS-DONE || true

if [[ -n "$base_kb" && -n "$open_kb" && -n "$opened" && "$opened" != "0" ]]; then
    delta_kb=$((open_kb - base_kb))
    per_circuit=$(( (delta_kb * 1024) / opened ))
    echo "B4: $delta_kb KB for $opened circuits = $per_circuit bytes per idle circuit"
    echo "B4: an idle circuit here is opened, attached, rendered once and its first"
    echo "B4: batch taken — a live component tree and the frame the differ compares"
    echo "B4: against. It holds NO socket; that memory is espresso's and std.websocket's."
    echo "B4: memory pool ON (the default a deployment runs with), --release build."
else
    echo "B4: NOT MEASURED — one of the two samples was empty (base='$base_kb' open='$open_kb' circuits='$opened')" >&2
fi
grep 'W8B-RSS' "$out/rss.err" | sed 's/^/B4 probe: /'
echo ""
echo "=== conditions ==="
say_machine
echo "compiler: $BEANSC ($(shasum -a 256 "$BEANSC" | cut -c1-12))"
