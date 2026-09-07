// compile.b — one `.bx` file into one `.b` file.
//
// The generated file is **whole**: the `<beans>` block's Beans and the
// generated `render` live in it together, so a `.bx` file has exactly one
// output and the drift gate has exactly one thing to regenerate and diff.
//
//     // Generated from pages/counter.bx by latte-bx. Do not edit.
//     package pages
//     import {Builder, …} from latte
//     <the <beans> block, verbatim>
//     fn _latte_component_counter_Hint(value: Hint) -> Component { return value }
//     partial class Counter {
//         pub override fn render(b: Builder) { … }
//     }
//
// Three decisions in there are worth the sentence each.
//
// **The `<beans>` block is copied byte for byte, and its own `package` line is
// blanked into a comment of the same length.** Not deleted: deleting it would
// shift every line after it and the beansc diagnostics the author actually
// reads — theirs, about their code — would point one line too high.
//
// **The header is read with a token walk, never with a substring search.**
// `partial class` inside a string or a comment is not a declaration, and a
// compiler that finds one there generates a file that names a class nobody
// wrote. `scan_words` skips strings, raw strings and comments through the same
// `skip_beans_noise` the header scanner uses.
//
// **A component tag is proved to be a `Component` by beansc, here, at check
// time.** latte-bx cannot type-check, so it emits one free function per
// distinct component tag:
//
//     fn _latte_component_counter_Hint(value: Hint) -> Component { return value }
//
// An unused free function costs nothing and is not an error. If `Hint` is not a
// `Component` the answer is `error: expected latte.Component, got pages.Hint`
// — a type error naming the type, instead of a blank subtree and a runtime
// fault in a page that looked fine.

package bx

import std.fs

/// The names the generated file imports from the latte module root.
///
/// `Builder`, `Component` and `InputEvent` are spelled by generated code;
/// `Callback`, `Reference` and the other four event classes are spelled by the
/// author, in a handler closure or a component parameter. All nine are here
/// because an unused import is not an error and a missing one is.
pub fn latte_imports() -> List<string> {
    return ["Builder", "Callback", "Component", "FocusEvent", "InputEvent",
            "KeyboardEvent", "MouseEvent", "Reference", "SubmitEvent"]
}

/// How to compile one file.
pub class Options {
    /// Where `Builder` and friends come from. `latte` everywhere but in the
    /// probes, which carry their own stub core.
    pub latte_module: string = "latte"
    /// The package the generated file declares. Empty means: take the one the
    /// `<beans>` block declares, and failing that the containing folder's name.
    pub package_name: string = ""
    pub fn init() {}
}

/// One compiled `.bx` file.
pub class Compiled {
    /// The generated Beans, or `""` when something was refused.
    pub source: string = ""
    /// The class the file defines, for a caller that wants to say so.
    pub class_name: string = ""
    pub diags: List<Diag> = []

    pub fn init() {}

    pub fn is_ok() -> bool { return self.diags.len() == 0 }

    /// Every diagnostic as `file:line:col: error: …`, one per line.
    pub fn report(file: string) -> string {
        let lines: List<string> = []
        for d: Diag in self.diags {
            lines.push("{file}:{d.show()}")
        }
        return lines.join("\n")
    }
}

// ------------------------------------------------------------ the header scan

/// One word of Beans source: an identifier run, or one byte of punctuation.
///
/// Strings, raw strings and comments produce no words at all, which is the
/// whole point — `// partial class Ghost` is a comment, not a declaration.
pub class Word {
    pub text: string = ""
    pub start: int = 0
    pub stop: int = 0
    /// Brace depth at the word. A declaration is at depth 0; anything inside a
    /// class or a function body is not.
    pub depth: int = 0

    pub fn init(text: string, start: int, stop: int, depth: int) {
        self.text = text
        self.start = start
        self.stop = stop
        self.depth = depth
    }
}

/// Split Beans source into words, skipping everything that is not code.
pub fn scan_words(code: string) -> List<Word> {
    let out: List<Word> = []
    var depth: int = 0
    var i: int = 0
    for i < code.len() {
        let past: int = skip_beans_noise(code, i)
        if past > i {
            i = past
            continue
        }
        let b: int = code.byte_at(i) as int
        if is_space_byte(b) {
            i = i + 1
            continue
        }
        if is_ident_start_byte(b) {
            let start: int = i
            for is_ident_byte(byte_of(code, i)) {
                i = i + 1
            }
            out.push(new Word(code.slice(start, i), start, i, depth))
            continue
        }
        if b == 123 { depth = depth + 1 }
        if b == 125 { depth = depth - 1 }
        out.push(new Word(code.slice(i, i + 1), i, i + 1, depth))
        i = i + 1
    }
    return move out
}

/// What the `<beans>` block declares.
pub class Header {
    /// The package the block declares, or `""`.
    pub package_name: string = ""
    /// The byte range of the `package <name>` statement, for blanking.
    pub package_start: int = -1
    pub package_stop: int = -1
    /// Every `partial class` at the top level, in source order.
    pub partial_classes: List<string> = []
    /// The type parameters of the class the file is named for.
    pub type_params: List<string> = []
    /// Where that class was declared, for a diagnostic.
    pub class_at: int = -1
    /// Every `import` at the top level, as `(bound name, module path, offset)`.
    pub import_names: List<string> = []
    pub import_paths: List<string> = []
    pub import_offsets: List<int> = []

    pub fn init() {}
}

/// Read the `<beans>` block's own declarations.
///
/// `wanted` is the class the file's name calls for; its type parameters are
/// collected only for that one, because a `<beans>` block may hold helper
/// classes and their parameters are none of the emitter's business.
pub fn scan_beans_header(code: string, wanted: string) -> Header {
    let out: Header = new Header()
    let words: List<Word> = scan_words(code)
    var i: int = 0
    for i < words.len() {
        let word: Word = words[i]
        if word.depth != 0 {
            i = i + 1
            continue
        }
        // `package <name>`, once, and not `self.package`.
        if word.text == "package" && out.package_start < 0 {
            if i > 0 && words[i - 1].text == "." {
                i = i + 1
                continue
            }
            if i + 1 < words.len() {
                out.package_name = words[i + 1].text
                out.package_start = word.start
                out.package_stop = words[i + 1].stop
            }
            i = i + 2
            continue
        }
        if word.text == "import" {
            if i > 0 && words[i - 1].text == "." {
                i = i + 1
                continue
            }
            i = read_import(words, i, out)
            continue
        }
        if word.text == "class" && i > 0 && words[i - 1].text == "partial" {
            if i + 1 >= words.len() {
                i = i + 1
                continue
            }
            let name: string = words[i + 1].text
            out.partial_classes.push(name)
            var cursor: int = i + 2
            if name == wanted {
                out.class_at = words[i + 1].start
                if cursor < words.len() && words[cursor].text == "<" {
                    var angle: int = 0
                    for cursor < words.len() {
                        let step: Word = words[cursor]
                        if step.text == "<" { angle = angle + 1 }
                        else if step.text == ">" {
                            angle = angle - 1
                            if angle == 0 {
                                cursor = cursor + 1
                                break
                            }
                        }
                        else if angle > 0 && is_beans_identifier(step.text) {
                            out.type_params.push(step.text)
                        }
                        cursor = cursor + 1
                    }
                }
            }
            i = cursor
            continue
        }
        i = i + 1
    }
    return out
}

/// One `import` statement, from the word after `import`. Answers the index to
/// carry on from.
fn read_import(words: List<Word>, at: int, out: Header) -> int {
    var i: int = at + 1
    if i >= words.len() { return i }
    let offset: int = words[at].start
    if words[i].text == "\{" {
        // `import {a, b as c} from path`
        let bound: List<string> = []
        var last: string = ""
        var expecting_alias: bool = false
        i = i + 1
        for i < words.len() {
            let word: Word = words[i]
            if word.text == "\}" {
                if last != "" { bound.push(last) }
                i = i + 1
                break
            }
            if word.text == "," {
                if last != "" { bound.push(last) }
                last = ""
                expecting_alias = false
                i = i + 1
                continue
            }
            if word.text == "as" {
                expecting_alias = true
                i = i + 1
                continue
            }
            if is_beans_identifier(word.text) {
                if expecting_alias || last == "" { last = word.text }
                expecting_alias = false
            }
            i = i + 1
        }
        var path: string = ""
        if i < words.len() && words[i].text == "from" {
            i = i + 1
            path = read_path(words, i)
            i = skip_path(words, i)
        }
        for name: string in bound {
            out.import_names.push(name)
            out.import_paths.push(path)
            out.import_offsets.push(offset)
        }
        return i
    }
    // `import a.b.c` — the last segment is the bound name.
    let path: string = read_path(words, i)
    let stop: int = skip_path(words, i)
    let parts: List<string> = path.split(".")
    out.import_names.push(parts[parts.len() - 1])
    out.import_paths.push(path)
    out.import_offsets.push(offset)
    return stop
}

/// The dotted path starting at `at`.
fn read_path(words: List<Word>, at: int) -> string {
    let parts: List<string> = []
    var i: int = at
    for i < words.len() {
        if !is_beans_identifier(words[i].text) { break }
        parts.push(words[i].text)
        i = i + 1
        if i >= words.len() || words[i].text != "." { break }
        i = i + 1
    }
    return parts.join(".")
}

fn skip_path(words: List<Word>, at: int) -> int {
    var i: int = at
    for i < words.len() {
        if !is_beans_identifier(words[i].text) { break }
        i = i + 1
        if i >= words.len() || words[i].text != "." { break }
        i = i + 1
    }
    return i
}

// ---------------------------------------------------------------- file names

/// `counter.bx` → `Counter`, `user_card.bx` → `UserCard`.
///
/// A component's class name comes from its file name, the way a Blazor
/// component's does, so there is one place a page is called something.
pub fn class_name_for(stem: string) -> string {
    let parts: List<string> = []
    var word: List<string> = []
    var i: int = 0
    for i < stem.len() {
        let b: int = stem.byte_at(i) as int
        if b == 95 || b == 45 {
            if !word.is_empty() { parts.push(word.join("")) }
            word = []
            i = i + 1
            continue
        }
        word.push(stem.slice(i, i + 1))
        i = i + 1
    }
    if !word.is_empty() { parts.push(word.join("")) }
    let out: List<string> = []
    for part: string in parts {
        if part.len() == 0 { continue }
        out.push(part.slice(0, 1).to_upper())
        out.push(part.slice(1, part.len()))
    }
    return out.join("")
}

/// The stem of a path: `pages/counter.bx` → `counter`.
pub fn stem_of(path: string) -> string {
    var start: int = 0
    var i: int = 0
    for i < path.len() {
        let b: int = path.byte_at(i) as int
        if b == 47 || b == 92 { start = i + 1 }
        i = i + 1
    }
    let name: string = path.slice(start, path.len())
    if name.ends_with(".bx") { return name.slice(0, name.len() - 3) }
    return name
}

/// The last directory of a path: `pages/counter.bx` → `pages`, and `""` when
/// the file has no directory at all.
pub fn folder_of(path: string) -> string {
    var cut: int = -1
    var i: int = 0
    for i < path.len() {
        let b: int = path.byte_at(i) as int
        if b == 47 || b == 92 { cut = i }
        i = i + 1
    }
    if cut < 0 { return "" }
    let directory: string = path.slice(0, cut)
    var start: int = 0
    i = 0
    for i < directory.len() {
        let b: int = directory.byte_at(i) as int
        if b == 47 || b == 92 { start = i + 1 }
        i = i + 1
    }
    return directory.slice(start, directory.len())
}

/// The file name of a path: `pages/counter.bx` → `counter.bx`.
pub fn file_name_of(path: string) -> string {
    var start: int = 0
    var i: int = 0
    for i < path.len() {
        let b: int = path.byte_at(i) as int
        if b == 47 || b == 92 { start = i + 1 }
        i = i + 1
    }
    return path.slice(start, path.len())
}

/// The generated file's path: `pages/counter.bx` → `pages/counter_gen.b`.
///
/// `_gen` rather than plain `.b` so a directory listing says which files are
/// machine-written, and so a hand-written `counter.b` beside it is possible
/// without a collision.
pub fn generated_path_for(path: string) -> string {
    var cut: int = -1
    var i: int = 0
    for i < path.len() {
        let b: int = path.byte_at(i) as int
        if b == 47 || b == 92 { cut = i }
        i = i + 1
    }
    let stem: string = stem_of(path)
    if cut < 0 { return "{stem}_gen.b" }
    return "{path.slice(0, cut + 1)}{stem}_gen.b"
}

/// A component tag as a function-name fragment: `ui.Button` → `ui_Button`.
pub fn mangle_tag(tag: string) -> string {
    let parts: List<string> = []
    var i: int = 0
    for i < tag.len() {
        let b: int = tag.byte_at(i) as int
        if is_ident_byte(b) { parts.push(tag.slice(i, i + 1)) }
        else { parts.push("_") }
        i = i + 1
    }
    return parts.join("")
}

// ------------------------------------------------------------- the assembly

/// Compile one `.bx` source into one `.b` source.
///
/// `path` is the file as the author names it — it goes into the line map and
/// into every diagnostic, so it should be the path they typed.
pub fn compile_source(source: string, path: string, options: Options) -> Compiled {
    let out: Compiled = new Compiled()
    let file: string = file_name_of(path)
    let stem: string = stem_of(path)
    let wanted: string = class_name_for(stem)
    out.class_name = wanted

    let doc: Document = parse_document(source)
    for d: Diag in doc.diags { out.diags.push(d) }

    var block: string = ""
    var block_start: int = 0
    var has_block: bool = false
    match doc.beans {
        some(beans) => {
            block = beans.code
            block_start = beans.start
            has_block = true
        }
        none => {
            out.diags.push(Diag.of(Span.at(1, 1),
                "{file} has no <beans> block — a component file holds one, declaring the partial class the markup renders into. Add <beans>pub partial class {wanted} extends Component \{ pub fn init() \{\} \}</beans>"))
        }
    }
    if !has_block { return out }

    let header: Header = scan_beans_header(block, wanted)
    // Positions inside the block, reported against the whole file.
    let locate: Lexer = new Lexer(source)

    var declared: bool = false
    for name: string in header.partial_classes {
        if name == wanted { declared = true }
    }
    if !declared {
        var found: string = "nothing"
        if !header.partial_classes.is_empty() {
            found = header.partial_classes.join(", ")
        }
        locate.seek(block_start)
        out.diags.push(Diag.of(locate.span(),
            "{file} has to declare `partial class {wanted}` — the class is named after the file, and latte-bx writes the other half of it. The block declares {found}"))
    }

    // An import of the latte module root that binds a name the generated line
    // already binds is a duplicate in a file the author never wrote.
    var index: int = 0
    for index < header.import_names.len() {
        if header.import_paths[index] == options.latte_module {
            let bound: string = header.import_names[index]
            for fixed: string in latte_imports() {
                if fixed != bound { continue }
                locate.seek(block_start + header.import_offsets[index])
                out.diags.push(Diag.of(locate.span(),
                    "the <beans> block imports {bound} from {options.latte_module}, and the generated file already does — latte-bx writes `import \{{latte_imports().join(", ")}\} from {options.latte_module}` at the top of every file it makes, and two imports of one name is an error in a file you did not write. Remove this one"))
            }
        }
        index = index + 1
    }

    let emitter: Emitter = new Emitter(file)
    let emitted: Emitted = emitter.emit(doc, header.type_params)
    for d: Diag in emitted.diags { out.diags.push(d) }

    if !out.is_ok() { return out }

    var package_name: string = options.package_name
    if package_name == "" { package_name = header.package_name }
    if package_name == "" { package_name = folder_of(path) }
    if package_name == "" {
        out.diags.push(Diag.of(Span.at(1, 1),
            "{file} sits in no directory, so latte-bx cannot tell what package it belongs to — declare one in the <beans> block, as `package pages`"))
        return out
    }

    let body: List<string> = []
    body.push("// Generated from {path} by latte-bx. Do not edit.")
    body.push("//")
    body.push("// The <beans> block below is {file}'s, copied through byte for byte; its")
    body.push("// own package line is blanked so every line after it keeps its number. The")
    body.push("// render method under it is the markup, as Builder calls with fixed")
    body.push("// sequence numbers. Change {file} and regenerate:")
    body.push("//")
    body.push("//     latte-bx build {path}")
    body.push("package {package_name}")
    body.push("")
    body.push("import \{{latte_imports().join(", ")}\} from {options.latte_module}")
    body.push("")
    body.push(blank_package_statement(block, header))
    if !emitted.components.is_empty() {
        body.push("")
        body.push("// Every component tag in {file}, checked by beansc rather than by latte-bx:")
        body.push("// a tag whose type is not a Component is a type error naming the type,")
        body.push("// instead of a blank subtree and a fault at run time. Unused, and an")
        body.push("// unused free function is not an error.")
        for tag: string in emitted.components {
            body.push("fn _latte_component_{stem}_{mangle_tag(tag)}(value: {tag}) -> Component \{ return value \}")
        }
    }
    body.push("")
    body.push("partial class {wanted} \{")
    body.push("    pub override fn render(b: Builder) \{")
    for line: string in emitted.lines { body.push(line) }
    body.push("    \}")
    body.push("\}")
    out.source = "{body.join("\n")}\n"
    return out
}

/// The `<beans>` block with its `package` statement replaced by a comment of
/// exactly the same length.
///
/// Same length, not removed, so every line number after it survives. The author
/// reads beansc's diagnostics about *their* code in this file, and a line that
/// has moved is a line they cannot find.
fn blank_package_statement(block: string, header: Header) -> string {
    if header.package_start < 0 { return block.trim_end() }
    let width: int = header.package_stop - header.package_start
    var filler: string = "//"
    if width > 2 { filler = "//{" ".repeat(width - 2)}" }
    return "{block.slice(0, header.package_start)}{filler}{block.slice(header.package_stop, block.len())}".trim_end()
}

/// Compile the `.bx` file at `path`.
pub fn compile_file(path: string, options: Options) -> Compiled {
    match fs.read(path) {
        ok(source) => { return compile_source(source, path, options) }
        err(problem) => {
            let out: Compiled = new Compiled()
            out.diags.push(Diag.of(Span.at(1, 1),
                "cannot read {path}: {problem.msg}"))
            return out
        }
    }
}
