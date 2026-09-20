#!/usr/bin/env bash
# The numbers that cross the WebAssembly boundary are written twice: once in
# `platform/constants.b` and once in the JavaScript that talks to it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

need() {
    if [[ ! -f "$ROOT/$1" ]]; then
        echo "--- constants FAILED: $1 is missing ---" >&2
        exit 1
    fi
}
need platform/constants.b
need js/latte-input.js
need js/latte-runtime.js
need browser/browser_host.b

# A pair table the JavaScript writes as `NAME: 7,`, against the Beans constant
# of the same name under `prefix`. An empty side is a check that stopped reading.
compare_named() {
    local label="$1" js_file="$2" js_object="$3" beans_file="$4" prefix="$5"
    js_object="$js_object" perl -0ne 'print $1 if /const \Q$ENV{js_object}\E\s*=\s*\{(.*?)\}/s' \
        "$ROOT/$js_file" |
        { grep -oE '[A-Z_]+:[[:space:]]*[0-9]+' || true; } |
        sed -E 's/:[[:space:]]*/ /' | sort > "$tmp/$label.js"

    while read -r name value; do
        grep -E "^pub const ${prefix}${name}:[[:space:]]*int[[:space:]]*=[[:space:]]*${value}\$" \
            "$ROOT/$beans_file" >/dev/null 2>&1 || echo "$name $value" >> "$tmp/$label.bad"
    done < "$tmp/$label.js"

    local count
    count=$(wc -l < "$tmp/$label.js" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        echo "--- constants FAILED: $js_object was not found in $js_file ---" >&2
        failed=1
        return
    fi
    if [[ -s "$tmp/$label.bad" ]]; then
        echo "--- constants FAILED: $js_file $js_object does not match ${prefix}* ---" >&2
        sed "s|^|    no ${prefix}|" "$tmp/$label.bad" >&2
        failed=1
        return
    fi
    echo "  ok constants/$label — $count number(s) agree with ${prefix}*"
}

compare_named events   js/latte-input.js EVENT platform/constants.b EV_
compare_named modifiers js/latte-input.js MOD   platform/constants.b MOD_

# The key codes, less the sentinels. Compared as a set of numbers rather than name by name: the
# JavaScript keys by the DOM's spelling (`Enter`) and Beans by its own
# (`KEY_RETURN`), so a name map here would be a third table to keep.
perl -0ne 'print $1 if /const KEYS\s*=\s*\{(.*?)\}/s' "$ROOT/js/latte-input.js" |
    { grep -oE ':[[:space:]]*[0-9]+' || true; } |
    { grep -oE '[0-9]+' || true; } > "$tmp/keys.js.raw"
{ grep -oE '^const KEY_CHARACTER = [0-9]+' "$ROOT/js/latte-input.js" || true; } |
    { grep -oE '[0-9]+$' || true; } >> "$tmp/keys.js.raw"
sort -n -u "$tmp/keys.js.raw" > "$tmp/keys.js"

{ grep -E '^pub const KEY_[A-Z0-9_]+:[[:space:]]*int[[:space:]]*=' "$ROOT/platform/constants.b" || true; } |
    { grep -vE '^pub const KEY_(UNKNOWN|PROPERTY|TEXT|COUNT):' || true; } |
    { grep -oE '=[[:space:]]*[0-9]+' || true; } |
    { grep -oE '[0-9]+' || true; } | sort -n -u > "$tmp/keys.beans"

if [[ ! -s "$tmp/keys.js" || ! -s "$tmp/keys.beans" ]]; then
    echo "--- constants FAILED: one of the key tables read empty ---" >&2
    failed=1
elif ! diff -q "$tmp/keys.beans" "$tmp/keys.js" >/dev/null; then
    echo "--- constants FAILED: the key codes do not match ---" >&2
    diff "$tmp/keys.beans" "$tmp/keys.js" | sed 's/^/    /' >&2
    echo "    < platform/constants.b KEY_*, > js/latte-input.js KEYS" >&2
    failed=1
else
    echo "  ok constants/keys — $(wc -l < "$tmp/keys.beans" | tr -d ' ') key code(s) on both sides"
fi

# The mouse buttons, by value: the JavaScript maps a DOM button number onto a
# platform one, so only the platform side has names.
perl -0ne 'print $1 if /const BUTTON\s*=\s*\{(.*?)\}/s' "$ROOT/js/latte-input.js" |
    { grep -oE ':[[:space:]]*[0-9]+' || true; } |
    { grep -oE '[0-9]+' || true; } | sort -n -u > "$tmp/buttons.js"
{ grep -E '^pub const BTN_[A-Z]+:' "$ROOT/platform/constants.b" || true; } |
    { grep -oE '=[[:space:]]*[0-9]+' || true; } |
    { grep -oE '[0-9]+' || true; } | sort -n -u > "$tmp/buttons.beans"
if [[ ! -s "$tmp/buttons.js" ]]; then
    echo "--- constants FAILED: BUTTON was not found in js/latte-input.js ---" >&2
    failed=1
elif ! diff -q "$tmp/buttons.beans" "$tmp/buttons.js" >/dev/null; then
    echo "--- constants FAILED: the mouse buttons do not match ---" >&2
    diff "$tmp/buttons.beans" "$tmp/buttons.js" | sed 's/^/    /' >&2
    failed=1
else
    echo "  ok constants/buttons — $(wc -l < "$tmp/buttons.beans" | tr -d ' ') button(s) on both sides"
fi

# The capability codes. `BrowserHost.code` states them rather than deriving
# them from the enum, so this is what holds that statement to the page.
perl -0ne 'print $1 if /const CAPABILITY\s*=\s*\{(.*?)\}/s' "$ROOT/js/latte-runtime.js" |
    { grep -oE '[A-Z_]+:[[:space:]]*[0-9]+' || true; } |
    sed -E 's/:[[:space:]]*/ /' | tr 'A-Z' 'a-z' | sort > "$tmp/cap.js"
awk '/static fn code\(what: platform.Capability\)/ { inside = 1; next }
     inside && /^        \}/ { exit }
     inside' "$ROOT/browser/browser_host.b" |
    { grep -oE '[a-z_]+ => [0-9]+' || true; } | sed -E 's/ => / /' | sort > "$tmp/cap.beans"
if [[ ! -s "$tmp/cap.js" || ! -s "$tmp/cap.beans" ]]; then
    echo "--- constants FAILED: one of the capability tables read empty ---" >&2
    failed=1
elif ! diff -q "$tmp/cap.beans" "$tmp/cap.js" >/dev/null; then
    echo "--- constants FAILED: the capability codes do not match ---" >&2
    diff "$tmp/cap.beans" "$tmp/cap.js" | sed 's/^/    /' >&2
    echo "    < browser/browser_host.b, > js/latte-runtime.js" >&2
    failed=1
else
    echo "  ok constants/capabilities — $(wc -l < "$tmp/cap.beans" | tr -d ' ') capability code(s) on both sides"
fi

exit $failed
