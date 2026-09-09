#!/usr/bin/env bash
# probes/check_refusals.sh — every recorded refusal, re-checked.
#
# A probe's answer is half "this works" and half "this is refused, with this
# message". The second half rots silently: a compiler that starts accepting a
# shape the design was built around leaves the recorded refusal confidently
# wrong, with nothing to notice. So each `probes/*_bad/` holds a program that
# must NOT compile and the exact answer beansc gave it, in `expected.txt`, and
# this script diffs them.
#
# Adding a refusal means adding `<name>_bad/main.b`, `<name>_bad/beans.pot`
# and `<name>_bad/expected.txt` — this script finds it by shape, so a new one
# cannot be forgotten, and a directory with no expected.txt is a failure and
# not a skip.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
beans=$(cd "$here/../../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
case "$("$beansc" --version)" in
    *"0.1.41"*) ;;
    *) echo "the refusals are recorded against beansc 0.1.41" >&2; exit 1 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-refusals.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
dirs=("$here"/*_bad)
if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "no *_bad probes found under $here — the layout moved" >&2
    exit 1
fi

failed=0
for dir in "${dirs[@]}"; do
    name=$(basename "$dir")
    entry="$dir/main.b"
    want="$dir/expected.txt"
    if [[ ! -f "$entry" ]]; then
        echo "$name: no main.b" >&2; failed=1; continue
    fi
    if [[ ! -f "$want" ]]; then
        echo "$name: no expected.txt — record the refusal, do not skip it" >&2
        failed=1; continue
    fi
    if (cd "$beans" && "$beansc" check "$entry") >"$tmp/$name.out" 2>&1; then
        echo "$name: beansc ACCEPTED a program that must be refused" >&2
        failed=1; continue
    fi
    # Paths differ per worktree; the messages do not.
    sed -e "s|^.*/probes/|probes/|" "$tmp/$name.out" >"$tmp/$name.clean"
    if diff -u "$want" "$tmp/$name.clean"; then
        echo "ok $name — refused, with the recorded message"
    else
        echo "--- $name: the refusal changed ---" >&2
        failed=1
    fi
done

[[ $failed -eq 0 ]] || { echo "refusals: FAILED" >&2; exit 1; }
echo "ok — ${#dirs[@]} recorded refusal(s), all still refused"
