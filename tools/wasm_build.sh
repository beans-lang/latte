#!/usr/bin/env bash
# Builds one Beans file into a browser WebAssembly module.
#
# The three knobs that are not obvious, and what goes wrong without each:
#
#   --target wasm32-unknown-unknown   the browser target. wasm32-wasip1 is the
#                                     other one and it needs a WASI shim in the
#                                     page plus a libc sysroot to link against.
#   --runtime freestanding            there is no operating system. The other
#                                     profiles are refused for this target.
#   --emit shared                     a module with no `_start`, exporting its
#                                     memory and the `pub extern "C"` names.
#                                     Without it the driver refuses: there is
#                                     no application host for this target.
#
# wasm-ld is what does the link, and Apple's clang does not ship one. The
# search order below is: what the caller named, Homebrew's lld, then the copy
# inside a Rust toolchain — which is there on most machines that have rustup
# and is the reason this works without a 1.5 GB llvm install.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source_file=${1:?usage: wasm_build.sh <file.b> <output.wasm>}
output=${2:?usage: wasm_build.sh <file.b> <output.wasm>}

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
BEANSC=${BEANSC:-${BEANS_ROOT:+$BEANS_ROOT/build/beansc}}
BEANSC=${BEANSC:-$(command -v beansc || true)}
if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi
if [[ -n ${BEANS_ROOT:-} ]]; then
    [[ -z ${BEANS_RUNTIME:-} && -f "$BEANS_ROOT/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$BEANS_ROOT/runtime/beans_rt.c"
    [[ -z ${BEANS_STDLIB:-}  && -d "$BEANS_ROOT/stdlib/std"        ]] && export BEANS_STDLIB="$BEANS_ROOT/stdlib/std"
fi

# A Clang with the wasm32 backend. Apple's has none.
wasm_cc=${BEANS_WASM_CC:-}
if [[ -z "$wasm_cc" ]]; then
    for candidate in /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang clang; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" --print-targets 2>/dev/null | grep -qw wasm32; then
            wasm_cc="$candidate"; break
        fi
    done
fi
if [[ -z "$wasm_cc" ]]; then
    echo "no Clang with a wasm32 backend. Install one (brew install llvm) or set BEANS_WASM_CC." >&2
    exit 1
fi

# And a wasm-ld for it to hand the objects to.
if ! command -v wasm-ld >/dev/null 2>&1; then
    for directory in \
        /opt/homebrew/opt/lld/bin \
        /usr/local/opt/lld/bin \
        "$(dirname "$wasm_cc")" \
        "$HOME"/.rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld
    do
        if [[ -x "$directory/wasm-ld" ]]; then PATH="$directory:$PATH"; break; fi
    done
fi
if ! command -v wasm-ld >/dev/null 2>&1; then
    echo "no wasm-ld on PATH. Install one (brew install lld), or use the copy inside a rustup toolchain." >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
cd "$ROOT"
"$BEANSC" build --target wasm32-unknown-unknown --runtime freestanding \
    --emit shared --cc "$wasm_cc" "$source_file" -o "$output"
