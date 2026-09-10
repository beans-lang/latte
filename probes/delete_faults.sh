#!/usr/bin/env bash
# probes/delete_faults.sh — delete every refusal in latte's core, one at a
# time, and watch the case that names it FAIL.
#
# A refusal test that still passes when the refusal is gone is worthless, and
# a refusal that cannot be made to fail is unreachable. Neither is visible
# from a green run. So this deletes
# each `self.faults.push(...)` site in turn, runs the suite that owns it, and
# requires that a check naming THAT site turns red.
#
#   builder.b     27 sites   tests/frames.b § 13
#   apply.b       14 sites   tests/w1_faults.b § 1
#   serialize.b    4 sites   tests/w1_faults.b § 3
#   stream.b      24 sites   tests/w6_stream.b § 4
#   virtual.b      1 site    tests/w6_virtual.b § 4
#   upload.b       1 site    tests/w6_upload.b § 6
#   forms.b       16 sites   tests/w4_forms.b § 6
#   persist.b      2 sites   tests/l8_persist.b § 8
#
# Run it with no argument for all three, or name one source file to run just
# that one: `probes/delete_faults.sh apply.b`.
#
# It is not part of `test.sh`. It rewrites the source files, so it must never
# run beside a gate, and it answers a question about the tests rather than
# about the code. Run it after touching a refusal, and read the table it
# prints.
#
# What it proves and what it does not:
#
#   - It runs the interpreter leg only. A refusal is Beans code with no
#     backend-specific behaviour, and `test.sh` already runs both suites on
#     both backends; what is being measured here is which ASSERTION notices,
#     not which backend.
#   - It runs one suite per source file, because that is where the
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
only="${1:-}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
case "$("$beansc" --version)" in
    *"0.1.41"*) ;;
    *) echo "latte is recorded against beansc 0.1.41" >&2; exit 1 ;;
esac

[[ -z ${BEANS_RUNTIME:-} && -f "$beans/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$beans/runtime/beans_rt.c"
[[ -z ${BEANS_STDLIB:-}  && -d "$beans/stdlib/std"        ]] && export BEANS_STDLIB="$beans/stdlib/std"
# The bridge roots, the same five `test.sh` pins. Two of them are not optional
# here: `tests/w4_forms.b` reaches `std.crypto` through `latte.web`, and
# `std.crypto` finds its digest under the NETWORKING bridge — so without
# BEANS_NET this probe dies with "networking bridge 'hash' is unavailable" and
# reports `forms.b` as "not green before the pass starts", which reads as a
# broken suite rather than a missing export.
[[ -z ${BEANS_ENCODING:-} && -d "$beans/runtime/encoding" ]] && export BEANS_ENCODING="$beans/runtime/encoding"
[[ -z ${BEANS_NET:-}      && -d "$beans/runtime/net"      ]] && export BEANS_NET="$beans/runtime/net"
[[ -z ${BEANS_LOG:-}      && -d "$beans/runtime/log"      ]] && export BEANS_LOG="$beans/runtime/log"

exec python3 - "$root" "$beansc" "$only" <<'PYTHON'
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
beansc = sys.argv[2]
only = sys.argv[3]

# One entry per source file: the suite whose golden carries its site-by-site
# accounting, and the site labels in the order the report sites appear in the
# source. The labels are the same strings the suite prints on its `site:`
# lines, so the mapping is checkable by eye against the golden and does not
# depend on a line number.
#
# The mapping from a site to its cases is proven by the run itself rather than
# asserted: if two labels were swapped, deleting one site would fail the other
# site's cases and this would report it as unguarded.
#
# But "reported as unguarded" is exactly what a real hole looks like too. On
# 2026-09-09 a label inserted three positions early sent a reader into the wrong
# code: three consecutive sites reported DELETED AND NOTHING NOTICED and every
# one of them was in fact guarded. So the order is CHECKED before a single site
# is deleted — `check_order` reads the `fn`, and any `match` arm, each site sits
# inside, and requires the label's own prefix to name one of them. A label in
# the wrong place is now a refusal that names both the line and the label,
# rather than a run that blames the code.
FILES = [
    {
        "source": "builder.b",
        "suite": "tests/frames.b",
        "labels": [
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
            "live_text / live expression N read no signal",
            "fill_slot / slot N holds a X, not a Y",
            "mount / an @inject field could not be filled",
            "mount / X is not a Component",
            "mount / cannot activate X",
            "mount / X has no zero-argument initializer",
            "mount_made / an @inject field could not be filled",
            "mount_made / X is not a Component",
            "region / duplicate key",
            "end_region / end_region with no open region",
            "fail_boundary / fail_boundary with no open boundary",
            "end_boundary / end_boundary with no open boundary",
            "unwind_to / an element was left open",
            "unwind_to / a region was left open",
            "unwind_to / a fragment was left open",
            "unwind_to / a boundary was left open",
        ],
    },
    {
        "source": "apply.b",
        "suite": "tests/w1_faults.b",
        "labels": [
            "root_for / update for component N arrived before its mount",
            "step_in / step_in N of M",
            "step_out / step_out at the root",
            "insert / insert at N of M",
            "insert / no staged subtree at N",
            "remove / remove N of M",
            "relocate / move from N of M",
            "relocate / move to N of M",
            "remove_attr / no attribute S:N to remove",
            "remove_handler / no handler S:E to remove",
            "run / the edit stream ended N level(s) deep",
            "kid / WHAT N of M",
            "wrong_kind_at / OP N needs a WANT node, not a GOT node",
            "wrong_kind / OP needs a WANT node, not a GOT node",
        ],
    },
    {
        "source": "forms.b",
        "suite": "tests/w4_forms.b",
        "labels": [
            "scan_forms / a @field on a type that is not a @form",
            "scan_forms / a rule on a type that is not a @form",
            "check_form_pages / a form page no unsafe method reaches",
            "check_form_pages / an unsafe method with no form",
            "plan_for_form / a @form that declares no @field",
            "bind_fields / a rule on a field that is not a @field",
            "bind_fields / two @fields with one posted name",
            "bind_fields / a @field that is not public",
            "bind_fields / a @field a form cannot bind",
            "read_rules / @required on a checkbox",
            "read_rules / a negative @length floor",
            "read_rules / a @length no value can satisfy",
            "read_rules / a @length that bounds nothing",
            "read_rules / @length on something that is not a string",
            "read_rules / @range on something that is not a number",
            "adopt_range / a @range no value can satisfy",
        ],
    },
    {
        "source": "stream.b",
        "suite": "tests/w6_stream.b",
        "labels": [
            "head / a streamed document has one head",
            "head / ID is not a usable slot id",
            "head / the slot ID is promised twice by one page",
            "head / the page's head carries chunk framing of its own",
            "chunk / the chunk for ID was written before the page's head",
            "chunk / the chunk for ID was written after the document ended",
            "chunk / ID is not a slot this page left open",
            "chunk / the slot ID was filled twice",
            "chunk / the chunk for ID carries chunk framing of its own",
            "tail / a streamed document ended before it had a head",
            "tail / a streamed document ends once",
            "tail / the page's tail carries chunk framing of its own",
            "tail / the document ended with N slot(s) never filled",
            "ChunkReader.refuse / the one funnel every reader refusal goes through",
            "open / a streamed page is opened once",
            "open / the region named X cannot be a slot id",
            "open / two regions on this page are both named X",
            "open / N streamed region(s) but no @stream",
            "open / @stream but no StreamRegion",
            "resolve / ID is not a region of this page",
            "gone / the region ID is no longer mounted",
            "emit / the region ID is no longer a StreamRegion",
            "emit / a fault the serializer raised on the region's frames",
            "close / a streamed page was closed before it was opened",
        ],
    },
    {
        "source": "virtual.b",
        "suite": "tests/w6_virtual.b",
        "labels": [
            "render / a misconfigured list renders nothing and says why",
        ],
    },
    {
        "source": "upload.b",
        "suite": "tests/w6_upload.b",
        "labels": [
            "render / a misconfigured control renders nothing that can be posted to",
        ],
    },
    {
        "source": "persist.b",
        "suite": "tests/l8_persist.b",
        "labels": [
            "persist_plan / a @persist field that is not public",
            "persist_plan / a @persist field that is not a scalar",
        ],
    },
    {
        "source": "serialize.b",
        "suite": "tests/w1_faults.b",
        "labels": [
            "one / no frame buffer for the T mounted at slot N",
            "one / F is not a child position",
            "element / void element <T> was given children",
            "content / WHAT inside <T> could close it",
        ],
    },
]

if only:
    FILES = [entry for entry in FILES if entry["source"] == only]
    if not FILES:
        print(f"no source file named {only}; this script knows builder.b, "
              f"apply.b, serialize.b, stream.b, virtual.b, upload.b, "
              f"forms.b and persist.b", file=sys.stderr)
        sys.exit(1)


def find_sites(text):
    """Every `<receiver>.faults.push( … )` expression, as (start, end) offsets.

    The receiver is anything, not only `self`. It was `self` until 2026-09-08,
    which meant a refusal written in a free function — the shape a whole-program
    scan writes them in — was invisible to this script and to test.sh's
    refusal-coverage leg alike. Comment lines are skipped so that a file
    explaining the rule is not deleted by it.

    The end is found by balancing parentheses while ignoring anything inside a
    double-quoted string, because the messages themselves carry `(` and `)` —
    `{problem.message()}` for one.
    """
    out = []
    for match in re.finditer(r"[A-Za-z_][A-Za-z0-9_.\[\]]*\.faults\.push\(", text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if text[line_start:match.start()].lstrip().startswith("//"):
            continue
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


ARM = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^()]*\))?\s*=>\s*$")


def enclosing_names(text, offset):
    """Every name that encloses a site: its `fn`, and each open `match` arm.

    A label's prefix names the thing a reader would go looking for. Usually
    that is the function — but in `apply.b` it is the arm of the one `match`
    over edit operations, and `run / insert at N of M` would be a worse name
    than `insert / insert at N of M`. Both spellings are accepted, so the check
    below constrains the label without dictating which of the two it uses.

    Braces are counted with string literals skipped, because a Beans message is
    full of `{...}` interpolation and a naive count closes the function early.
    """
    start = 0
    name = None
    for match in re.finditer(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]", text):
        if match.start() > offset:
            break
        start, name = match.end(), match.group(1)

    names = [name] if name else []
    stack = []
    i, in_string = start, False
    while i < offset:
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 1
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "{":
            head = ARM.search(text[text.rfind("\n", 0, i) + 1:i].rstrip())
            stack.append(head.group(1) if head else None)
        elif ch == "}":
            if stack:
                stack.pop()
        i += 1
    return names + [arm for arm in stack if arm]


def check_order(text, sites, labels):
    """Every label's prefix must name the `fn` — or the `match` arm — its site
    is in.

    This is the one drift the count check cannot see. `len(sites) ==
    len(labels)` still holds when a label is inserted at the wrong index: the
    labels below it all shift by one, every site is then reported under its
    neighbour's name, and the run blames the code for a bookkeeping mistake.

    It does not order two sites that share one prefix — four of `mount`'s five
    refusals do. That residue is small and, once this check passes, it is the
    ONLY way a label can still be misplaced, which is worth knowing when a run
    reports a site as unguarded.
    """
    wrong = []
    for index, (start, _) in enumerate(sites):
        label = labels[index]
        want = label.split(" / ", 1)[0].split(".")[-1]
        names = enclosing_names(text, start)
        if want not in names:
            line = text.count("\n", 0, start) + 1
            wrong.append((line, " / ".join(names) or "nothing named", label))
    return wrong


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


def run_suite(suite):
    done = subprocess.run([beansc, "run", str(root / suite)], cwd=root,
                          capture_output=True, text=True)
    return done.returncode, done.stdout, done.stderr


# Everything is checked BEFORE the first source file is touched, so a script
# that is going to refuse does it without having rewritten anything.
plan = []
for entry in FILES:
    source = root / entry["source"]
    golden = root / (entry["suite"][:-2] + ".out")
    text = source.read_text()
    sites = find_sites(text)
    if len(sites) != len(entry["labels"]):
        print(f"{entry['source']} has {len(sites)} report sites, this script "
              f"names {len(entry['labels'])}. Add the new one to its LABELS, "
              f"in file order.", file=sys.stderr)
        sys.exit(1)
    wrong = check_order(text, sites, entry["labels"])
    if wrong:
        print(f"{entry['source']}: LABELS are out of file order — a site is "
              f"lined up with a label from a different function:", file=sys.stderr)
        for line, got, label in wrong:
            print(f"  line {line} is inside {got}, but its label says "
                  f"\"{label}\"", file=sys.stderr)
        print("reorder LABELS to match the source; the count check cannot see "
              "this", file=sys.stderr)
        sys.exit(1)
    by_site = cases_by_site(golden.read_text())
    missing = [label for label in entry["labels"] if label not in by_site]
    if missing:
        print(f"no case in {golden.name} names these {entry['source']} sites:",
              file=sys.stderr)
        for label in missing:
            print(f"  {label}", file=sys.stderr)
        print("the suite and this script have drifted apart", file=sys.stderr)
        sys.exit(1)
    plan.append({"entry": entry, "source": source, "sites": sites,
                 "by_site": by_site})

for suite in sorted({entry["suite"] for entry in FILES}):
    code, out, err = run_suite(suite)
    if code != 0 or "FAIL" in out:
        print(f"{suite} is not green before the pass starts; fix that first",
              file=sys.stderr)
        print(err or out, file=sys.stderr)
        sys.exit(1)

total = sum(len(step["sites"]) for step in plan)
failures = 0
guarded = 0
print(f"deleting {total} report sites, one at a time\n")
originals = {}
try:
    for step in plan:
        entry = step["entry"]
        source = step["source"]
        original = source.read_text()
        originals[source] = original
        print(f"--- {entry['source']} ({len(step['sites'])} sites, "
              f"{entry['suite']})")
        for index, (start, end) in enumerate(step["sites"]):
            label = entry["labels"][index]
            patched = original[:start] + "let _: bool = true" + original[end:]
            source.write_text(patched)
            code, out, err = run_suite(entry["suite"])
            source.write_text(original)

            if code != 0:
                print(f"?? {label}\n   the suite did not run with the site "
                      f"deleted:\n{(err or out).strip()}")
                failures += 1
                continue

            red = [line[5:].split(":", 1)[0]
                   for line in out.splitlines() if line.startswith("FAIL ")]
            mine = [name for name in red if name in step["by_site"][label]]
            if mine:
                shown = ", ".join(sorted(set(mine))[:3])
                more = "" if len(set(mine)) <= 3 else f", +{len(set(mine)) - 3} more"
                print(f"ok {label}\n   CAUGHT by {len(set(mine))} case(s): {shown}{more}")
                guarded += 1
            else:
                print(f"XX {label}\n   DELETED AND NOTHING NOTICED — the cases "
                      f"that name it are {', '.join(step['by_site'][label])}")
                if red:
                    print(f"   (other cases did fail: {', '.join(sorted(set(red))[:5])})")
                failures += 1
finally:
    for source, text in originals.items():
        source.write_text(text)

print()
if failures:
    print(f"{guarded} of {total} report sites are guarded; {failures} are not",
          file=sys.stderr)
    sys.exit(1)
print(f"all {total} report sites are guarded: deleting each one turns a "
      f"check that names it red")
PYTHON
