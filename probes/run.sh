#!/usr/bin/env bash
# probes/run.sh <probe-dir> [-- args…]
#
# Runs one probe on BOTH backends and prints both outputs. A probe answered on
# one backend is not answered (RULES.md 3), so this is the only sanctioned way
# to run one — it makes forgetting the native leg take extra effort.
#
# A tree-built beansc resolves stdlib/std and runtime/beans_rt.c relative to
# the working directory, which is why every invocation below runs from the
# beans checkout.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
beans=$(cd "$here/../../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
version=$("$beansc" --version)
case "$version" in
    *"0.1.40"*) ;;
    *) echo "the probes are recorded against beansc 0.1.40; this says: $version" >&2
       exit 1 ;;
esac

probe=${1:?usage: run.sh <probe-dir> [-- args…]}
shift || true
[[ "${1:-}" == "--" ]] && shift
entry="$here/$probe/main.b"
[[ -f "$entry" ]] || { echo "no probe at $entry" >&2; exit 1; }

out=$(mktemp -d "${TMPDIR:-/tmp}/latte-probe.XXXXXX")
trap 'rm -rf "$out"' EXIT

echo "=== $probe — the tree interpreter ==="
(cd "$beans" && "$beansc" run "$entry" ${1:+--} "$@")

echo
echo "=== $probe — the native binary ==="
(cd "$beans" && "$beansc" build "$entry" -o "$out/probe") >/dev/null
(cd "$beans" && "$out/probe" "$@")

echo
echo "beansc: $beansc ($(shasum -a 256 "$beansc" | cut -c1-12))"
