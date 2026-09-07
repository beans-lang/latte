// compile.b — a `.bx` file to a `.b` file.
//
// The driver. `lex.b` and `parse.b` turn one tag into a tree, `attrs.b` and
// `colors.b` say what each attribute becomes, `emit.b` turns the tree back
// into a chain; this file is what walks a whole file, decides which `<` is a
// tag and which is a less-than, and writes the result out with an import
// header on it.
//
// ## Everything outside a tag is opaque
//
// A `.bx` file is a Beans file with tag expressions in it. bx does not read
// the Beans — beansc does, and it will say something better about it than bx
// could. So the walk copies bytes through untouched until it finds a tag,
// replaces the tag with `emit_indented`'s chain, and resumes at the exact
// `end` the parse answered. `bx/parse_demo.b`'s `walk_file` case pins that
// contract; an off-by-one in `end` would duplicate or eat source.
//
// `parse_tag_at` and not `parse_tag`, because the walk already knows the line
// and column of the `<` it is standing on. `parse_tag` rescans the file from
// byte zero to work them out, so a file with `n` tags would cost `O(n²)`.
//
// ## Which `<` opens a tag
//
// This is the driver's decision and nobody else's — `bx/parse.b` says so in
// as many words, because only the driver sees the Beans around the tag. Two
// rules, and between them they cover every shape that actually occurs:
//
//   1. **The byte after `<` starts a name.** That is a letter or `_`, never a
//      digit and never a space, so `n < 10` and `a < b` are comparisons.
//   2. **The byte before `<` does not end one.** A letter, a digit, `_`, `]`
//      or `)` in front means the `<` belongs to what came before it:
//      `List<string>`, `Option<int>`, `OrderedMap<string, ElementState>`,
//      `xs[i]<limit`, `f()<limit`. A generic argument list is the common case
//      and it is the one that would have hurt — every Beans file has several.
//
// What is left over: `a <b`, a comparison written with a space on one side
// only. It reads as a tag and then fails to parse as one, with a position, on
// the line it is on. That is the honest trade — the alternative is parsing
// Beans, which is the one thing this package must not do.
//
// ## Strings and comments are skipped
//
// `io.println("a <div> in a message")` must not compile a tag, and neither
// must a commented-out one. So the walk carries four states — code, string,
// line comment, block comment (nesting, as spec/SYNTAX.md says) — and only
// looks for a `<` in the first. That is lexing, but it is lexing two
// constructs whose whole job is to hold arbitrary text, not parsing Beans.
//
// A string ends at a `"` **or at a newline**, because beansc ends it there
// too ("string not closed before end of line"). An unbalanced quote therefore
// costs one line rather than swallowing the rest of the file. The one shape
// this simplification gets wrong is a string holding a nested string inside
// an interpolation — `"a {pad("x", 3)} b"` — where the middle is scanned as
// code; it re-synchronises at the end of the literal, and the only way to be
// bitten is to write a tag inside an interpolation, which does not work
// anyway.
//
// ## The import header
//
// `emit.b` reports the import paths its chain names, per tag. The driver
// collects them, drops the ones the file already has, and writes the rest in
// after the package clause and after any imports already there. It is a
// superset by design — `attr_imports()` names `crema.style` and `crema.color`
// together — and an unused import compiles.
//
// ## std.fs lives here, and that is a choice
//
// RULES.md: `import std.fs` anywhere in a package refuses the whole wasm
// build for any program that imports that package. `crema.bx` is a build-time
// tool — it turns source into source and is never linked into the UI it
// compiles — so nothing that reaches the browser imports it. If that ever
// stops being true, `compile_source` is the whole compiler and takes and
// answers a `string`; only `compile_file` and `compile_path` touch a disk.

package bx

import std.fs
import std.path

// ------------------------------------------------------------- the result

/// What one compile produced: the Beans source, the imports it added, how
/// many tags it translated, and everything found wrong.
///
/// The same three questions `TagParse` and `Emission` answer, in the same
/// shape, so a caller holds one thing all the way down the pipeline.
pub class Compiled {
    /// The `.b` source. Meaningful only when `is_ok()`: a walk that faulted
    /// keeps going so it can report the rest of the file, and a tag that did
    /// not parse is copied through as it was written rather than guessed at.
    pub text: string = ""
    /// The import paths bx added, in the order it added them. A path the file
    /// already had is not repeated and does not appear here.
    pub added: List<string> = []
    /// How many tags were found and translated.
    pub tags: int = 0
    /// Everything found wrong, in source order.
    pub diags: List<Diag> = []

    /// An empty result. The walk fills it.
    pub fn init() {}

    /// Whether nothing was found wrong.
    pub fn is_ok() -> bool {
        return self.diags.is_empty()
    }

    /// Every diagnostic, one per line, in the form beansc uses.
    pub fn report() -> string {
        let lines: List<string> = []
        for d: Diag in self.diags {
            lines.push(d.show())
        }
        let nl: string = "\n"
        return lines.join(nl)
    }
}

// -------------------------------------------------------------- the walk

/// Translate one `.bx` source into `.b` source.
///
/// The whole compiler. `compile_file` is this plus two calls to `std.fs`.
pub fn compile_source(source: string) -> Compiled {
    let out: Compiled = new Compiled()
    var parts: List<string> = []
    var needed: List<string> = []
    var copied: int = 0
    var i: int = 0
    var line: int = 1
    var col: int = 1
    var mode: int = in_code()
    var nesting: int = 0

    for i < source.len() {
        let b: int = source.byte_at(i) as int

        if mode == in_code() {
            if b == 34 {
                mode = in_string()
            } else if b == 47 && byte_of(source, i + 1) == 47 {
                mode = in_line_comment()
            } else if b == 47 && byte_of(source, i + 1) == 42 {
                mode = in_block_comment()
                nesting = 1
                i = i + 1
                col = col + 1
            } else if b == 60 && opens_tag(source, i) {
                parts.push(source.slice(copied, i))
                let parsed: TagParse = parse_tag_at(source, i, line, col)
                take_diags(out, parsed.diags)
                out.tags = out.tags + 1
                // A parse that ended where it started would leave `i` where
                // it was and spin forever, and `slice(i, end)` with an `end`
                // behind `i` would panic outright. `Parser.init` seeds
                // `last_end` with the offset it was handed, so neither can
                // happen today; the walk still refuses to depend on it,
                // because the cost of being wrong is a hang rather than a
                // diagnostic. It steps over the `<` and carries on.
                if parsed.end <= i {
                    copied = i
                    col = col + 1
                    i = i + 1
                    continue
                }
                match parsed.root {
                    some(node) => {
                        let produced: Emission = emit_tag(node, indent_depth(source, i))
                        take_diags(out, produced.diags)
                        for path: string in produced.imports {
                            note(needed, path)
                        }
                        parts.push(produced.text)
                    }
                    none => {
                        // Nothing to emit, so the markup stays as it was
                        // written: the output is then something a reader can
                        // look at next to the diagnostic, instead of a hole.
                        parts.push(source.slice(i, parsed.end))
                    }
                }
                // Step over the tag a byte at a time, only to keep the line
                // and column right for the next `parse_tag_at`. The tag's own
                // bytes are markup, so the Beans scanner starts again in code.
                for i < parsed.end {
                    if source.byte_at(i) as int == 10 {
                        line = line + 1
                        col = 1
                    } else {
                        col = col + 1
                    }
                    i = i + 1
                }
                copied = parsed.end
                continue
            }
        } else if mode == in_string() {
            if b == 92 {
                // The escape covers the next byte, whatever it is.
                i = i + 1
                col = col + 1
            } else if b == 34 {
                mode = in_code()
            } else if b == 10 {
                mode = in_code()
            }
        } else if mode == in_line_comment() {
            if b == 10 {
                mode = in_code()
            }
        } else {
            if b == 47 && byte_of(source, i + 1) == 42 {
                nesting = nesting + 1
                i = i + 1
                col = col + 1
            } else if b == 42 && byte_of(source, i + 1) == 47 {
                nesting = nesting - 1
                i = i + 1
                col = col + 1
                if nesting <= 0 {
                    mode = in_code()
                }
            }
        }

        // `byte_of` and not `byte_at`: a `\\` or a `/*` at the very last byte
        // of the file has already stepped `i` past the end, and `byte_at`
        // panics out of range where `byte_of` answers -1.
        if byte_of(source, i) == 10 {
            line = line + 1
            col = 1
        } else {
            col = col + 1
        }
        i = i + 1
    }

    parts.push(source.slice(copied, source.len()))
    let chained: string = parts.join("")
    out.text = with_imports(chained, needed, out)
    return out
}

/// The same, as the `Result` a caller who only wants the source wants.
///
/// Every diagnostic goes into the message, one per line, the way `parse_one`
/// and `emit` flatten theirs: a `Result` carries one `Error` and losing the
/// other nine would undo the reason the walk accumulates them.
pub fn compile_text(source: string) -> Result<string> {
    let done: Compiled = compile_source(source)
    if !done.is_ok() {
        return err(done.report(), "bx_compile")
    }
    return ok(done.text)
}

// ------------------------------------------------------------------ files

/// Read `from`, translate it, write `to`. Answers how many tags it found.
///
/// Nothing is written when anything went wrong: a `.b` file that is half
/// translated is worse than no file, because the next build reports beansc's
/// opinion of generated source instead of bx's opinion of the markup.
pub fn compile_file(from: string, to: string) -> Result<int> {
    let source: string = fs.read(from)?
    let done: Compiled = compile_source(source)
    if !done.is_ok() {
        return err("{from}\n{done.report()}", "bx_compile")
    }
    let written: int = fs.write(to, done.text)?
    return ok(done.tags)
}

/// The same, choosing the output name: `view.bx` becomes `view.b`.
pub fn compile_path(from: string) -> Result<int> {
    return compile_file(from, output_path(from))
}

/// Where `compile_path` writes: the same path with `.bx` turned into `.b`.
///
/// A name that does not end in `.bx` gets `.b` added rather than replacing
/// whatever extension it has, so `notes.txt` becomes `notes.txt.b` and never
/// overwrites something that was not markup.
pub fn output_path(from: string) -> string {
    if from.ends_with(".bx") {
        return "{from.slice(0, from.len() - 3)}.b"
    }
    return "{from}.b"
}

// ------------------------------------------------------- the import header

/// `text` with `paths` written in as `import` lines.
///
/// After the package clause and after any imports already there, so the
/// header of a generated file reads the way a hand-written one does. A path
/// the file already imports is skipped; if none is left, nothing moves.
fn with_imports(text: string, paths: List<string>, out: Compiled) -> string {
    let lines: List<string> = text.lines()
    var package_at: int = -1
    for i: int in 0..lines.len() {
        if lines[i].trim().starts_with("package ") {
            package_at = i
            break
        }
    }
    if package_at < 0 {
        out.diags.push(Diag.of(Span.at(1, 1),
            "a .bx file needs a package clause — bx writes the import header after it"))
        return text
    }

    // Walk the header: imports, blank lines and comments belong to it, and
    // the first real declaration ends it.
    var after: int = package_at
    var j: int = package_at + 1
    for j < lines.len() {
        let trimmed: string = lines[j].trim()
        if trimmed.starts_with("import ") {
            after = j
        } else if trimmed.len() > 0 && !trimmed.starts_with("//") {
            break
        }
        j = j + 1
    }

    var added: List<string> = []
    for path: string in paths {
        if !already_imports(lines, path) {
            added.push(path)
        }
    }
    for path: string in added {
        out.added.push(path)
    }
    if added.len() == 0 {
        return text
    }

    var written: List<string> = []
    for i: int in 0..lines.len() {
        written.push(lines[i])
        if i == after {
            if after == package_at {
                written.push("")
            }
            for path: string in added {
                written.push("import {path}")
            }
        }
    }
    let nl: string = "\n"
    let joined: string = written.join(nl)
    if text.ends_with("\n") {
        return "{joined}\n"
    }
    return joined
}

/// Whether one of `lines` is already `import <path>`.
fn already_imports(lines: List<string>, path: string) -> bool {
    let wanted: string = "import {path}"
    for line: string in lines {
        if line.trim() == wanted {
            return true
        }
    }
    return false
}

/// Add `path` to `seen` unless it is already there.
fn note(seen: List<string>, path: string) {
    for held: string in seen {
        if held == path {
            return
        }
    }
    seen.push(path)
}

/// Copy `found` onto the end of `out.diags`.
fn take_diags(out: Compiled, found: List<Diag>) {
    for d: Diag in found {
        out.diags.push(d)
    }
}

// -------------------------------------------------------------- the rules

/// Whether the `<` at `at` opens a tag. See the file header.
fn opens_tag(source: string, at: int) -> bool {
    if !is_name_start_byte(byte_of(source, at + 1)) {
        return false
    }
    return !ends_a_term(byte_of(source, at - 1))
}

/// Whether a byte can end the thing a `<` would then belong to: an
/// identifier, a number, a subscript or a call.
///
/// Deliberately *not* `is_name_byte`, which is the markup rule and counts
/// `-`, `.` and `:`. This is the Beans rule, and it is what keeps
/// `List<string>` from reading as a tag.
fn ends_a_term(v: int) -> bool {
    if v >= 48 && v <= 57 { return true }
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    if v == 95 { return true }
    if v == 93 { return true }
    return v == 41
}

/// How deep to indent the chain: the indentation of the *line* the tag opens
/// on, in levels of four spaces.
///
/// The line and not the column of the `<`. `emit_indented` never indents the
/// constructor — the caller has already put the cursor there, which is
/// exactly true here — and puts the calls one level deeper, so a tag on a
/// line indented once gets its calls indented twice:
///
///     return element.div()
///         .flex()
///
/// which is what a hand-written chain looks like. Taking the column instead
/// would indent the calls under `return <` rather than under `return`, and
/// every tag after a long `let name: element.Div = ` would march off the
/// right of the screen.
fn indent_depth(source: string, at: int) -> int {
    var start: int = at
    for start > 0 {
        if byte_of(source, start - 1) == 10 {
            break
        }
        start = start - 1
    }
    var width: int = 0
    var i: int = start
    for i < at {
        let b: int = byte_of(source, i)
        if b == 32 {
            width = width + 1
        } else if b == 9 {
            width = width + 4
        } else {
            break
        }
        i = i + 1
    }
    return width / 4
}

// The four states the walk can be in. Named functions rather than an enum
// because they are local to this file and an `enum(u8)` compared with `==`
// would read no better at four call sites each.

/// Beans, where a `<` may open a tag.
fn in_code() -> int { return 0 }

/// Inside a `"..."`, where it may not.
fn in_string() -> int { return 1 }

/// Inside a `//` comment.
fn in_line_comment() -> int { return 2 }

/// Inside a `/* */` comment, which nests.
fn in_block_comment() -> int { return 3 }
