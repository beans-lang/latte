#!/usr/bin/env bash
# Two hand-written lists no compiler can hold together: the `WidgetKind` cases
# and the `all()` that walks them. A missing push makes a kind invisible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/controls/widget_kind.b"

if [[ ! -f "$SRC" ]]; then
    echo "--- vocabulary FAILED: $SRC is missing ---" >&2
    exit 1
fi

declared=$(awk '/^pub enum WidgetKind \{/ { inside = 1; next }
                inside && /^\}/ { exit }
                inside' "$SRC" | sed -E 's|//.*||' | grep -oE '^[[:space:]]+[a-z_]+[[:space:]]*$' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

listed=$(grep -oE 'every\.push\(WidgetKind\.[a-z_]+\)' "$SRC" | sed -E 's/.*WidgetKind\.([a-z_]+)\)/\1/')

if [[ -z "$declared" ]]; then
    echo "--- vocabulary FAILED: no enum cases were found in controls/widget_kind.b ---" >&2
    echo "    The enum's shape changed and this gate stopped reading it." >&2
    exit 1
fi
if [[ -z "$listed" ]]; then
    echo "--- vocabulary FAILED: no every.push(WidgetKind.…) was found ---" >&2
    exit 1
fi

if [[ "$declared" != "$listed" ]]; then
    echo "--- vocabulary FAILED: WidgetKind.all() is not the enum ---" >&2
    diff <(echo "$declared") <(echo "$listed") | sed 's/^/    /' >&2
    echo "    < declared in the enum, > pushed by all(). Order matters: the" >&2
    echo "    doc comment on all() says declaration order, and a golden reads it." >&2
    exit 1
fi

count=$(echo "$declared" | wc -l | tr -d ' ')
echo "  ok vocabulary/kinds — $count kind(s), declared and walked in the same order"

# The retired-tag sentences. Two lists of the same names, one in the compiler
# and one in the runtime, and a tag on only one side is a tag with no message.
compiler=$(perl -0ne 'print $1 if /pub fn canvas_retired_tag\(tag: string\) -> string \{(.*?)\n\}/s' \
    "$ROOT/bx/canvas_widgets.b" | { grep -oE 'tag == "[A-Za-z]+"' || true; } |
    sed -E 's/tag == "(.*)"/\1/' | sort -u)
runtime=$(perl -0ne 'print $1 if /pub static fn retired\(tag: string\) -> string \{(.*?)\n    \}/s' \
    "$ROOT/compose/vocabulary.b" | { grep -oE 'tag == "[A-Za-z]+"' || true; } |
    sed -E 's/tag == "(.*)"/\1/' | sort -u)

if [[ -z "$compiler" || -z "$runtime" ]]; then
    echo "--- vocabulary FAILED: a retired-tag list read empty ---" >&2
    echo "    One of the two functions changed shape and this stopped reading it." >&2
    exit 1
fi
if [[ "$compiler" != "$runtime" ]]; then
    echo "--- vocabulary FAILED: the retired tags do not match ---" >&2
    diff <(echo "$compiler") <(echo "$runtime") | sed 's/^/    /' >&2
    echo "    < bx.canvas_retired_tag, > compose.Vocabulary.retired" >&2
    exit 1
fi
echo "  ok vocabulary/retired — $(echo "$compiler" | wc -l | tr -d ' ') tag(s) named on both sides"
