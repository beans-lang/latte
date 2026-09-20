#!/usr/bin/env bash
# Does the gallery still show every control latte draws?
#
# The list comes out of the compiler — `latte-bx vocabulary --target canvas`
# names what the canvas target draws — so adding a control to latte and
# forgetting the showcase is a failure here rather than a thing nobody notices.
#
# A control that cannot be shown goes in EXCUSED below, with the reason. An
# empty excuse is refused: "it does not work" has to say why, next to the name.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GALLERY="$ROOT/examples/showcase/site/gallery_page.bx"
BEANSC="${BEANSC:-${BEANS_ROOT:-$ROOT/../../beans}/build/beansc}"

# tag|why it is not in the gallery
EXCUSED=(
  "Canvas|no legal markup: bare is refused for having no shape, and with a shape it is refused for laying nothing out. The shapes themselves are the canvas nodes — see docs/unfinished.md"
)

[[ -f "$GALLERY" ]] || { echo "--- gallery FAILED: $GALLERY is missing ---" >&2; exit 1; }
[[ -x "$BEANSC" ]] || { echo "--- gallery FAILED: no beansc at $BEANSC ---" >&2; exit 1; }

# "controls" is what the canvas target draws; "controlsNotYetDrawn" is the
# other list and is deliberately not read here.
drawn=$(cd "$ROOT" && "$BEANSC" run examples/latte_bx.b -- vocabulary --target canvas 2>/dev/null \
        | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["controls"]))')

if [[ -z "$drawn" ]]; then
    echo "--- gallery FAILED: the vocabulary named no controls ---" >&2
    echo "    latte-bx vocabulary --target canvas changed shape, so this stopped" >&2
    echo "    reading it and would pass for ever after." >&2
    exit 1
fi

status=0
shown=0
skipped=0
while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    why=""
    excused=0
    for row in "${EXCUSED[@]}"; do
        [[ "${row%%|*}" == "$tag" ]] || continue
        excused=1
        why="${row#*|}"
    done
    if [[ $excused -eq 1 ]]; then
        if [[ -z "$why" ]]; then
            echo "--- gallery FAILED: $tag is excused with no reason ---" >&2
            status=1
            continue
        fi
        echo "  skip $tag — $why"
        skipped=$((skipped + 1))
        continue
    fi
    if grep -qE "<$tag[[:space:]/>]" "$GALLERY"; then
        shown=$((shown + 1))
        continue
    fi
    echo "--- gallery FAILED: <$tag> is drawn by latte and is not in the gallery ---" >&2
    echo "    Add it to examples/showcase/site/gallery_page.bx, or give it a row" >&2
    echo "    in EXCUSED in this script saying why it cannot be shown." >&2
    status=1
done <<< "$drawn"

# And the other direction: an excuse for a control latte no longer draws.
for row in "${EXCUSED[@]}"; do
    tag="${row%%|*}"
    if ! grep -qx "$tag" <<< "$drawn"; then
        echo "--- gallery FAILED: $tag is excused and is not a control latte draws ---" >&2
        echo "    Delete its row in EXCUSED; the reason it carries is now about nothing." >&2
        status=1
    fi
done

if [[ $status -eq 0 ]]; then
    echo "ok gallery — $shown control(s) shown, $skipped excused with a reason"
fi
exit $status
