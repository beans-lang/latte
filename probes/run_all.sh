#!/usr/bin/env bash
# probes/run_all.sh — every probe, both backends, plus the recorded refusals.
#
# Why this is NOT wired into `test.sh`: the probes measure the *compiler's*
# behaviour, not latte's, and they are slow — p1_duplex holds a socket open for
# six seconds, p5_activate benchmarks 1,000 activations six ways, p6_cycle
# makes 175,000 objects. Putting that in the edit-loop gate is how people stop
# running the edit-loop gate. This runs on a compiler bump, and on nothing else.
#
#   ./run_all.sh           every probe, both backends   (a few minutes)
#   ./run_all.sh --check   `beansc check` only          (seconds)
#
# The probes fall into three kinds and each is checked differently:
#
#   answers  must run on both backends and end with "probe <name>: ok". The
#            probe states its own verdict rather than this script guessing from
#            the output, because several probes print a deliberate `false` that
#            IS the recorded answer — p1_duplex's phase C is supposed to corrupt
#            the stream, and p3_generic's generic component is supposed to fail
#            to activate. A probe whose recorded failure started passing must
#            fail here too, because BLOCKERS.md would then be stale.
#   walls    are repros of BLOCKERS.md entries; they only have to still run.
#   p3_emitter_wall  must CHECK ok, RUN ok, and FAIL to build. If it ever
#            builds, B3 is fixed and probes/BUILDER.md's constraint is stale.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
beans=$(cd "$here/../../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
version=$("$beansc" --version)
echo "beansc: $beansc ($(shasum -a 256 "$beansc" | cut -c1-12)) — $version"
case "$version" in
    *"0.1.40"*) ;;
    *) echo "NOTE: the answers in ANSWERS.md were recorded against 0.1.40." >&2
       echo "      A different compiler here means every answer needs re-reading." >&2 ;;
esac

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

answers=(p1_duplex p2_channel p3_generic p5_partial p5_activate p6_cycle p7_chunked p8_builder)
walls=(p3_generic_wall p3_reflect_msg)
build_must_fail=(p3_emitter_wall)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-probes.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failed=0
ran=0

# Every probe directory must be accounted for by one of the lists above, or a
# probe added later is silently never run — the failure this workspace has
# shipped before (RULES.md 5).
shopt -s nullglob
for dir in "$here"/*/; do
    name=$(basename "$dir")
    case "$name" in *_bad) continue ;; esac
    known=0
    for n in "${answers[@]}" "${walls[@]}" "${build_must_fail[@]}"; do
        [[ "$n" == "$name" ]] && known=1
    done
    if [[ $known -eq 0 ]]; then
        echo "$name: not listed in run_all.sh — add it to answers/walls/build_must_fail" >&2
        failed=1
    fi
done

check_one() {
    local name=$1
    if (cd "$beans" && "$beansc" check "$here/$name/main.b") >"$tmp/$name.check" 2>&1; then
        return 0
    fi
    echo "--- $name: beansc check failed ---" >&2
    cat "$tmp/$name.check" >&2
    return 1
}

for name in "${answers[@]}" "${walls[@]}" "${build_must_fail[@]}"; do
    check_one "$name" || failed=1
done
[[ $check_only -eq 0 ]] || {
    [[ $failed -eq 0 ]] || { echo "probes: FAILED" >&2; exit 1; }
    echo "ok — every probe still type-checks"
    exit 0
}

run_both() {
    local name=$1
    if ! (cd "$beans" && "$beansc" run "$here/$name/main.b") >"$tmp/$name.interp" 2>&1; then
        echo "--- $name: failed under the interpreter ---" >&2
        cat "$tmp/$name.interp" >&2
        return 1
    fi
    if ! (cd "$beans" && "$beansc" build "$here/$name/main.b" -o "$tmp/$name.bin") \
            >"$tmp/$name.build" 2>&1; then
        echo "--- $name: failed to build natively ---" >&2
        cat "$tmp/$name.build" >&2
        return 1
    fi
    if ! (cd "$beans" && "$tmp/$name.bin") >"$tmp/$name.native" 2>&1; then
        echo "--- $name: failed to run natively ---" >&2
        cat "$tmp/$name.native" >&2
        return 1
    fi
    return 0
}

for name in "${answers[@]}"; do
    if run_both "$name"; then
        bad=0
        for leg in interp native; do
            if ! grep -qx "probe $name: ok" "$tmp/$name.$leg"; then
                echo "--- $name ($leg): the probe did not say it was ok ---" >&2
                tail -5 "$tmp/$name.$leg" >&2
                bad=1
            fi
        done
        # The two legs must also agree on everything but the timings, which is
        # the invariant this workspace actually runs on.
        if [[ $bad -eq 0 ]]; then
            echo "ok $name — both backends, the probe stands by its answer"
            ran=$((ran + 1))
        else
            failed=1
        fi
    else
        failed=1
    fi
done

for name in "${walls[@]}"; do
    if run_both "$name"; then
        echo "ok $name — still runs (its falses are the finding; read BLOCKERS.md)"
        ran=$((ran + 1))
    else
        failed=1
    fi
done

for name in "${build_must_fail[@]}"; do
    if ! (cd "$beans" && "$beansc" run "$here/$name/main.b") >"$tmp/$name.interp" 2>&1; then
        echo "--- $name: should run under the interpreter and did not ---" >&2
        cat "$tmp/$name.interp" >&2
        failed=1
    elif (cd "$beans" && "$beansc" build "$here/$name/main.b" -o "$tmp/$name.bin") \
            >"$tmp/$name.build" 2>&1; then
        echo "--- $name: it BUILT. B3 is fixed, and probes/BUILDER.md's" >&2
        echo "    'component<T> must be an instance method' constraint is now stale." >&2
        failed=1
    else
        echo "ok $name — still checks, still runs, still refused by the emitter (B3)"
        ran=$((ran + 1))
    fi
done

# probe 6's answer is half a deinit count and half `leaks` reporting zero, and
# a claim that is only ever made by hand is a claim nobody re-checks. macOS
# only — and it SAYS so rather than skipping quietly, because a gate that
# skips on a missing tool dies silently when the layout moves (RULES.md 5).
if command -v leaks >/dev/null 2>&1; then
    if (cd "$beans" && "$beansc" build "$here/p6_cycle/main.b" -o "$tmp/p6.bin") \
            >"$tmp/p6.leakbuild" 2>&1; then
        if leaks --atExit -- "$tmp/p6.bin" >"$tmp/p6.leaks" 2>&1 &&
           grep -q "0 leaks for 0 total leaked bytes" "$tmp/p6.leaks"; then
            echo "ok p6_cycle under leaks — $(grep -o '[0-9]* leaks for [0-9]* total leaked bytes' "$tmp/p6.leaks" | tail -1)"
        else
            echo "--- p6_cycle: leaks did not report zero ---" >&2
            grep -E "leaks for|Leak" "$tmp/p6.leaks" | tail -20 >&2
            failed=1
        fi
    else
        echo "--- p6_cycle: could not build for the leaks run ---" >&2
        cat "$tmp/p6.leakbuild" >&2
        failed=1
    fi
else
    echo "SKIP p6_cycle under leaks: no \`leaks\` on this machine (macOS only)."
    echo "     ANSWERS.md \u00a76's zero-leaks claim is UNVERIFIED on this run."
fi

bash "$here/check_refusals.sh" || failed=1

[[ $failed -eq 0 ]] || { echo "probes: FAILED" >&2; exit 1; }
echo "ok — $ran probe(s) re-verified on both backends"
