#!/usr/bin/env bash
# probes/w8_leaks.sh — the second half of PLAN.md gate 10's second half.
#
# `tests/w8_hostile.b` proves the corpus never PANICS: a panic in Beans ends
# the process, so a run that reaches its last line panicked on none of its
# shapes and `test.sh` compares the whole transcript. Nothing in `test.sh`
# proves the other half of the sentence — "and never leak" — because latte's
# gate has no `leaks` leg at all.
#
# This is that leg. It builds the hostile corpus natively and runs it under
# macOS `leaks --atExit`. Every shape allocates two `Circuit`s, four `Channel`s
# and two `AtomicInt`s and mounts a page, so ~9,000 shapes is ~18,000 circuits
# built and dropped — which is exactly the shape a retain cycle or a channel
# nobody closed would show up in.
#
# It is NOT wired into `test.sh`, for the reason `probes/run_all.sh` gives
# about itself: the native build plus the instrumented run takes minutes, and a
# gate people stop running is worse than one that says what it did not check.
# Run it on a compiler bump, on any change to `circuit.b` or `wire.b`, and
# before a release.
#
#     probes/w8_leaks.sh
#
# On a machine with no `leaks` it prints SKIP and says, in the same breath,
# that the no-leak claim is UNVERIFIED on this run — RULES.md 5: a gate that
# skips quietly on a missing tool dies silently when the layout moves.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
beans=$(cd "$root/../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"
suite="$root/tests/w8_hostile.b"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
[[ -f "$suite"  ]] || { echo "no suite at $suite" >&2; exit 1; }
version=$("$beansc" --version)
case "$version" in
    *"0.1.40"*) ;;
    *) echo "latte is recorded against beansc 0.1.40, this is: $version" >&2; exit 1 ;;
esac

if ! command -v leaks >/dev/null 2>&1; then
    echo "SKIP w8_leaks: no \`leaks\` on this machine (macOS only)."
    echo "     PLAN.md gate 10's \"and never leak\" is UNVERIFIED on this run."
    echo "     tests/w8_hostile.b still proves the corpus never panics; nothing"
    echo "     on this machine has checked that it never leaks."
    exit 0
fi

[[ -z ${BEANS_RUNTIME:-}  && -f "$beans/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$beans/runtime/beans_rt.c"
[[ -z ${BEANS_STDLIB:-}   && -d "$beans/stdlib/std"         ]] && export BEANS_STDLIB="$beans/stdlib/std"
[[ -z ${BEANS_ENCODING:-} && -d "$beans/runtime/encoding"   ]] && export BEANS_ENCODING="$beans/runtime/encoding"
[[ -z ${BEANS_NET:-}      && -d "$beans/runtime/net"        ]] && export BEANS_NET="$beans/runtime/net"
[[ -z ${BEANS_LOG:-}      && -d "$beans/runtime/log"        ]] && export BEANS_LOG="$beans/runtime/log"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "beansc: $beansc ($(shasum -a 256 "$beansc" | cut -c1-12)) — $version"
echo "building tests/w8_hostile.b natively ..."
if ! (cd "$root" && "$beansc" build "$suite" -o "$tmp/hostile.bin") >"$tmp/build.log" 2>&1; then
    echo "--- w8_leaks: the hostile corpus did not build ---" >&2
    cat "$tmp/build.log" >&2
    exit 1
fi

echo "running it under leaks --atExit ..."
# `leaks` exits non-zero when it finds leaks, so the run is guarded and the
# report is read either way. The binary's own exit status matters too: a
# corpus that FAILED its checks and a corpus that leaked are different
# findings and this prints both.
set +e
leaks --atExit -- "$tmp/hostile.bin" >"$tmp/leaks.log" 2>&1
leaks_status=$?
set -e

tail_line=$(grep -E "^[0-9]+ hostile shapes, " "$tmp/leaks.log" | tail -1 || true)
summary=$(grep -oE "[0-9]+ leaks for [0-9]+ total leaked bytes" "$tmp/leaks.log" | tail -1 || true)

if [[ -z "$tail_line" ]]; then
    echo "--- w8_leaks: the corpus did not reach its last line ---" >&2
    echo "    That is a PANIC, not a leak. The last 40 lines:" >&2
    tail -40 "$tmp/leaks.log" >&2
    exit 1
fi
echo "corpus: $tail_line"

case "$tail_line" in
    *", 0 failed") ;;
    *) echo "--- w8_leaks: the corpus ran but its own checks failed ---" >&2
       grep -A3 "^FAIL" "$tmp/leaks.log" | head -40 >&2
       exit 1 ;;
esac

if [[ -z "$summary" ]]; then
    echo "--- w8_leaks: leaks printed no summary line ---" >&2
    tail -40 "$tmp/leaks.log" >&2
    exit 1
fi

case "$summary" in
    "0 leaks for 0 total leaked bytes")
        echo "ok w8_leaks — $summary over the whole hostile corpus"
        ;;
    *)
        echo "--- w8_leaks: leaks did not report zero: $summary ---" >&2
        grep -E "Leak:|leaks for" "$tmp/leaks.log" | head -40 >&2
        exit 1
        ;;
esac

exit 0
