#!/usr/bin/env bash
# Rebuild the demo's stylesheet from the classes its markup actually uses.
#
#   examples/board/build-css.sh
#
# The output, `css/app.build.css`, is COMMITTED. A consumer of this example
# runs no build step and installs no toolchain — the same rule the generated
# `.b` beside every `.bx` follows. Run this after changing a class name in the
# markup, and commit what it writes.
#
# It needs Node, because Tailwind is a Node program. That is the only part of
# this repository that does, and it is why this is a script you run rather than
# a leg of the gate: a gate that needed npm would fail on a machine that has
# beansc and nothing else.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

command -v npm >/dev/null 2>&1 || {
    echo "npm not found — Tailwind is a Node program." >&2
    echo "The committed css/app.build.css is what the demo serves; you only need this to change it." >&2
    exit 1
}

# Tailwind resolves `@import "tailwindcss"` relative to the input file, so the
# packages have to be here rather than borrowed from a temporary npx cache.
[[ -d node_modules ]] || npm install --no-audit --no-fund

./node_modules/.bin/tailwindcss -i css/app.css -o css/app.build.css --minify
echo "wrote css/app.build.css ($(wc -c < css/app.build.css) bytes)"
