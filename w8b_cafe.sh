#!/usr/bin/env bash
# w8b_cafe.sh — the SHIPPED example, in a real browser.
#
# `w8b_smoke.sh` beside this one drives a server written for the test. This one
# drives `examples/cafe/main.b -- serve 0`, which is the program a person runs,
# unchanged: a whole latte application with a page shell, a layout, a keyed
# loop, a child component with a callback, a form with antiforgery, latte's own
# CSP and its client script served off the asset route.
#
# **Why it exists.** W9 built the cafe app and gated it on both backends
# through espresso's `TestHost`, which cannot open a WebSocket — so until this
# leg, latte could serve a document and nobody had ever loaded one. That is the
# difference between "the framework renders" and "a person can build an app,
# open it and click something". `lanes/W9.md` "Next" names `w9_smoke.sh` for
# this; it is `w8b_cafe.sh` instead because W8b owns the browser harness and
# two lanes taking one name is a merge conflict in the expensive place.
# **If W9 resumes: this is that step, done. Do not write `w9_smoke.sh` too.**
#
# **What it asserts that nothing else can.** The example's own `check` mode
# already proves the routing, the binding, the antiforgery and the seam. Every
# check here is about the part a `TestHost` cannot reach: the bytes a browser
# received, the headers it enforced, the script it fetched and RAN, the socket
# it opened, and a click on a component becoming state on the server and markup
# back in the DOM.
#
# Skips are loud and name what went unchecked (RULES.md 5). Two inputs can
# honestly be missing — a browser and `playwright-core`. A missing example, or
# a missing `js/latte.js`, is a FAILURE: those are this repo's own files.
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

APP_SRC="$ROOT/examples/cafe/main.b"
CAFE_JS="$ROOT/tests/w8b_cafe.js"
APPLIER="$ROOT/js/latte.js"
for f in "$APP_SRC" "$CAFE_JS" "$APPLIER"; do
    if [[ ! -f "$f" ]]; then
        echo "--- w8b-cafe FAILED: ${f#$ROOT/} is missing ---" >&2
        exit 1
    fi
done

find_chrome() {
    local c
    for c in "${CHROME:-}" \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "$(command -v google-chrome 2>/dev/null || true)" \
        "$(command -v chromium 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP w8b-cafe: no \`node\` on PATH."
    echo "   NOT CHECKED: the shipped example loaded in a real browser — the document"
    echo "   it serves, the CSP it enforces, the client script it runs, the circuit it"
    echo "   opens and a click on a component reaching the server and coming back."
    exit 0
fi
if ! chrome=$(find_chrome); then
    echo "SKIP w8b-cafe: no Chrome or Chromium found (set CHROME=/path/to/chrome)."
    echo "   NOT CHECKED: the shipped example loaded in a real browser."
    exit 0
fi

# Shared with w8b_smoke.sh on purpose: one playwright-core, installed once.
PW_DIR="$ROOT/build/w8b/pw"
if [[ ! -d "$PW_DIR/node_modules/playwright-core" ]]; then
    mkdir -p "$PW_DIR"
    [[ -f "$PW_DIR/package.json" ]] || \
        printf '%s\n' '{ "name": "w8b-smoke-tools", "private": true, "version": "0.0.0" }' \
        > "$PW_DIR/package.json"
    if ! (cd "$PW_DIR" && npm install --no-audit --no-fund --silent \
            playwright-core@1.63.0) >"$PW_DIR/install.log" 2>&1; then
        echo "SKIP w8b-cafe: playwright-core is not installed and could not be fetched."
        echo "   NOT CHECKED: the shipped example loaded in a real browser."
        echo "   To check it: (cd build/w8b/pw && npm install playwright-core@1.63.0)"
        sed -n '1,10p' "$PW_DIR/install.log" >&2
        exit 0
    fi
fi

out="$ROOT/build/w8b/cafe"
mkdir -p "$out"

if ! (cd "$ROOT" && "$BEANSC" build "$APP_SRC" -o "$out/cafe") \
        >"$out/cafe.build" 2>&1; then
    echo "--- w8b-cafe FAILED: examples/cafe/main.b would not build ---" >&2
    sed -n '1,40p' "$out/cafe.build" >&2
    exit 1
fi

rm -f "$out/cafe.out" "$out/cafe.err"
# Started from ROOT, and with `serve 0`: the app reads `js/latte.js` relative to
# the working directory, and a fixed port is a false green when something else
# is already listening on it.
(cd "$ROOT" && "$out/cafe" serve 0) >"$out/cafe.out" 2>"$out/cafe.err" &
app_pid=$!
cleanup() {
    if kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

port=""
for _ in $(seq 1 400); do
    if [[ -s "$out/cafe.err" ]]; then
        port=$(awk '/CAFE-PORT/ { print $2; exit }' "$out/cafe.err")
        [[ -n "$port" ]] && break
        if grep -q 'CAFE-UNAVAILABLE' "$out/cafe.err"; then
            echo "SKIP w8b-cafe: the example said it cannot run here."
            sed -n '1,4p' "$out/cafe.err"
            echo "   NOT CHECKED: the shipped example loaded in a real browser."
            exit 0
        fi
        if grep -q 'CAFE-REFUSED' "$out/cafe.err"; then
            echo "--- w8b-cafe FAILED: the example refused to start ---" >&2
            sed -n '1,10p' "$out/cafe.err" >&2
            exit 1
        fi
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "--- w8b-cafe FAILED: the example exited before it printed a port ---" >&2
        sed -n '1,40p' "$out/cafe.err" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ -z "$port" ]]; then
    echo "--- w8b-cafe FAILED: the example never printed a port ---" >&2
    sed -n '1,40p' "$out/cafe.err" >&2
    exit 1
fi

status=0
W8B_CAFE_URL="http://127.0.0.1:$port/" \
W8B_CAFE_CHROME="$chrome" \
NODE_PATH="$PW_DIR/node_modules" \
    node "$CAFE_JS" >"$out/cafe.txt" 2>&1 || status=$?
cat "$out/cafe.txt"

stopped=0
curl -fsS --max-time 10 "http://127.0.0.1:$port/_stop" >/dev/null 2>&1 && stopped=1
for _ in $(seq 1 200); do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.05
done
if kill -0 "$app_pid" 2>/dev/null; then
    echo "--- w8b-cafe FAILED: the example did not shut down after /_stop (asked: $stopped) ---" >&2
    cleanup
    exit 1
fi
trap - EXIT
wait "$app_pid" 2>/dev/null || true

if [[ $status -ne 0 ]]; then
    echo "--- w8b-cafe FAILED: the browser half reported failures (exit $status) ---" >&2
    echo "--- the example's stderr ---" >&2
    cat "$out/cafe.err" >&2
    exit 1
fi

# ---- the server's half ----------------------------------------------------
fact() { awk -v k="CAFE-$1" '$1 == k { print $2; exit }' "$out/cafe.err"; }
server_bad=0
expect() {                       # <name> <got> <want>
    if [[ "$2" == "$3" ]]; then
        echo "ok app $1 $2"
    else
        echo "FAIL app $1: got ${2:-<nothing>} want $3" >&2
        server_bad=$((server_bad + 1))
    fi
}
if ! grep -q 'CAFE-DONE' "$out/cafe.err"; then
    echo "--- w8b-cafe FAILED: the example never printed its summary ---" >&2
    cat "$out/cafe.err" >&2
    exit 1
fi
js_sockets=$(awk '/^W8B-CAFE-JS-SOCKETS/ { print $2; exit }' "$out/cafe.txt")
js_pages=$(awk '/^W8B-CAFE-JS-PAGES/ { print $2; exit }' "$out/cafe.txt")
# Cross-checked against what the BROWSER says it did rather than hard-coded: a
# constant here would have to be edited every time a check is added, and the
# day someone edited it wrong it would still be green.
expect upgrades "$(fact UPGRADES)" "${js_sockets:-<no count from the browser>}"
expect pages    "$(fact PAGES)"    "${js_pages:-<no count from the browser>}"
expect stops    "$(fact STOPS)"    1
expect faults   "$(fact FAULTS)"   0
if [[ $server_bad -ne 0 ]]; then
    echo "--- w8b-cafe FAILED: $server_bad server-side fact(s) wrong ---" >&2
    grep 'CAFE-' "$out/cafe.err" >&2
    exit 1
fi

summary=$(tail -3 "$out/cafe.txt" | grep -E '^[0-9]+ checks' || true)
echo "ok w8b-cafe — the shipped example ran in a real browser: ${summary:-no count}, on $("$chrome" --version 2>/dev/null | head -1), server-side facts agree"
