#!/usr/bin/env bash
# Build the latte command line for one platform and wrap it for download.
# The label comes out of the compiler; `--expect` fails a mislabelled archive.
#
#     tools/package_cli.sh dist                          # for this machine
#     tools/package_cli.sh dist --expect arm64-apple-darwin
#     tools/package_cli.sh dist --target x86_64-unknown-linux-musl --no-run
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

outdir=""
target=""
expect=""
run_checks=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --target) target=${2:-}; shift 2 ;;
        --expect) expect=${2:-}; shift 2 ;;
        --no-run) run_checks=0; shift ;;
        -*)
            echo "usage: tools/package_cli.sh <outdir> [--target <triple>] [--expect <triple>] [--no-run]" >&2
            exit 2 ;;
        *) outdir=$1; shift ;;
    esac
done
if [[ -z "$outdir" ]]; then
    echo "usage: tools/package_cli.sh <outdir> [--target <triple>] [--expect <triple>] [--no-run]" >&2
    exit 2
fi

# The resolution order every gate in this repo uses, so a workspace checkout
# and a bare clone with an installed release both find a compiler.
if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
BEANSC=${BEANSC:-${BEANS_ROOT:+$BEANS_ROOT/build/beansc}}
BEANSC=${BEANSC:-$(command -v beansc || true)}
if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi
# A tree-built compiler has no launcher, so its source roots are the caller's
# job. An installed release sets its own and none of this fires.
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-}  && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}   && -d "$BEANS_ROOT/stdlib/std"         ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding"   ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}      && -d "$BEANS_ROOT/runtime/net"        ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}      && -d "$BEANS_ROOT/runtime/log"        ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi
export BEANSC

version=$(bash tools/check_version.sh --print)

# For a cross build the triple is the label. For a native one the compiler is
# asked, because "what this machine is" is its answer to give and not ours.
if [[ -n "$target" ]]; then
    label=$target
else
    label=$("$BEANSC" doctor | sed -n 's/^host target: *//p' | tr -d '[:space:]')
fi
if [[ -z "$label" ]]; then
    echo "could not determine a target label — 'beansc doctor' named no host target" >&2
    exit 1
fi
if [[ -n "$expect" && "$expect" != "$label" ]]; then
    echo "--- package FAILED: this build is $label, the caller expected $expect ---" >&2
    echo "    An archive named for the wrong platform is worse than none." >&2
    exit 1
fi

exe=""
case $label in *windows*) exe=".exe" ;; esac

name="latte-v$version-$label"
# The staged tree is kept, so a caller can run the binary without unpacking an
# archive — there is no one extractor that reads both forms on every runner.
stage="$outdir/stage/$name"
rm -rf "$stage"
mkdir -p "$stage"

build_args=(build --release)
if [[ -n "$target" ]]; then build_args+=(--target "$target"); fi
build_args+=(examples/latte_cli.b -o "$stage/latte$exe")
"$BEANSC" "${build_args[@]}"

# A binary that does not answer its own name is not shippable. Cross builds
# cannot be run here, and say so rather than passing quietly.
if [[ $run_checks -eq 1 ]]; then
    got=$("$stage/latte$exe" version)
    if [[ "$got" != "latte $version" ]]; then
        echo "--- package FAILED: the binary says '$got', the tree says 'latte $version' ---" >&2
        exit 1
    fi
    echo "ok package/runs — $label answers '$got'"
else
    echo "note package — $label was cross-built and NOT run here; a runner for it must"
fi

cp README.md LICENSE CHANGELOG.md NOTICE.md "$stage/"

archive=""
case $label in
    *windows*)
        archive="$outdir/$name.zip"
        rm -f "$archive"
        # GitHub's Windows image has both; which one is not worth depending on.
        if command -v 7z >/dev/null 2>&1; then
            (cd "$outdir/stage" && 7z a -tzip -bso0 -bsp0 "../$name.zip" "$name" >/dev/null)
        elif command -v zip >/dev/null 2>&1; then
            (cd "$outdir/stage" && zip -q -r -X "../$name.zip" "$name")
        else
            echo "no zip tool: install 7z or zip to package a Windows build" >&2
            exit 1
        fi
        ;;
    *)
        archive="$outdir/$name.tar.gz"
        rm -f "$archive"
        # The members are named rather than globbed, so the order in the
        # archive is this list and not the directory's.
        (cd "$outdir/stage" && tar czf "../$name.tar.gz" \
            "$name/latte" "$name/README.md" "$name/LICENSE" \
            "$name/CHANGELOG.md" "$name/NOTICE.md")
        ;;
esac

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "no sha256 tool found" >&2
        exit 1
    fi
}

sum=$(sha256_of "$archive")
bytes=$(wc -c < "$archive" | tr -d '[:space:]')
echo "$sum  $(basename "$archive")" > "$archive.sha256"

echo "ok package — $(basename "$archive"), $bytes bytes, sha256 $sum"
echo "   the binary is $stage/latte$exe"
