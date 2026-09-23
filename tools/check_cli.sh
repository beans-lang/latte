#!/usr/bin/env bash
# Does `latte init` write projects `latte build` builds, and does the packaged
# release do the same with no checkout? LATTE_DIST=<dir> tests an archive already built.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

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
    [[ -z ${BEANS_ENCODING:-} && -d "$BEANS_ROOT/runtime/encoding" ]] && export BEANS_ENCODING="$BEANS_ROOT/runtime/encoding"
    [[ -z ${BEANS_NET:-}     && -d "$BEANS_ROOT/runtime/net"       ]] && export BEANS_NET="$BEANS_ROOT/runtime/net"
    [[ -z ${BEANS_LOG:-}     && -d "$BEANS_ROOT/runtime/log"       ]] && export BEANS_LOG="$BEANS_ROOT/runtime/log"
fi
export BEANSC
# Hermetic: a LATTE_HOME or LATTE_ROOT from the caller's shell would pick the kit.
unset LATTE_HOME LATTE_ROOT

tmp=$(mktemp -d "${TMPDIR:-/tmp}/latte-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

latte="$ROOT/build/latte"
"$BEANSC" build "$ROOT/examples/latte_cli.b" -o "$latte" >"$tmp/build.log" 2>&1 || {
    echo "--- cli FAILED: the binary did not build ---" >&2
    cat "$tmp/build.log" >&2
    exit 1
}
echo "ok cli/binary — examples/latte_cli.b builds"

status=0
failures=0
note() { echo "--- cli FAILED: $1 ---" >&2; status=1; failures=$((failures + 1)); }

# A free port, asked of the kernel: a fixed one can be answered by a stranger.
free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Run an html build folder the way `latte build` says to, and ask it for its
# page and its script. `$3` is text only this project's page can hold.
serves() {
    local folder=$1 name=$2 wanted=$3 port pid page=""
    port=$(free_port)
    (cd "$folder" && exec "./$name" serve "$port") >"$tmp/$name-serve.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do
        page=$(curl -fsS "http://127.0.0.1:$port/" 2>/dev/null) && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    local script
    script=$(curl -fsS "http://127.0.0.1:$port/_latte/latte.js" 2>/dev/null | head -c 64 || true)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ "$page" != *"$wanted"* ]]; then
        note "$folder/$name did not serve its page"
        sed 's/^/    /' "$tmp/$name-serve.log" >&2
        return 1
    fi
    if [[ "$script" != *"latte.js"* ]]; then
        note "$folder/$name served no /_latte/latte.js from the js/ the build staged"
        return 1
    fi
    return 0
}

# --- one target, from nothing to an artifact ---------------------------
one_target() {
    local target=$1 name=$2 artifact=$3
    local work="$tmp/$target"
    mkdir -p "$work"
    (cd "$work" && "$latte" init "$name" --target "$target" --latte "$ROOT") \
        >"$tmp/$target-init.log" 2>&1 || {
        note "'latte init --target $target' refused"
        cat "$tmp/$target-init.log" >&2
        return 0
    }
    # generated/ is NOT written by init: the first build writes it, and a
    # scaffolder that wrote it too would be a second mirror rule.
    if [[ -d "$work/$name/generated" ]]; then
        note "init wrote generated/, which is the build's to write"
        return 0
    fi
    (cd "$work/$name" && "$latte" build) >"$tmp/$target-build.log" 2>&1 || {
        note "'latte build' refused a project 'latte init --target $target' wrote"
        cat "$tmp/$target-build.log" >&2
        return 0
    }
    if [[ ! -f "$work/$name/$artifact" ]]; then
        note "the $target build wrote no $artifact"
        return 0
    fi
    # And it is regenerated from the markup, not left where init put it.
    if [[ ! -f "$work/$name/generated/site/shell.b" ]]; then
        note "the $target build generated no shell.b from shell.bx"
        return 0
    fi
    # A second build must be a no-op for the markup: a generator that rewrote
    # every file identically would make every build a full rebuild.
    (cd "$work/$name" && "$latte" build) >"$tmp/$target-build2.log" 2>&1 || {
        note "the second $target build refused"
        return 0
    }
    if ! grep -q "generated 0 file" "$tmp/$target-build2.log"; then
        if grep -q "generated .* file" "$tmp/$target-build2.log"; then
            note "the second $target build regenerated markup that had not changed"
            cat "$tmp/$target-build2.log" >&2
            return 0
        fi
    fi
    # The drift check must agree with what the build just wrote.
    (cd "$work/$name" && "$latte" check --drift) >"$tmp/$target-drift.log" 2>&1 || {
        note "'latte check --drift' calls a freshly built $target project stale"
        cat "$tmp/$target-drift.log" >&2
        return 0
    }
    if [[ $target == html ]]; then
        serves "$work/$name/build/debug" "$name" "<h1>$name</h1>" || return 0
        echo "ok cli/$target — init, build, $artifact, no drift, and it serves from build/debug"
        return 0
    fi
    echo "ok cli/$target — init, build, $artifact, and no drift"
}

one_target html shopfront build/debug/shopfront
one_target canvas drawpad build/debug/drawpad.wasm

# The canvas build's other half: a page and everything it asks for, each of
# which would otherwise be a silent 404 and a blank canvas.
canvas_out="$tmp/canvas/drawpad/build/debug"
if [[ -d "$canvas_out" ]]; then
    for wanted in index.html canvaskit/canvaskit.js canvaskit/canvaskit.wasm \
                  latte/latte-page.js latte/latte-runtime.js latte/latte-canvaskit.js \
                  latte/latte-semantics.js latte/latte-editing.js latte/latte-input.js \
                  latte/latte-link.js latte/latte-floats.js fonts/latte-regular.ttf; do
        [[ -f "$canvas_out/$wanted" ]] || note "the canvas build staged no $wanted"
    done
    # Every script the page imports has to be one of the staged ones. A module
    # latte grew and this list did not is a 404 in the browser and nothing here.
    while IFS= read -r imported; do
        [[ -f "$canvas_out/latte/$imported" ]] || \
            note "the page's latte/$imported was not staged — add it to cli/assets.b"
    done < <(grep -ohE 'from "\./[a-z-]+\.js"' "$canvas_out"/latte/*.js 2>/dev/null |
             sed 's|from "\./||; s|"||' | sort -u)
    [[ $status -eq 0 ]] && echo "ok cli/page — the page and every module it imports are staged"
fi

# --- the refusals: each beside its accepted case above, and each asserting
# its OWN message, since an earlier refusal for another reason looks the same.
refuses() {
    local what=$1 where=$2 saying=$3; shift 3
    if (cd "$where" && "$@") >"$tmp/refusal.log" 2>&1; then
        note "$what was ACCEPTED"
        return 0
    fi
    if ! grep -qF "$saying" "$tmp/refusal.log"; then
        note "$what was refused, but for another reason"
        echo "    wanted: $saying" >&2
        sed 's/^/    got:    /' "$tmp/refusal.log" >&2
        return 0
    fi
    echo "ok cli/refuses — $what"
}
mkdir -p "$tmp/empty"
refuses "a name that cannot be a module" "$tmp" \
    "cannot be a module name" "$latte" init 9lives
refuses "init over a project that is already there" "$tmp/html" \
    "beans.pot is already there" "$latte" init shopfront
refuses "a target latte has not" "$tmp" \
    "is not a target" "$latte" init newthing --target svg
refuses "an option latte has not" "$tmp" \
    "is not an option latte has" "$latte" build --fast
refuses "a build with no project above it" "$tmp/empty" \
    "no beans.pot here or above" "$latte" build
refuses "markup no folder covers" "$tmp/canvas/drawpad" \
    "is outside every markup folder" sh -c \
    'mkdir -p parts && cp site/shell.bx parts/stray.bx && "$0" generate; s=$?; rm -rf parts; exit $s' "$latte"

# --- the installed package: install the archive, then build git-pinned projects,
# the remote a snapshot of THIS tree via url.insteadOf, with a private package cache.
version=$(bash "$ROOT/tools/check_version.sh" --print)
dist=${LATTE_DIST:-}
if [[ -z "$dist" ]]; then
    dist="$tmp/dist"
    kit_args=()
    [[ -n ${LATTE_KIT:-} ]] && kit_args=(--kit "$LATTE_KIT")
    bash "$ROOT/tools/package_cli.sh" "$dist" ${kit_args[@]+"${kit_args[@]}"} \
        >"$tmp/package.log" 2>&1 || {
        note "tools/package_cli.sh could not package this tree"
        cat "$tmp/package.log" >&2
        exit 1
    }
fi
archive=$(cd "$dist" && ls latte-v"$version"-*.tar.gz 2>/dev/null | head -1 || true)
if [[ -z "$archive" ]]; then
    note "no latte-v$version-*.tar.gz in $dist"
    exit 1
fi
base="$tmp/release"
mkdir -p "$base"
cp "$dist/$archive" "$base/"
(cd "$dist" && cat "$archive.sha256") >"$base/SHA256SUMS"
cp "$ROOT/tools/latte-install.sh" "$base/"

home="$tmp/home"
LATTE_INSTALL_BASE_URL="$base" sh "$base/latte-install.sh" --prefix "$home" --no-modify-path \
    >"$tmp/install.log" 2>&1 || { note "the installer refused its own release"; cat "$tmp/install.log" >&2; exit 1; }
installed="$home/bin/latte"
got=$("$installed" version)
[[ "$got" == "latte $version" ]] || note "the installed launcher says '$got'"
mkdir -p "$tmp/empty"
(cd "$tmp/empty" && "$installed" doctor) >"$tmp/doctor.log" 2>&1 ||
    { note "'latte doctor' failed outside a project"; cat "$tmp/doctor.log" >&2; }
grep -q "ok       page kit" "$tmp/doctor.log" || note "doctor did not vouch for the installed kit"
echo "ok cli/install — $archive installs, runs, and doctor vouches for its kit"

src="$tmp/latte-src"
mkdir -p "$src"
(cd "$ROOT" && git ls-files -co --exclude-standard | while IFS= read -r f; do
    [[ -f "$f" ]] && printf '%s\n' "$f"; done >"$tmp/snapshot.list" &&
    tar cf - -T "$tmp/snapshot.list") | (cd "$src" && tar xf -)
(cd "$src" && git init -q && git add -A &&
    git -c user.name=gate -c user.email=gate@localhost commit -qm snapshot &&
    git tag "v$version" && git tag v0.1.9)
printf '[url "file://%s"]\n\tinsteadOf = https://github.com/beans-lang/latte.git\n' "$src" >"$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export BEANS_HOME="$tmp/beans-home"
mkdir -p "$BEANS_HOME" "$tmp/pinned"

# A canvas project pinned by git: its page must come from the installed kit.
mark=$failures
(cd "$tmp/pinned" && "$installed" init padkit --target canvas && cd padkit &&
    "$installed" build) >"$tmp/pinned-canvas.log" 2>&1 || {
    note "an installed latte could not build the canvas project it scaffolded"
    cat "$tmp/pinned-canvas.log" >&2
}
out="$tmp/pinned/padkit/build/debug"
if [[ -f "$out/padkit.wasm" ]]; then
    grep -q "from this latte's own kit" "$tmp/pinned-canvas.log" ||
        note "the canvas page did not come from the installed kit"
    for staged in canvaskit/canvaskit.wasm canvaskit/canvaskit.js latte/latte-page.js fonts/latte-regular.ttf; do
        from="$home/share/latte/${staged/latte\//js/}"
        cmp -s "$out/$staged" "$from" || note "$staged is not the installed kit's $from"
    done
    grep -q 'import github.com/beans-lang/latte/browser' "$tmp/pinned/padkit/main.b" ||
        note "a git-pinned main.b does not import latte by its git path"
    [[ $failures -eq $mark ]] && echo "ok cli/pinned-canvas — builds from git, and the page, CanvasKit and fonts are the installed kit's"
fi

# An html project pinned by git: espresso and barista come from GitHub.
(cd "$tmp/pinned" && "$installed" init shopkit && cd shopkit &&
    "$installed" build) >"$tmp/pinned-html.log" 2>&1 || {
    note "an installed latte could not build the html project it scaffolded"
    cat "$tmp/pinned-html.log" >&2
}
if [[ -x "$tmp/pinned/shopkit/build/debug/shopkit" ]] &&
    serves "$tmp/pinned/shopkit/build/debug" shopkit "<h1>shopkit</h1>"; then
    echo "ok cli/pinned-html — builds from git and serves from build/debug"
fi

# A pin to another latte is refused before compiling; --project moves it and the lock.
mark=$failures
padkit="$tmp/pinned/padkit"
(cd "$padkit" && "$BEANSC" pot add github.com/beans-lang/latte v0.1.9) >"$tmp/pot.log" 2>&1 ||
    { note "could not pin padkit to v0.1.9"; cat "$tmp/pot.log" >&2; }
refuses "a build pinned to another latte than the installed one" "$padkit" \
    "this latte's page kit is for v$version" "$installed" build
(cd "$padkit" && "$installed" upgrade --project) >"$tmp/repin.log" 2>&1 ||
    { note "'latte upgrade --project' failed"; cat "$tmp/repin.log" >&2; }
grep -q "require github.com/beans-lang/latte v$version" "$padkit/beans.pot" ||
    note "upgrade --project did not move beans.pot's pin"
grep -q "^module github.com/beans-lang/latte v$version " "$padkit/beans.lock" ||
    note "upgrade --project moved the pin and not the lock"
(cd "$padkit" && "$installed" upgrade --project) 2>&1 | grep -q "nothing to move" ||
    note "a second upgrade --project was not a no-op"
(cd "$padkit" && "$installed" build) >/dev/null 2>&1 || note "the build after upgrade --project failed"

# When beansc cannot resolve the new pin, the manifest is put back.
(cd "$padkit" && "$BEANSC" pot add github.com/beans-lang/latte v0.1.9) >/dev/null 2>&1 ||
    note "could not pin padkit back to v0.1.9"
git -C "$src" tag -d "v$version" >/dev/null
refuses "a repin beansc cannot resolve" "$padkit" \
    "so it is back as it was" "$installed" upgrade --project
grep -q "require github.com/beans-lang/latte v0.1.9" "$padkit/beans.pot" ||
    note "a failed upgrade --project left beans.pot moved"
git -C "$src" tag "v$version"
[[ $failures -eq $mark ]] && echo "ok cli/upgrade-project — refuses a stale pin, moves pin and lock together, and puts back what beansc refused"

# The launcher's own upgrade, against the local release.
mark=$failures
LATTE_INSTALL_BASE_URL="$base" "$installed" upgrade >"$tmp/self.log" 2>&1 ||
    { note "'latte upgrade' failed"; cat "$tmp/self.log" >&2; }
grep -q "already installed" "$tmp/self.log" || note "'latte upgrade' on the current version did not say so"
LATTE_INSTALL_BASE_URL="$base" "$installed" upgrade --force >"$tmp/self.log" 2>&1 ||
    { note "'latte upgrade --force' failed"; cat "$tmp/self.log" >&2; }
[[ "$("$installed" version)" == "latte $version" ]] || note "latte did not run after upgrade --force"
[[ -f "$home/share/latte/VERSION" ]] || note "upgrade --force left no kit"
refuses "an upgrade option latte has not" "$tmp" "usage: latte upgrade" "$installed" upgrade --soon
[[ $failures -eq $mark ]] && echo "ok cli/self-upgrade — the launcher reinstalls through the installer and latte still runs"

# A damaged kit is named, not papered over.
mv "$home/share/latte/canvaskit/canvaskit.wasm" "$tmp/canvaskit.wasm.away"
refuses "a canvas build from a damaged installation" "$padkit" \
    "this installation is damaged" sh -c '"$0" upgrade --project >/dev/null 2>&1; "$0" build' "$installed"
refuses "doctor on a damaged installation" "$tmp" "MISSING  page kit" "$installed" doctor
mv "$tmp/canvaskit.wasm.away" "$home/share/latte/canvaskit/canvaskit.wasm"
refuses "a git-pinned build with no installation" "$padkit" \
    "was not started from an installation" "$latte" build
refuses "'latte upgrade' from a binary that is not installed" "$tmp" \
    "this latte is not an installation" "$latte" upgrade

exit $status
