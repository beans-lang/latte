#!/usr/bin/env bash
# Stages the built showcase as a static site, in the tree's own layout so the
# page's relative paths are unchanged. Build the wasm and fonts first.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: stage_showcase.sh <output-dir>}

need=(
    examples/showcase/index.html
    examples/showcase/mark.png
    node_modules/canvaskit-wasm/bin/canvaskit.js
    node_modules/canvaskit-wasm/bin/canvaskit.wasm
    build/browser/showcase.wasm
    build/fonts/latte-regular.ttf
    build/fonts/latte-medium.ttf
    build/fonts/latte-bold.ttf
)
missing=0
for file in "${need[@]}"; do
    [[ -f "$ROOT/$file" ]] || { echo "missing $file" >&2; missing=1; }
done
[[ $missing -eq 0 ]] || { echo "build the showcase first (README: Two targets)" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
for file in "${need[@]}"; do
    mkdir -p "$out/$(dirname "$file")"
    cp "$ROOT/$file" "$out/$file"
done
cp -R "$ROOT/js" "$out/js"

cat > "$out/index.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Latte — the showcase</title>
<meta http-equiv="refresh" content="0; url=examples/showcase/">
<a href="examples/showcase/">Latte — the showcase</a>
EOF
echo "staged $(find "$out" -type f | wc -l | tr -d ' ') files in $out"
