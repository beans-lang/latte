#!/usr/bin/env bash
# Is every checked-in generated file what the compiler would write today?
#
# Generated Beans is checked in so a consumer can build without running a
# markup compiler. That convenience has one failure mode and it is silent: a
# `.bx` file changes, nobody regenerates, and the program keeps doing what the
# markup used to say. A hand edit to a generated file is the same failure with
# a different cause.
#
# So this regenerates the whole tree into a scratch directory and diffs. It
# never writes into the repository, which matters: a gate that "fixed" the
# drift would hide exactly the change it exists to report.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-generated.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/tools/generate.sh" "$tmp" >"$tmp/generate.log" 2>&1 || {
    echo "--- generated FAILED: the generator refused ---" >&2
    cat "$tmp/generate.log" >&2
    exit 1
}
sed 's/^/  /' "$tmp/generate.log"

status=0
checked=0
while IFS= read -r file; do
    relative=${file#"$tmp/"}
    if [[ ! -f "$ROOT/$relative" ]]; then
        echo "--- generated FAILED: $relative is not checked in ---" >&2
        echo "    run tools/generate.sh and commit what it writes." >&2
        status=1
        continue
    fi
    checked=$((checked + 1))
    if ! diff -u "$ROOT/$relative" "$file" >"$tmp/one.diff"; then
        echo "--- generated FAILED: $relative is stale or was edited by hand ---" >&2
        echo "    < what is checked in, > what the compiler writes now" >&2
        head -40 "$tmp/one.diff" >&2
        status=1
    fi
done < <(find "$tmp" -name "*.b" | sort)

# And the other direction: a generated file whose markup is gone.
while IFS= read -r file; do
    relative=${file#"$ROOT/"}
    if [[ ! -f "$tmp/$relative" ]]; then
        echo "--- generated FAILED: $relative has no markup behind it any more ---" >&2
        echo "    delete it, or restore the .bx file it came from." >&2
        status=1
    fi
done < <(find "$ROOT/generated" -name "*.b" 2>/dev/null | sort)

if [[ $checked -eq 0 ]]; then
    echo "--- generated FAILED: nothing was compared ---" >&2
    exit 1
fi
[[ $status -eq 0 ]] && echo "ok generated — $checked file(s) match what the compiler writes"
exit $status
