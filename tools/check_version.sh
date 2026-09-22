#!/usr/bin/env bash
# The version the binary prints, the changelog heading and the release tag
# must agree, or a release ships whatever LATTE_VERSION last happened to say.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

print_only=0
tag=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --print) print_only=1; shift ;;
        -*) echo "usage: tools/check_version.sh [--print] [<tag>]" >&2; exit 2 ;;
        *) tag=$1; shift ;;
    esac
done

version=$(sed -n 's/^pub const LATTE_VERSION: string = "\(.*\)"$/\1/p' cli/version.b)
if [[ -z "$version" ]]; then
    echo "cli/version.b does not declare LATTE_VERSION" >&2
    exit 1
fi

if [[ $print_only -eq 1 ]]; then
    echo "$version"
    exit 0
fi

status=0

# `## [Unreleased]` is not a release. The version in the binary needs its own
# heading, which is what makes a tagged build describable to whoever installs it.
if ! grep -qE "^## \[$version\]" CHANGELOG.md; then
    echo "--- version FAILED: CHANGELOG.md has no '## [$version]' heading ---" >&2
    echo "    cli/version.b says $version. The headings it does have:" >&2
    grep -nE '^## ' CHANGELOG.md | head -5 | sed 's/^/      /' >&2
    status=1
fi

if [[ -n "$tag" ]]; then
    tagged=${tag#v}
    if [[ "$tagged" != "$version" ]]; then
        echo "--- version FAILED: tag $tag is not cli/version.b's $version ---" >&2
        status=1
    fi
fi

if [[ $status -eq 0 ]]; then
    if [[ -n "$tag" ]]; then
        echo "ok version — latte $version, with a changelog heading and tag $tag"
    else
        echo "ok version — latte $version, with a changelog heading"
    fi
fi
exit $status
