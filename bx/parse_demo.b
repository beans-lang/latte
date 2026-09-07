// parse_demo.b — the parse half of the `bx` golden, in one callable place.
//
// The gate for `bx` is `tests/bx.b`, and that file is the driver agent's: it
// prints the parse goldens, the attribute-table goldens, the emitted source
// and the diagnostics, in that order, and `./test.sh` diffs the whole thing
// against `tests/bx.out` on both backends. Rather than have two agents edit
// one test file, the parse half lives here as one function the gate calls,
// and the front end owns it the way it owns `lex.b` and `parse.b`.
//
// It prints rather than answering a string, so the call site is one line —
// `bx.parse_demo()` — and so a case can be added here without the gate file
// changing at all.
//
// What is in it, and why each group earns its lines:
//
//   * **shapes** — every node and attribute form in ast.b, at least once.
//   * **the split rule** — all the ramp cases named in parse.b's header. The
//     split is the one real decision the parser makes and a wrong guess is
//     silent, so every case that shaped the rule is pinned here.
//   * **brace balancing** — the reason lex.b carries a mode stack. A handler
//     body with braces, a string holding a close brace, the brace escapes, an
//     escaped quote, a trailing backslash, an interpolation holding a nested
//     string, a map literal (two open braces in a row) and blocks three deep.
//     Every one of them ends the attribute in the wrong place under a naive
//     brace count. The last case is the opposite proof: a lone open brace in
//     a string really is an interpolation, and beansc refuses that source too
//     ("string not closed before end of line"), so agreeing with it is right.
//   * **escapes** — an attribute value resolves them and a literal child does
//     not, which is a deliberate asymmetry ast.b explains. The control
//     characters are printed as byte codes rather than as themselves: a
//     golden file with a raw tab in it is one editor away from a false diff.
//   * **diagnostics** — one case per message, plus one tag carrying four
//     mistakes, because a parser that reports one fault per run is a bad
//     parser and only a multi-fault case proves this one is not.

package bx

import std.io

/// Print the parse goldens. Called by `tests/bx.b`; see the header.
pub fn parse_demo() {
    let mid: string = "package main\n\nfn view(n: int) -> Div \{\n    let head: Div = <div flex gap-2>\"Total: \{n\}\"</div>\n    let tail: Div = <div mt-4>\{footer\}</div>\n    if n > 0 \{ io.println(\"this string never closes\n\}\n"
    show_head("bx parse — shapes")
    show_case("the DESIGN.md example", "<div flex gap-2 bg=\"red\" on:click=\{fn(e: int) \{ io.println(\"clicked \{e\}\") \}\}>\n    \{inner\}\n</div>")
    show_case("a nested tag, a literal child and a hole", "<div flex gap-2 bg=\"red\">\n    <span text-lg>\"Count: \{n\}\"</span>\n    \{inner\}\n</div>")
    show_case("self-closing, spaced and tight", "<div><br /><br/></div>")
    show_case("expression attributes", "<div w=\{my_width\} bg=\{theme.accent\} id=\"row-7\" />")
    show_case("an empty tag", "<div></div>")
    show_case("three levels, and a tag name with a dot", "<ui.Panel flex><div gap-2><span>\"deep\"</span></div></ui.Panel>")

    show_head("bx parse — the ramp split rule")
    show_case("every case the split rule has to get right", "<div gap-2 w-full m-neg-4 mt-1p5 rounded-lg border-t-2 gap-x-4 rounded-tl-lg w-1/2 />")
    show_case("a flag is a name with no hyphen", "<div flex relative truncate />")
    show_case("a hyphenated name with a value is not a ramp", "<div font-family=\"Inter\" line-height=\{1.4\} />")
    io.println("")
    show_split("gap-2")
    show_split("w-full")
    show_split("m-neg-4")
    show_split("mt-1p5")
    show_split("rounded-lg")
    show_split("border-t-2")
    show_split("gap-x-4")
    show_split("rounded-tl-lg")
    show_split("w-1/2")
    show_split("m-neg-neg-4")
    show_split("p-px")
    show_split("border-t")

    show_head("bx parse — brace balancing")
    show_case("a handler whose body has braces and an interpolated string", "<div on:click=\{fn(e: int) \{ io.println(\"clicked \{e\}\") \}\} />")
    show_case("a handler whose string contains a close brace", "<div on:click=\{fn() \{ io.println(\"\}\") \}\} />")
    show_case("a handler whose string contains the brace escapes", "<div on:click=\{fn() \{ io.println(\"a \\\{ b \\\} c\") \}\} />")
    show_case("a handler whose string contains an escaped quote", "<div on:click=\{fn() \{ io.println(\"say \\\"hi\\\"\") \}\} />")
    show_case("a handler whose string ends in a backslash escape", "<div on:click=\{fn() \{ io.println(\"back \\\\\") \}\} />")
    show_case("an interpolation that itself contains a string", "<div label=\{\"a \{fmt.pad_left(\"x\", 3)\} b\"\} />")
    show_case("a map literal, which is two open braces in a row", "<div data=\{\{\"a\": 1, \"b\": 2\}\} />")
    show_case("nested blocks, several levels deep", "<div on:mouse_down=\{fn(e: int) \{ if e > 0 \{ io.println(\"\{e\}\") \} else \{ io.println(\"\\\}\") \} \}\} />")
    show_case("a hole in child position with the same problem", "<div>\{rows.map(fn(r: int) -> string \{ return \"row \{r\}\" \})\}</div>")
    show_case("a lone \{ in a string is an interpolation, not a literal brace", "<div on:click=\{fn() \{ io.println(\"\{\") \}\} />")

    show_head("bx parse — escapes")
    io.println("")
    show_escape_bytes("every escape Beans has", "\"a\\nb\\tc\\rd\\0e\\\\f\\\"g\\\{h\\\}i\"")
    show_escape_bytes("an escape Beans does not have", "\"a\\qb\"")
    show_escape_bytes("a trailing lone backslash", "\"a\\\"")
    show_case("an attribute value resolves its printable escapes", "<div title=\"\\\{d\\\} \\\"e\\\" \\\\f\" />")
    show_case("a literal child keeps every escape as written", "<div>\"\\\{d\\\} \\\"e\\\" \\\\f\"</div>")
    show_case("a literal child keeps its Beans interpolation", "<div>\"Count: \{n\} of \{total\}\"</div>")

    show_head("bx parse — diagnostics")
    show_case("a tag that was never closed", "<div flex>")
    show_case("an open tag that was never finished", "<div flex")
    show_case("a string that was never closed", "<div bg=\"red\n/>")
    show_case("braces that were never balanced", "<div w=\{1 + (2 />")
    show_case("a close tag naming the wrong element", "<div>\"x\"</span>")
    show_case("a close tag belonging to an ancestor", "<a><b><c></a>")
    show_case("a close tag with no name", "<div></>")
    show_case("a close tag missing its >", "<div></div")
    show_case("a handler given a string", "<div on:click=\"hi\" />")
    show_case("a handler given no value at all", "<div on:click />")
    show_case("an attribute with an equals and no value", "<div gap= />")
    show_case("a namespace bx does not have", "<div bind:value=\{x\} />")
    show_case("on: with no event after it", "<div on:=\{handler\} />")
    show_case("a ramp with an empty step", "<div gap- />")
    show_case("a tag with no name", "<>")
    show_case("a stray value with no attribute name", "<div \"red\" />")
    show_case("junk in child position", "<div>= 7</div>")
    show_case("four mistakes in one tag, all reported", "<div gap= bind:x=\"1\" on:click=\"hi\" 7>")


    show_head("bx parse — walking a file")
    walk_file(mid)

    show_head("bx parse — the Result form")
    show_result("one clean tag", "<div flex gap-2>\{inner\}</div>")
    show_result("a tag with faults", "<div gap= >")
    show_result("two tags", "<br /> <br />")
    show_result("no tag at all", "let x = 1")
}

/// A section heading.
fn show_head(title: string) {
    io.println("")
    io.println("=== {title}")
}

/// Parse one source and print the source, the tree, the diagnostics, and the
/// offset the tag ended at.
///
/// The source goes out line by line between two `|` so a diff says which line
/// moved, and so a source containing a newline cannot be mistaken for the
/// tree under it. The closing `|` is not decoration: a `.bx` line may end in
/// a space, and a golden file with trailing whitespace in it is one editor
/// away from a false diff. `end` is printed because a driver walking a `.bx`
/// file resumes there, and an off-by-one in it would duplicate or eat source.
fn show_case(label: string, source: string) {
    io.println("")
    io.println("-- {label}")
    for line: string in source.lines() {
        io.println("| {line} |")
    }
    let parsed: TagParse = parse_tag(source, 0)
    match parsed.root {
        some(el) => { io.print(el.show(0)) }
        none => { io.println("(no tree)") }
    }
    for d: Diag in parsed.diags {
        io.println("! {d.show()}")
    }
    io.println("end={parsed.end} ok={parsed.is_ok()}")
}

/// What `split_ramp` answers for one name, on its own, so the rule reads
/// without a tree around it.
fn show_split(name: string) {
    let split: RampSplit = split_ramp(name)
    io.println("{name} -> family={split.family} step={split.step}")
}

/// Lex one `"..."` literal on its own and print its resolved value as byte
/// codes.
///
/// Byte codes rather than the characters themselves because the point of the
/// case is the escapes that resolve to control characters, and a golden file
/// holding a raw tab, carriage return or NUL is a false diff waiting for the
/// next editor to touch it.
fn show_escape_bytes(label: string, literal: string) {
    let lex: Lexer = Lexer.at(literal, 0)
    let t: Token = lex.next_token()
    var codes: List<string> = []
    var i: int = 0
    for i < t.value.len() {
        codes.push("{t.value.byte_at(i)}")
        i = i + 1
    }
    let sep: string = " "
    io.println("{label}")
    io.println("| {literal} |")
    io.println("raw={t.raw}")
    io.println("bytes=[{codes.join(sep)}]")
    for d: Diag in lex.diags {
        io.println("! {d.show()}")
    }
}

/// What the `Result` form of the entry point answers.
fn show_result(label: string, source: string) {
    match parse_one(source) {
        ok(el) => { io.println("{label}: ok <{el.tag}> {el.attrs.len()} attrs, {el.children.len()} children") }
        err(e) => { io.println("{label}: err [{e.kind}] {e.msg}") }
    }
}

/// Walk a whole source the way `bx/compile.b` will: copy the opaque Beans,
/// parse each tag, resume at the offset the parse answered.
///
/// Three claims live or die here, and none of them shows up in a single-tag
/// case. **`end` is exact** — a byte out and the driver would duplicate or
/// eat source, and the `text |` lines below would show it. **Line and column
/// are counted from the top of the file**, not from where the tag starts, so
/// a diagnostic lines up with what beansc says about the same file. And **the
/// parser never reads past the tag**: the Beans under these tags carries a
/// string that is never closed, which an eager one-token lookahead would
/// fetch, scan and report a fault in — code this package has no business
/// reading. Every tag answering `ok=true` is the proof it does not.
///
/// Finding the `<` that opens a tag is the *driver's* decision, not this
/// package's: only the driver knows which `<` in a Beans file opens a tag and
/// which is a less-than. The finder here is the crudest stand-in that works
/// on the sample — a `<` with a name byte after it — and it is here to
/// exercise the `end` contract, not to be that decision.
fn walk_file(source: string) {
    io.println("")
    for line: string in source.lines() {
        io.println("| {line} |")
    }
    io.println("")
    var at: int = 0
    for at < source.len() {
        let lt: int = source.find_byte(60, at)
        if lt < 0 {
            break
        }
        if !is_name_start_byte(byte_of(source, lt + 1)) {
            at = lt + 1
            continue
        }
        io.println("text | [{spelled(source, at, lt)}]")
        let parsed: TagParse = parse_tag(source, lt)
        match parsed.root {
            some(el) => { io.print(el.show(0)) }
            none => { io.println("(no tree)") }
        }
        for d: Diag in parsed.diags {
            io.println("! {d.show()}")
        }
        io.println("tag  | {lt}..{parsed.end} ok={parsed.is_ok()}")
        at = parsed.end
    }
    io.println("text | [{spelled(source, at, source.len())}]")
}

/// The bytes in `from..to` with newlines and tabs spelled out, so a golden
/// can pin a range without a line break making it unreadable.
fn spelled(source: string, from: int, to: int) -> string {
    if from >= to {
        return "(nothing)"
    }
    return source.slice(from, to).replace("\n", "\\n").replace("\t", "\\t")
}
