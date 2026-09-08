#!/usr/bin/env bash
# w8b_smoke.sh — PLAN.md gate 11: "One Playwright smoke in real Chromium."
#
# Starts `tests/_w8b_smoke_server.b` — a real espresso server on a port the
# kernel chose, with a latte circuit endpoint on it — then drives it from a
# real browser with `tests/w8b_smoke.js`, then asks the server what it saw.
#
# **Why this exists beside `browser-apply`.** That leg runs `js/latte.js` in
# headless Chrome against fixtures a Beans program printed into a file, and it
# is the best applier check here. `tests/circuit_live.b` runs the same server
# and drives it with a `std.websocket` client on an OS thread. Neither has a
# BROWSER open a SOCKET. Everything between them — the handshake Chrome sends,
# the `Origin` header only a browser sets and `EndpointOptions.origins` refuses
# by default, `latte.js`'s boot off its own `<script>` tag, a real click
# becoming an `ev` message, and a batch arriving through `WebSocket.onmessage`
# into a real DOM — was unproven until this leg.
#
# **Both halves are asserted.** The browser's half is `tests/w8b_smoke.js`.
# The server's half is the `W8B-SMOKE-*` summary this script reads after
# shutdown: how many upgrades espresso completed, how many pages the circuit
# built, how many circuits the set opened, how many it still holds, and how
# many faults it recorded. A browser cannot fake those.
#
# **Skips are loud and name what went unchecked** (RULES.md 5). There are two
# inputs that can be missing — a browser and `playwright-core` — and each says
# so on its own line. A missing SERVER, script, or applier is a FAILURE: those
# are this repo's own files and their absence means the layout moved.
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

SERVER_SRC="$ROOT/tests/_w8b_smoke_server.b"
SMOKE_JS="$ROOT/tests/w8b_smoke.js"
APPLIER="$ROOT/js/latte.js"
for f in "$SERVER_SRC" "$SMOKE_JS" "$APPLIER"; do
    if [[ ! -f "$f" ]]; then
        echo "--- w8b-smoke FAILED: ${f#$ROOT/} is missing ---" >&2
        exit 1
    fi
done

# ---- the two inputs that may honestly be absent ---------------------------
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
    echo "SKIP w8b-smoke: no \`node\` on PATH."
    echo "   NOT CHECKED: a real browser opening a real WebSocket to a latte circuit —"
    echo "   the handshake, the Origin allowlist, latte.js's boot, a real click"
    echo "   becoming an ev message, and a batch reaching a real DOM."
    exit 0
fi
if ! chrome=$(find_chrome); then
    echo "SKIP w8b-smoke: no Chrome or Chromium found (set CHROME=/path/to/chrome)."
    echo "   NOT CHECKED: a real browser opening a real WebSocket to a latte circuit."
    exit 0
fi

# playwright-core drives the browser this host already has; it downloads none.
# Kept under build/ so it is not in the repo and `make clean`-shaped commands
# take it with them.
PW_DIR="$ROOT/build/w8b/pw"
if [[ ! -d "$PW_DIR/node_modules/playwright-core" ]]; then
    mkdir -p "$PW_DIR"
    [[ -f "$PW_DIR/package.json" ]] || \
        printf '%s\n' '{ "name": "w8b-smoke-tools", "private": true, "version": "0.0.0" }' \
        > "$PW_DIR/package.json"
    if ! (cd "$PW_DIR" && npm install --no-audit --no-fund --silent \
            playwright-core@1.63.0) >"$PW_DIR/install.log" 2>&1; then
        echo "SKIP w8b-smoke: playwright-core is not installed and could not be fetched."
        echo "   NOT CHECKED: a real browser opening a real WebSocket to a latte circuit."
        echo "   To check it: (cd build/w8b/pw && npm install playwright-core@1.63.0)"
        sed -n '1,10p' "$PW_DIR/install.log" >&2
        exit 0
    fi
fi

out="$ROOT/build/w8b/smoke"
mkdir -p "$out"

if ! (cd "$ROOT" && "$BEANSC" build "$SERVER_SRC" -o "$out/server") \
        >"$out/server.build" 2>&1; then
    echo "--- w8b-smoke FAILED: the smoke server would not build ---" >&2
    sed -n '1,40p' "$out/server.build" >&2
    exit 1
fi

rm -f "$out/server.out" "$out/server.err"
# Started from ROOT: it reads `js/latte.js` relative to the module root.
(cd "$ROOT" && "$out/server") >"$out/server.out" 2>"$out/server.err" &
server_pid=$!
cleanup() {
    if kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# The port arrives on stderr, unbuffered, the moment `bind` returns. Waiting on
# it rather than sleeping is the difference between a suite that is slow on a
# fast machine and one that is flaky on a loaded one.
port=""
for _ in $(seq 1 400); do
    if [[ -s "$out/server.err" ]]; then
        port=$(awk '/W8B-SMOKE-PORT/ { print $2; exit }' "$out/server.err")
        [[ -n "$port" ]] && break
        if grep -q 'W8B-SMOKE-UNAVAILABLE' "$out/server.err"; then
            echo "SKIP w8b-smoke: the server said it cannot run here."
            sed -n '1,4p' "$out/server.err"
            echo "   NOT CHECKED: a real browser opening a real WebSocket to a latte circuit."
            exit 0
        fi
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "--- w8b-smoke FAILED: the smoke server exited before it printed a port ---" >&2
        sed -n '1,40p' "$out/server.err" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ -z "$port" ]]; then
    echo "--- w8b-smoke FAILED: the smoke server never printed a port ---" >&2
    sed -n '1,40p' "$out/server.err" >&2
    exit 1
fi

status=0
W8B_SMOKE_URL="http://127.0.0.1:$port/" \
W8B_SMOKE_CHROME="$chrome" \
NODE_PATH="$PW_DIR/node_modules" \
    node "$SMOKE_JS" >"$out/smoke.txt" 2>&1 || status=$?
cat "$out/smoke.txt"

# Ask the server to stop, so the summary is printed rather than killed. A
# server that will not stop is itself a finding — that is the circuit teardown
# path — so this is a failure and not a fall-through to `kill`.
stopped=0
curl -fsS --max-time 10 "http://127.0.0.1:$port/_stop" >/dev/null 2>&1 && stopped=1
for _ in $(seq 1 200); do
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.05
done
if kill -0 "$server_pid" 2>/dev/null; then
    echo "--- w8b-smoke FAILED: the server did not shut down after /_stop (asked: $stopped) ---" >&2
    cleanup
    exit 1
fi
trap - EXIT
wait "$server_pid" 2>/dev/null || true

if [[ $status -ne 0 ]]; then
    echo "--- w8b-smoke FAILED: the browser half reported failures (exit $status) ---" >&2
    echo "--- server stderr ---" >&2
    cat "$out/server.err" >&2
    exit 1
fi

# ---- the server's half ----------------------------------------------------
fact() { awk -v k="W8B-SMOKE-$1" '$1 == k { print $2; exit }' "$out/server.err"; }
server_bad=0
expect() {                       # <name> <got> <want>
    if [[ "$2" == "$3" ]]; then
        echo "ok server $1 $2"
    else
        echo "FAIL server $1: got ${2:-<nothing>} want $3" >&2
        server_bad=$((server_bad + 1))
    fi
}
if ! grep -q 'W8B-SMOKE-DONE' "$out/server.err"; then
    echo "--- w8b-smoke FAILED: the server never printed its summary ---" >&2
    cat "$out/server.err" >&2
    exit 1
fi
# Two navigations, so two page shells and two copies of the applier — those are
# exact whatever the socket does. The socket counts are cross-checked instead of
# hard-coded: the number of upgrades espresso completed and the number of
# circuits the set opened must both equal the number of WebSockets the BROWSER
# says it opened. That is a stronger claim than any constant, and it stays true
# when the reconnect in § 9 starts working and adds a third.
js_sockets=$(awk '/^W8B-SMOKE-JS-SOCKETS/ { print $2; exit }' "$out/smoke.txt")
expect pages    "$(fact PAGES)"    2
expect scripts  "$(fact SCRIPTS)"  2
expect stops    "$(fact STOPS)"    1
expect faults   "$(fact FAULTS)"   0
expect upgrades "$(fact UPGRADES)" "${js_sockets:-<no count from the browser>}"
expect circuits "$(fact CIRCUITS)" "${js_sockets:-<no count from the browser>}"
if [[ $server_bad -ne 0 ]]; then
    echo "--- w8b-smoke FAILED: $server_bad server-side fact(s) wrong ---" >&2
    grep 'W8B-SMOKE' "$out/server.err" >&2
    exit 1
fi

summary=$(tail -3 "$out/smoke.txt" | grep -E '^[0-9]+ checks' || true)
echo "ok w8b-smoke — a real browser drove a real socket: ${summary:-no count}, on $("$chrome" --version 2>/dev/null | head -1), server-side facts agree"
