#!/bin/sh
# Install latte for the current user; nothing is replaced until the download is
# checksummed and runs. curl -fsSL …/releases/latest/download/latte-install.sh | sh
set -eu

REPO=${LATTE_INSTALL_REPO:-beans-lang/latte}

say() { printf '%s\n' "$*"; }
note() { printf 'latte: %s\n' "$*"; }
die() { printf 'latte: error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: latte-install.sh [options]

  --version <v>      install this release instead of the latest (e.g. 0.2.0)
  --prefix <dir>     install here instead of $HOME/.latte
  --target <triple>  force a target instead of detecting one
  --force            reinstall even when this version is already installed
  --no-modify-path   do not touch shell startup files
  --help             show this message

environment:
  LATTE_HOME         same as --prefix
  LATTE_TARGET       same as --target
EOF
}

version=
prefix=${LATTE_HOME:-}
target=${LATTE_TARGET:-}
force=0
modify_path=1

while [ $# -gt 0 ]; do
    case $1 in
        --version) [ $# -ge 2 ] || die "--version needs a value"; version=${2#v}; shift 2 ;;
        --version=*) version=${1#*=}; version=${version#v}; shift ;;
        --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
        --prefix=*) prefix=${1#*=}; shift ;;
        --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
        --target=*) target=${1#*=}; shift ;;
        --force) force=1; shift ;;
        --no-modify-path) modify_path=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$prefix" ] || prefix=$HOME/.latte
case $prefix in
    /*) ;;
    *) die "--prefix must be an absolute path, not '$prefix'" ;;
esac

work=
# The trailing `:` keeps a cleanup that finds nothing from deciding the exit status.
cleanup() { [ -n "$work" ] && rm -rf "$work"; :; }
trap cleanup EXIT HUP INT TERM
work=$(mktemp -d "${TMPDIR:-/tmp}/latte-install.XXXXXX") ||
    die "cannot create a temporary directory"

# ------------------------------------------------------------------- fetching
if command -v curl >/dev/null 2>&1; then
    downloader=curl
elif command -v wget >/dev/null 2>&1; then
    downloader=wget
else
    die "neither curl nor wget is installed; install one and run this again"
fi

fetch_attempts=${LATTE_INSTALL_ATTEMPTS:-3}

# A stall aborts after 30 seconds and the loop retries, which curl's own
# --retry does not do for a connection that opens and then goes quiet.
fetch_once() {
    if [ "$downloader" = curl ]; then
        curl -fsSL --proto '=https' --tlsv1.2 \
             --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
             -o "$2" "$1"
    else
        wget -q --https-only --timeout=30 --tries=1 -O "$2" "$1"
    fi
}

# A bare path is how CI runs this end to end before a release exists.
fetch() {
    from=$1 to=$2
    case $from in
        http://*|https://*)
            attempt=1
            while :; do
                fetch_once "$from" "$to" && return 0
                [ "$attempt" -ge "$fetch_attempts" ] && return 1
                sleep $((attempt * 2))
                attempt=$((attempt + 1))
            done
            ;;
        *)
            [ -f "$from" ] || return 1
            cp "$from" "$to" || return 1
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------ platform
kernel=$(uname -s 2>/dev/null || echo unknown)
machine=$(uname -m 2>/dev/null || echo unknown)
libc=none
if [ "$kernel" = Linux ]; then
    # musl has no macro to ask; its loader's name is the fact that can be checked.
    libc=gnu
    for loader in /lib/ld-musl-*.so.1 /lib/libc.musl-*.so.1; do
        [ -e "$loader" ] && libc=musl && break
    done
    if [ "$libc" = gnu ] && command -v ldd >/dev/null 2>&1; then
        ldd --version 2>&1 | head -1 | grep -qi musl && libc=musl
    fi
fi

if [ -z "$target" ]; then
    case $kernel in
        Linux)
            case $machine in
                x86_64|amd64) target="x86_64-unknown-linux-$libc" ;;
                aarch64|arm64) target="aarch64-unknown-linux-$libc" ;;
            esac
            ;;
        Darwin)
            case $machine in
                arm64|aarch64) target="arm64-apple-darwin" ;;
            esac
            ;;
    esac
fi

# ------------------------------------------------------------ the checksums
base=${LATTE_INSTALL_BASE_URL:-}
base_is_ours=0
if [ -z "$base" ]; then
    base_is_ours=1
    if [ -n "$version" ]; then
        base="https://github.com/$REPO/releases/download/v$version"
    else
        base="https://github.com/$REPO/releases/latest/download"
    fi
fi

fetch "$base/SHA256SUMS" "$work/SHA256SUMS" ||
    die "cannot download the release's checksums from $base/SHA256SUMS"

# The one archive for this target; its name carries the version.
row=
if [ -n "$target" ]; then
    row=$(awk -v want="$target" '
        function ends(s, t) { return length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
        {
            name = $2; sub(/^\*/, "", name)
            if (name ~ /^latte-v/ && (ends(name, "-" want ".tar.gz") || ends(name, "-" want ".zip"))) {
                print $1 " " name; exit
            }
        }' "$work/SHA256SUMS")
fi

if [ -z "$row" ]; then
    say "latte: no released package matches this machine." >&2
    say "" >&2
    say "  operating system: $kernel" >&2
    say "  architecture:     $machine" >&2
    say "  libc:             $libc" >&2
    say "  target:           ${target:-could not be determined}" >&2
    say "" >&2
    say "Published packages:" >&2
    awk '{ n = $2; sub(/^\*/, "", n); if (n ~ /^latte-v/) printf "  %s\n", n }' "$work/SHA256SUMS" >&2
    say "" >&2
    say "Pick one with LATTE_TARGET=<triple>, or build from source:" >&2
    say "  https://github.com/$REPO#the-command-line" >&2
    exit 1
fi

expected_sha=${row%% *}
asset=${row#* }
release_version=${asset#latte-v}
release_version=${release_version%-"$target".tar.gz}
release_version=${release_version%-"$target".zip}

if [ -n "$version" ] && [ "$version" != "$release_version" ]; then
    die "the release at $base publishes $release_version, not $version"
fi
# `latest` moves: pin every later fetch to the release the checksums named.
if [ "$base_is_ours" -eq 1 ]; then
    base="https://github.com/$REPO/releases/download/v$release_version"
fi

# ---------------------------------------------------------- already installed
if [ "$force" -eq 0 ] && [ -x "$prefix/bin/latte" ]; then
    installed=$("$prefix/bin/latte" version 2>/dev/null || true)
    if [ "$installed" = "latte $release_version" ]; then
        note "latte $release_version is already installed in $prefix"
        note "re-run with --force to reinstall"
        exit 0
    fi
fi

# ------------------------------------------------------------------ download
note "downloading $asset"
fetch "$base/$asset" "$work/$asset" || die "cannot download $base/$asset"

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha=$(sha256sum <"$work/$asset" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    actual_sha=$(shasum -a 256 <"$work/$asset" | cut -d' ' -f1)
elif command -v openssl >/dev/null 2>&1; then
    actual_sha=$(openssl dgst -sha256 <"$work/$asset" | awk '{print $NF}')
else
    die "no sha256 tool found; install coreutils, perl-shasum or openssl"
fi
if [ "$actual_sha" != "$expected_sha" ]; then
    die "checksum mismatch for $asset
  expected $expected_sha
  actual   $actual_sha
Nothing was installed."
fi
note "checksum verified"

# ------------------------------------------------------- unpack and validate
mkdir "$work/stage"
case $asset in
    *.zip)
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$work/$asset" -d "$work/stage" ||
                die "cannot unpack $asset; nothing was installed"
        else
            tar xf "$work/$asset" -C "$work/stage" ||
                die "cannot unpack $asset (no unzip, and this tar does not read zip); nothing was installed"
        fi
        ;;
    *)
        tar xzf "$work/$asset" -C "$work/stage" ||
            die "cannot unpack $asset; nothing was installed"
        ;;
esac
unpacked=$(find "$work/stage" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$unpacked" ] || die "$asset does not contain a package directory"
launcher=
if [ -x "$unpacked/bin/latte" ]; then
    launcher="$unpacked/bin/latte"
elif [ -f "$unpacked/bin/latte.cmd" ]; then
    launcher="$unpacked/bin/latte.cmd"
else
    die "$asset has no bin/latte; nothing was installed"
fi
[ -f "$unpacked/share/latte/VERSION" ] ||
    die "$asset has no page kit (share/latte/VERSION); nothing was installed"

# The staged binary answers before anything moves, so a corrupt or
# wrong-architecture download never replaces a working install.
staged_version=$("$launcher" version 2>/dev/null) ||
    die "the downloaded latte does not run on this machine ($machine); nothing was installed"
[ "$staged_version" = "latte $release_version" ] ||
    die "the downloaded binary says '$staged_version', not 'latte $release_version'; nothing was installed"
note "staged $staged_version"

# ------------------------------------------------------------------- install
parent=$(dirname "$prefix")
mkdir -p "$parent" || die "cannot create $parent"
previous=
if [ -e "$prefix" ]; then
    previous="$prefix.old-$$"
    mv "$prefix" "$previous" || die "cannot move the existing $prefix aside"
fi
if ! mv "$unpacked" "$prefix"; then
    [ -n "$previous" ] && mv "$previous" "$prefix"
    die "cannot install into $prefix"
fi
[ -n "$previous" ] && rm -rf "$previous"

# ---------------------------------------------------------------------- PATH
bin_dir="$prefix/bin"
line="export PATH=\"$bin_dir:\$PATH\""
updated=
already=
if [ "$modify_path" -eq 1 ]; then
    for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$profile" ] || continue
        if grep -Fq "$bin_dir" "$profile" 2>/dev/null; then
            already="${already:+$already }$profile"
            continue
        fi
        {
            printf '\n# added by the latte installer\n'
            printf '%s\n' "$line"
        } >>"$profile" && updated="${updated:+$updated }$profile"
    done
    if [ -z "$updated" ] && [ -z "$already" ]; then
        {
            printf '\n# added by the latte installer\n'
            printf '%s\n' "$line"
        } >>"$HOME/.profile" && updated="$HOME/.profile"
    fi
fi

# ----------------------------------------------------------------- report
say ""
note "installed latte $release_version into $prefix"
if [ -n "$updated" ]; then
    note "PATH updated in: $updated — a new terminal picks it up"
elif [ -n "$already" ]; then
    note "PATH already set in: $already"
else
    note "add latte to your PATH with:"
    say ""
    say "    $line"
fi
say ""
launcher_name=$(basename "$launcher")
"$prefix/bin/$launcher_name" version || die "the installed latte did not run"
note "run 'latte doctor' to see what this machine can build"
note "move a project to this latte with 'latte upgrade --project' inside it"
