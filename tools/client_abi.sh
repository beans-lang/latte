#!/usr/bin/env bash
# Do the two halves of a CLIENT REGION's WebAssembly boundary still agree?
#
# `tools/wasm_abi.sh` asks this about the canvas target. This asks it about
# the region runtime, whose boundary is a different pair of files:
# `client/actions.b` declares what the module imports and
# `js/latte-client.js` supplies them, beside the runtime's own.
#
# The failure without this check is the worst kind. A name added on one side
# only is fine at build time, fine at link time — a browser module is linked
# with `--allow-undefined` — and a LinkError in somebody's browser the first
# time a page instantiates it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

module=${1:-build/browser/clienttest.wasm}
# The entry that was built. It declares the action imports itself, for the
# reason `client/actions.b` gives: a declaration in the library would put
# those symbols in the server binary too.
entry=${2:-tests/client/browser.b}
if [[ ! -f "$module" ]]; then
    echo "no module at $module — build one with tools/wasm_build.sh" >&2
    exit 1
fi
if [[ ! -f "$entry" ]]; then
    echo "no entry at $entry — it is what declares the page's imports" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-client-abi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# What Beans declares, and what the runtime's own half declares beside it.
{
    grep -hoE 'pub extern "C" fn latte_js_[a-z_0-9]+' client/*.b "$entry" | sed 's/.*fn //'
    grep -hoE 'pub extern "C" fn latte_js_[a-z_]+' browser/bridge.b | sed 's/.*fn //'
    grep -oE '^extern [a-z0-9_ ]*latte_js_[a-z_0-9]+' wasm/latte_wasm_host.c |
        grep -oE 'latte_js_[a-z_0-9]+'
} | sort -u > "$tmp/declared"

# What the page supplies. Asked of the objects rather than read out of them
# with a pattern: a regex over the source answered "nothing at all" the first
# time somebody reindented a file, which is a check reporting a catastrophe
# because its own scraper broke.
node --input-type=module -e '
import { LatteRuntime } from "./js/latte-runtime.js";
import { LatteClient } from "./js/latte-client.js";

const runtime = new LatteRuntime({});
runtime.memory = new WebAssembly.Memory({ initial: 1 });
// Neither object is called, only listed, so a null runtime is enough.
const client = new LatteClient({ runtime: runtime, document: null, dom: null });
const names = new Set([
    ...Object.keys(runtime.imports().env),
    ...Object.keys(client.actionImports()),
]);
process.stdout.write([...names].sort().join("\n") + "\n");
' > "$tmp/supplied"

node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
const names = WebAssembly.Module.imports(m).map((i) => i.name).sort();
process.stdout.write(names.join("\n") + "\n");
' "$module" > "$tmp/imported"

status=0

# A name the module really imports that nothing declares is a symbol that
# slipped through `--allow-undefined` — usually a libc call Clang decided to
# emit — and would be a LinkError in a page.
unexpected=$(comm -23 "$tmp/imported" "$tmp/declared" || true)
if [[ -n "$unexpected" ]]; then
    echo "--- $module imports names nothing declares ---" >&2
    echo "$unexpected" | sed 's/^/    /' >&2
    echo "    Add it to wasm/latte_wasm_host.c if it is a C builtin, or to" >&2
    echo "    client/actions.b and js/latte-client.js if the page supplies it." >&2
    status=1
fi

# And a name it imports that the page does not supply is the LinkError
# itself, one release early.
missing=$(comm -23 "$tmp/imported" "$tmp/supplied" || true)
if [[ -n "$missing" ]]; then
    echo "--- the page does not supply what $module imports ---" >&2
    echo "$missing" | sed 's/^/    /' >&2
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "ok client-abi — $(wc -l < "$tmp/imported" | tr -d ' ') imports, every one declared and supplied"
fi
exit $status
