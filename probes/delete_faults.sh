#!/usr/bin/env bash
# probes/delete_faults.sh — delete every refusal in builder.b, one at a time,
# and watch the case that names it FAIL.
#
# RULES.md, "The refusal that never runs": a refusal test that still passes
# when the refusal is gone is worthless, and a refusal that cannot be made to
# fail is unreachable. Neither is visible from a green run. So this deletes
# each of the 24 `self.faults.push(...)` sites in builder.b in turn, runs
# `tests/frames.b`, and requires that a check naming THAT site turns red.
#
# It is not part of `test.sh`. It rewrites builder.b, so it must never run
# beside a gate, and it answers a question about the tests rather than about
# the code. Run it after touching a refusal, and read the table it prints.
#
# What it proves and what it does not:
#
#   - It runs the interpreter leg only. A refusal is Beans code with no
#     backend-specific behaviour, and `test.sh` already runs the suite on both;
#     what is being measured here is which ASSERTION notices, not which
#     backend.
#   - It runs `tests/frames.b` only, because § 13 of that file is where the
#     site-by-site accounting lives. A deleted refusal will also shift other
#     goldens; a golden diff says "something changed" and this says which rule.
#   - "CAUGHT" means a check whose case names that site printed FAIL. A golden
#     that merely differs is not enough: the whole point is that the failure
#     names the rule.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
beans=$(cd "$root/../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
case "$("$beansc" --version)" in
    *"0.1.40"*) ;;
    *) echo "latte is recorded against beansc 0.1.40" >&2; exit 1 ;;
esac

[[ -z ${BEANS_RUNTIME:-} && -f "$beans/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$beans/runtime/beans_rt.c"
[[ -z ${BEANS_STDLIB:-}  && -d "$beans/stdlib/std"        ]] && export BEANS_STDLIB="$beans/stdlib/std"

exec python3 - "$root" "$beansc" <<'PYTHON'
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
beansc = sys.argv[2]
source = root / "builder.b"
suite = root / "tests" / "frames.b"
golden = root / "tests" / "frames.out"

# The site labels, in the order the report sites appear in builder.b. They are
# the same strings § 13 of tests/frames.b prints, so the mapping is checkable
# by eye against the golden and does not depend on a line number.
LABELS = [
    "note_sibling / sequence N does not follow M in this scope",
    "take_attribute_slot / X is outside an element's attribute run",
    "take_attribute_slot / X does not follow Y in this element's attribute run",
    "open / refused tag name",
    "close / close with no open element",
    "attr / attribute N carried a refused scheme",
    "name_is_writable / refused attribute name",
    "name_is_writable / refused inline handler attribute",
    "attrs / refused splatted attribute name",
    "attrs / refused splatted inline handler",
    "attrs / attribute N carried a refused scheme",
    "fill_slot / slot N holds a X, not a Y",
    "mount / X is not a Component",
    "mount / cannot activate X",
    "mount / X has no zero-argument initializer",
    "mount_made / X is not a Component",
    "region / duplicate key",
    "end_region / end_region with no open region",
    "fail_boundary / fail_boundary with no open boundary",
    "end_boundary / end_boundary with no open boundary",
    "unwind_to / an element was left open",
    "unwind_to / a region was left open",
    "unwind_to / a fragment was left open",
    "unwind_to / a boundary was left open",
]


def find_sites(text):
    """Every `self.faults.push( … )` expression, as (start, end) offsets.

    The end is found by balancing parentheses while ignoring anything inside a
    double-quoted string, because the messages themselves carry `(` and `)` —
    `{problem.message()}` for one.
    """
    out = []
    for match in re.finditer(r"self\.faults\.push\(", text):
        i = match.end()
        depth = 1
        in_string = False
        while depth:
            ch = text[i]
            if in_string:
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
        out.append((match.start(), i))
    return out


def cases_by_site(golden_text):
    """case name -> site label, read out of the suite's own output."""
    mapping = {}
    name = None
    for line in golden_text.splitlines():
        if line.startswith("-- "):
            name = line[3:].strip()
        elif line.strip().startswith("site:") and name is not None:
            mapping.setdefault(line.split("site:", 1)[1].strip(), []).append(name)
    return mapping


original = source.read_text()
sites = find_sites(original)
by_site = cases_by_site(golden.read_text())

if len(sites) != len(LABELS):
    print(f"builder.b has {len(sites)} report sites, this script names "
          f"{len(LABELS)}. Add the new one to LABELS, in file order.",
          file=sys.stderr)
    sys.exit(1)
missing = [label for label in LABELS if label not in by_site]
if missing:
    print("no case in tests/frames.out names these sites:", file=sys.stderr)
    for label in missing:
        print(f"  {label}", file=sys.stderr)
    print("the suite and this script have drifted apart", file=sys.stderr)
    sys.exit(1)


def run_suite():
    done = subprocess.run([beansc, "run", str(suite)], cwd=root,
                          capture_output=True, text=True)
    return done.returncode, done.stdout, done.stderr


code, out, err = run_suite()
if code != 0 or "FAIL" in out:
    print("tests/frames.b is not green before the pass starts; fix that first",
          file=sys.stderr)
    print(err or out, file=sys.stderr)
    sys.exit(1)

failures = 0
print(f"deleting {len(sites)} report sites in {source.name}, one at a time\n")
try:
    for index, (start, end) in enumerate(sites):
        label = LABELS[index]
        patched = original[:start] + "let _: bool = true" + original[end:]
        source.write_text(patched)
        code, out, err = run_suite()
        source.write_text(original)

        if code != 0:
            print(f"?? {label}\n   the suite did not run with the site "
                  f"deleted:\n{(err or out).strip()}")
            failures += 1
            continue

        red = [line[5:].split(":", 1)[0]
               for line in out.splitlines() if line.startswith("FAIL ")]
        mine = [name for name in red if name in by_site[label]]
        if mine:
            shown = ", ".join(sorted(set(mine))[:3])
            more = "" if len(set(mine)) <= 3 else f", +{len(set(mine)) - 3} more"
            print(f"ok {label}\n   CAUGHT by {len(set(mine))} case(s): {shown}{more}")
        else:
            print(f"XX {label}\n   DELETED AND NOTHING NOTICED — the cases that "
                  f"name it are {', '.join(by_site[label])}")
            if red:
                print(f"   (other cases did fail: {', '.join(sorted(set(red))[:5])})")
            failures += 1
finally:
    source.write_text(original)

print()
if failures:
    print(f"{len(sites) - failures} of {len(sites)} report sites are guarded; "
          f"{failures} are not", file=sys.stderr)
    sys.exit(1)
print(f"all {len(sites)} report sites are guarded: deleting each one turns a "
      f"check that names it red")
PYTHON
