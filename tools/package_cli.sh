#!/usr/bin/env bash
# Build the latte command line for one platform and wrap it, with its page kit
# (Skia's CanvasKit, latte's js/, fonts): tools/package_cli.sh <outdir> [--kit <dir>].
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

usage() {
    echo "usage: tools/package_cli.sh <outdir> [--kit <dir>] [--target <triple>] [--expect <triple>] [--no-run]" >&2
    exit 2
}

outdir=""
kit=""
target=""
expect=""
run_checks=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --kit) kit=${2:-}; shift 2 ;;
        --target) target=${2:-}; shift 2 ;;
        --expect) expect=${2:-}; shift 2 ;;
        --no-run) run_checks=0; shift ;;
        -*) usage ;;
        *) outdir=$1; shift ;;
    esac
done
[[ -n "$outdir" ]] || usage

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
BEANSC=${BEANSC:-${BEANS_ROOT:+$BEANS_ROOT/build/beansc}}
BEANSC=${BEANSC:-$(command -v beansc || true)}
# Git Bash never marks a `.cmd` executable; cmd.exe runs it, so existing is enough.
runnable=0
[[ -n "$BEANSC" && -x "$BEANSC" ]] && runnable=1
[[ "$BEANSC" == *.cmd && -f "$BEANSC" ]] && runnable=1
if [[ $runnable -eq 0 ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi
# A tree-built compiler has no launcher, so its source roots are ours to set.
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-}  && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}   && -d "$BEANS_ROOT/stdlib/std"         ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding"   ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}      && -d "$BEANS_ROOT/runtime/net"        ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}      && -d "$BEANS_ROOT/runtime/log"        ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi
export BEANSC

version=$(bash tools/check_version.sh --print)

# The label comes out of the compiler, never out of the caller.
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
    exit 1
fi

# The kit is platform-independent: a release builds it once and hands it to every job.
if [[ -z "$kit" ]]; then
    kit="$outdir/kit"
    bash tools/make_kit.sh "$kit"
fi
kit_version=$(sed -n 's/^latte=//p' "$kit/VERSION" 2>/dev/null || true)
if [[ "$kit_version" != "$version" ]]; then
    echo "--- package FAILED: the kit at $kit is for latte '${kit_version:-?}', this tree is $version ---" >&2
    exit 1
fi

windows=0
case $label in *windows*) windows=1 ;; esac

name="latte-v$version-$label"
# The staged tree is kept so a caller can run it without an extractor for both forms.
stage="$outdir/stage/$name"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/libexec" "$stage/share"

real="$stage/bin/latte.real"
[[ $windows -eq 1 ]] && real="$stage/bin/latte.real.exe"
build_args=(build --release)
if [[ -n "$target" ]]; then build_args+=(--target "$target"); fi
build_args+=(examples/latte_cli.b -o "$real")
"$BEANSC" "${build_args[@]}"

cp -R "$kit" "$stage/share/latte"
printf 'target=%s\n' "$label" >>"$stage/share/latte/VERSION"
cp tools/latte-install.sh tools/latte-install.ps1 tools/latte-upgrade.ps1 "$stage/libexec/"
cp README.md LICENSE CHANGELOG.md NOTICE.md "$stage/"

if [[ $windows -eq 1 ]]; then
    # CRLF: cmd.exe misreads a label past a 512-byte boundary in an LF-only file.
    awk '{ printf "%s\r\n", $0 }' >"$stage/bin/latte.cmd" <<'EOF'
@echo off
setlocal
rem The launcher's own installation is LATTE_HOME: the binary finds its page kit there.
for %%I in ("%~dp0..") do set "LATTE_HOME=%%~fI"
if /I "%~1"=="upgrade" if /I not "%~2"=="--project" goto upgrade
"%~dp0latte.real.exe" %*
exit /b %ERRORLEVEL%

:upgrade
set "LATTE_UPGRADE_FORCE="
if /I "%~2"=="--force" set "LATTE_UPGRADE_FORCE=-Force"
if not "%~2"=="" if not defined LATTE_UPGRADE_FORCE goto upgrade_usage
if not "%~3"=="" goto upgrade_usage
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LATTE_HOME%\libexec\latte-upgrade.ps1" -Prefix "%LATTE_HOME%" %LATTE_UPGRADE_FORCE%
exit /b %ERRORLEVEL%

:upgrade_usage
echo usage: latte upgrade [--force]    replace this installation 1>&2
echo        latte upgrade --project    move this project's pins 1>&2
exit /b 2
EOF
    launcher="$stage/bin/latte.cmd"
else
    cat >"$stage/bin/latte" <<'EOF'
#!/bin/sh
set -eu
# Shell built-ins only, so the launcher starts even with a broken PATH. Its own
# installation is LATTE_HOME: the binary finds its page kit there.
case $0 in
    */*) bin=${0%/*} ;;
    *)   bin=. ;;
esac
bin=$(CDPATH= cd -- "$bin" && pwd -P)
LATTE_HOME=$(CDPATH= cd -- "$bin/.." && pwd -P)
export LATTE_HOME
if [ "${1-}" = upgrade ] && [ "${2-}" != --project ]; then
    force=
    if [ "$#" -eq 2 ] && [ "$2" = --force ]; then force=--force; fi
    if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ -z "$force" ]; }; then
        echo "usage: latte upgrade [--force]    replace this installation" >&2
        echo "       latte upgrade --project    move this project's pins" >&2
        exit 2
    fi
    exec sh "$LATTE_HOME/libexec/latte-install.sh" \
        --prefix "$LATTE_HOME" --no-modify-path $force
fi
exec "$bin/latte.real" "$@"
EOF
    chmod 0755 "$stage/bin/latte" "$real"
    launcher="$stage/bin/latte"
fi

# A package whose launcher does not answer its own name is not shippable.
if [[ $run_checks -eq 1 ]]; then
    got=$("$launcher" version)
    if [[ "$got" != "latte $version" ]]; then
        echo "--- package FAILED: the launcher says '$got', the tree says 'latte $version' ---" >&2
        exit 1
    fi
    echo "ok package/runs — $label answers '$got' through its launcher"
else
    echo "note package — $label was cross-built and NOT run here; a runner for it must"
fi

archive=""
if [[ $windows -eq 1 ]]; then
    archive="$outdir/$name.zip"
    rm -f "$archive"
    if command -v 7z >/dev/null 2>&1; then
        (cd "$outdir/stage" && 7z a -tzip -bso0 -bsp0 "../$name.zip" "$name" >/dev/null)
    elif command -v zip >/dev/null 2>&1; then
        (cd "$outdir/stage" && zip -q -r -X "../$name.zip" "$name")
    else
        echo "no zip tool: install 7z or zip to package a Windows build" >&2
        exit 1
    fi
else
    archive="$outdir/$name.tar.gz"
    rm -f "$archive"
    # Members in sorted order, so the archive's listing does not depend on the file system's.
    (cd "$outdir/stage" && find "$name" -type f | LC_ALL=C sort >"../$name.members" &&
        tar czf "../$name.tar.gz" -T "../$name.members")
    rm -f "$outdir/$name.members"
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        echo "no sha256 tool found" >&2
        exit 1
    fi
}

sum=$(sha256_of "$archive")
bytes=$(wc -c < "$archive" | tr -d '[:space:]')
echo "$sum  $(basename "$archive")" > "$archive.sha256"

echo "ok package — $(basename "$archive"), $bytes bytes, sha256 $sum"
echo "   the launcher is $launcher"
