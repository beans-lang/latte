#!/usr/bin/env bash
# Assemble share/latte/: latte's js/, CanvasKit (Skia), fonts, licences, VERSION.
# Needs `npm install` and `node tools/font_prepare.mjs` first. Usage: make_kit.sh <outdir>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

out=${1:-}
if [[ -z "$out" || $# -ne 1 ]]; then
    echo "usage: tools/make_kit.sh <outdir>" >&2
    exit 2
fi

version=$(bash tools/check_version.sh --print)
ck_dir=node_modules/canvaskit-wasm
# The CanvasKit a kit carries is the one package.json pins, never whatever npm resolved.
pinned=$(sed -n 's/.*"canvaskit-wasm": *"\([^"]*\)".*/\1/p' package.json)
if [[ ! -f "$ck_dir/package.json" ]]; then
    echo "--- kit FAILED: $ck_dir is not there — run 'npm install' first ---" >&2
    exit 1
fi
installed=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$ck_dir/package.json" | head -1)
if [[ "$installed" != "$pinned" ]]; then
    echo "--- kit FAILED: package.json pins canvaskit-wasm $pinned, node_modules holds $installed ---" >&2
    exit 1
fi

missing=0
need() { [[ -f "$1" ]] || { echo "--- kit FAILED: $1 is not there${2:+ — $2} ---" >&2; missing=1; }; }
need "$ck_dir/bin/canvaskit.js"
need "$ck_dir/bin/canvaskit.wasm"
need "$ck_dir/LICENSE"
need node_modules/roboto-fontface/LICENSE "run 'npm install'"
for font in regular medium bold mono; do
    need "build/fonts/latte-$font.ttf" "run 'node tools/font_prepare.mjs'"
done
[[ $missing -eq 0 ]] || exit 1

rm -rf "$out"
mkdir -p "$out/js" "$out/canvaskit" "$out/fonts" "$out/licenses"
# All of js/, not the page's list: a superset costs a few kilobytes and a
# module the list forgot would otherwise be a 404 in somebody's browser.
cp js/*.js "$out/js/"
cp "$ck_dir/bin/canvaskit.js" "$ck_dir/bin/canvaskit.wasm" "$out/canvaskit/"
cp build/fonts/latte-regular.ttf build/fonts/latte-medium.ttf \
   build/fonts/latte-bold.ttf build/fonts/latte-mono.ttf "$out/fonts/"
cp "$ck_dir/LICENSE" "$out/licenses/canvaskit-skia-BSD-3-Clause.txt"
cp node_modules/roboto-fontface/LICENSE "$out/licenses/roboto-Apache-2.0.txt"
printf 'latte=%s\ncanvaskit=%s\n' "$version" "$installed" >"$out/VERSION"

files=$(find "$out" -type f | wc -l | tr -d '[:space:]')
echo "ok kit — latte $version, CanvasKit $installed, $files files in $out"
