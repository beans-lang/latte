#!/usr/bin/env bash
# The version the binary prints, the changelog heading, the release tag, and the
# espresso/barista pins the CLI writes must each agree with what they mirror.
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

# An application pins what latte pins, or beansc refuses two refs in one graph.
pin_of() { sed -n "s/^pub const $1: string = \"\(.*\)\"$/\1/p" cli/version.b; }
row_of() { sed -n "s|^require github.com/beans-lang/$2 \([^ ]*\).*|\1|p" "$1"; }
for check in "ESPRESSO_PIN espresso beans.pot" "ESPRESSO_PIN espresso app/beans.pot" \
             "BARISTA_PIN barista app/beans.pot"; do
    set -- $check
    want=$(pin_of "$1")
    have=$(row_of "$3" "$2")
    if [[ -z "$want" || "$want" != "$have" ]]; then
        echo "--- version FAILED: cli/version.b's $1 is '${want:-?}', $3 requires $2 at '${have:-?}' ---" >&2
        status=1
    fi
done

if [[ -n "$tag" ]]; then
    tagged=${tag#v}
    if [[ "$tagged" != "$version" ]]; then
        echo "--- version FAILED: tag $tag is not cli/version.b's $version ---" >&2
        status=1
    fi
fi

if [[ $status -eq 0 ]]; then
    if [[ -n "$tag" ]]; then
        echo "ok version — latte $version, with a changelog heading, its pins, and tag $tag"
    else
        echo "ok version — latte $version, with a changelog heading and its pins"
    fi
fi
exit $status
