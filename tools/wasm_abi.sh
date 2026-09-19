#!/usr/bin/env bash
# Do the two halves of the WebAssembly boundary still agree?
#
# `browser/bridge.b` declares what the module imports. `js/latte-runtime.js`
# supplies them. Nothing links the two but this, and the failure without it is
# the worst kind: a name added on one side only is fine at build time, fine at
# link time — `--allow-undefined` is how a browser module is linked — and a
# LinkError in somebody's browser the first time the module is instantiated.
#
# Three comparisons, because there are three ways to get it wrong:
#   * a name declared in Beans that JavaScript does not supply
#   * a name JavaScript supplies that nothing declares
#   * a name in the built module that is in neither list, which is how a libc
#     function Clang decided to emit a call to (memcpy, memchr) turns up
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

module=build/browser/_abi_surface.wasm
bash tools/wasm_build.sh tests/canvas/_abi_surface.b "$module" >/dev/null

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-abi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# What Beans declares. Both halves: the page's own services and the drawing
# surface, which are separate packages and one boundary.
# Two declaring sides, because the boundary has two. Beans declares what Beans
# calls; `wasm/latte_wasm_host.c` declares what the *runtime* calls through it —
# the float text hooks, which no Beans line names and which are imports all the
# same.
{
    grep -hoE 'pub extern "C" fn latte_js_[a-z_]+' browser/bridge.b canvaskit/bridge.b |
        sed 's/.*fn //'
    grep -oE '^extern [a-z0-9_ ]*latte_js_[a-z_0-9]+' wasm/latte_wasm_host.c |
        grep -oE 'latte_js_[a-z_0-9]+'
} | sort -u > "$tmp/declared"

# What the page supplies — asked of the modules rather than read out of them
# with a pattern. A regex over the source was what this used to do, and it
# answered "nothing at all" the first time somebody reindented the file, which
# is a gate reporting a catastrophe because its own scraper broke.
node --input-type=module -e '
import { LatteRuntime } from "./js/latte-runtime.js";
import { canvasKitImports } from "./js/latte-canvaskit.js";

// Neither object is called, only listed, so the stubs need only exist.
const runtime = new LatteRuntime({});
runtime.memory = new WebAssembly.Memory({ initial: 1 });
const surface = { surface: null, ensureSurface: () => false, revision: 0, isSoftware: false,
                  images: new Map(), paragraphs: new Map() };
const names = new Set([
    ...Object.keys(runtime.imports().env),
    ...Object.keys(canvasKitImports(runtime, surface)),
]);
process.stdout.write([...names].sort().join("\n") + "\n");
' > "$tmp/supplied"

# What the module really imports.
node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
const names = WebAssembly.Module.imports(m).map((i) => i.name).sort();
process.stdout.write(names.join("\n") + "\n");
' "$module" > "$tmp/imported"

status=0

if ! diff -u "$tmp/declared" "$tmp/supplied" > "$tmp/pair.diff"; then
    echo "--- the two halves of the boundary disagree ---" >&2
    echo "    < is declared in browser/bridge.b, > is supplied by js/latte-runtime.js" >&2
    cat "$tmp/pair.diff" >&2
    status=1
else
    echo "ok wasm-abi/pair — $(wc -l < "$tmp/declared" | tr -d ' ') imports, declared and supplied"
fi

# Every real import must be a declared one. Anything else is a symbol that
# slipped through --allow-undefined — usually a libc call Clang decided to
# emit — and would be a LinkError in a page.
unexpected=$(comm -23 "$tmp/imported" "$tmp/declared" || true)
if [[ -n "$unexpected" ]]; then
    echo "--- the built module imports names nothing declares ---" >&2
    echo "$unexpected" | sed 's/^/    /' >&2
    echo "    Add it to wasm/latte_wasm_host.c if it is a C builtin, or to" >&2
    echo "    browser/bridge.b and js/latte-runtime.js if the page should supply it." >&2
    status=1
else
    echo "ok wasm-abi/closed — the module imports nothing beyond what is declared"
fi

# The float hooks are reached from C, not from Beans, so no Beans line can
# reference them and the coverage check below would report them forever. They
# are covered by tests/canvas/floats.b instead, which prints floats and is
# diffed against the other two backends.
grep -v -E '^latte_js_(format|parse)_f64$' "$tmp/declared" > "$tmp/declared_beans"
missing=$(comm -13 "$tmp/imported" "$tmp/declared_beans" || true)
if [[ -n "$missing" ]]; then
    echo "--- declared imports the ABI surface never referenced ---" >&2
    echo "$missing" | sed 's/^/    /' >&2
    echo "    tests/canvas/_abi_surface.b must touch every import, or this gate" >&2
    echo "    stops covering the ones it misses." >&2
    status=1
else
    echo "ok wasm-abi/covered — the surface references every declared import"
fi

exit $status
