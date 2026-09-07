// PLAN.md gate 4: the markup compiler.
//
// Five things, in this order, because each one is worthless without the one
// before it.
//
// **The contract.** `latte.bx` cannot import `latte` — "a package cannot
// import its own module root" — so the escaping rules, the element tables and
// the refusal predicates exist twice: once in `frames.b`, where the runtime
// serializer uses them, and once in `bx/html.b`, where the build-time folder
// does. If those two ever disagree, a folded subtree and an unfolded one say
// different things and nothing else in this repo would notice. So the first
// section runs both copies over a corpus and fails on the first disagreement.
//
// **The `$` rules.** Every row of the transition table, against a fixture,
// through the parse tree.
//
// **The emission.** Every fixture's generated `render`, in the golden. That is
// where sequence numbering, the two arms of the fold switch, the line map and
// the whole-tree refusals are visible.
//
// **The drift gate.** Every generated `.b` checked into this repo is
// regenerated here and diffed. A stale generated file fails the gate instead
// of shipping.
//
// **Gate 4's own words: "hand-written builder versus generated builder
// producing identical frames."** Two halves. The *frames* half is
// `tests/w2_equiv.b`, which renders a generated component and a hand-written
// twin and compares frame dumps on both backends. The *text* half is here:
// `probes/p8_builder/pages/counter_gen.b` was hand-written by W0 from
// PLAN.md's worked example, before any of this existed, and
// `probes/p8_builder/pages/counter.bx` is the markup it must come from. Every
// sequence number W0 wrote has to mean the same thing in latte-bx's output.
package main

import std.fs
import std.io
import latte
import latte.bx

// ---------------------------------------------------------------- reporting
//
// One class rather than free functions with a module-level counter: a
// module-level `var` has no spelling in Beans — only `const NAME` starts a
// module-level declaration — so the failure count is a field.

pub class Suite {
    pub failures: int = 0
    pub fn init() {}

    fn check(name: string, ok: bool) {
    if ok { return }
    self.failures = self.failures + 1
    io.println("FAIL {name}")
}

    fn same(name: string, got: string, want: string) {
    if got == want { return }
    self.failures = self.failures + 1
    io.println("FAIL {name}")
    io.println("  got  {got}")
    io.println("  want {want}")
}

// ------------------------------------------------- section 1: the contract

    fn tag_corpus() -> List<string> {
    return ["div", "span", "br", "input", "textarea", "title", "pre",
            "script", "style", "listing", "my-widget", "ui.button", "SVG",
            "a1", "1a", "", "-x", "x-", "a_b", "a:b", "a b", "img", "PRE",
            "TEXTAREA", "Script"]
}

    fn attribute_corpus() -> List<string> {
    return ["class", "id", "data-x", "xlink:href", "href", "src", "action",
            "formaction", "poster", "data", "on", "onclick", "onCLICK",
            "on-foo", "on_dismiss", "once", "only", "no", "1x", "", "a.b",
            ":x", "-x", "x y", "a\"b", "a>b", "_x", ".x", "disabled"]
}

    fn url_corpus() -> List<string> {
    return ["", "/path", "path", "http://a", "HTTPS://a", "mailto:a@b.c",
            "tel:+1", "javascript:alert(1)", "JaVaScRiPt:alert(1)",
            "java\tscript:alert(1)", "java\nscript:alert(1)",
            " javascript:alert(1)", "data:text/html,x", "about:blank",
            "?q=1:2", "#a:b", "//host/x", "a/b:c", "vbscript:x", ":x"]
}

    fn text_corpus() -> List<string> {
    return ["", "plain", "a<b>c", "a&b", "a&amp;b", "\"quoted\"", "it's",
            "<script>alert(1)</script>", "&<>\"'", "\n\ttabbed",
            "unicode — ok", "a>b"]
}

    fn raw_body_corpus() -> List<string> {
    return ["const a = 1;", "", "</script>", "</SCRIPT >", "a</script",
            "<!-- x", "a <!-- b", "</style>", "1 < 2", "x</styl"]
}

/// The build-time copies and the run-time originals, over a corpus.
///
/// Every row here is a rule that exists in two files. The gate is not that
/// they look alike; it is that they answer the same for every input tried.
    fn contract_agrees() {
    for tag: string in self.tag_corpus() {
        self.check("is_void_element({tag})",
              bx.is_void_element(tag) == latte.is_void_element(tag.to_lower()))
        self.check("is_raw_text_element({tag})",
              bx.is_raw_text_element(tag) == latte.is_raw_text_element(tag.to_lower()))
        self.check("is_rcdata_element({tag})",
              bx.is_rcdata_element(tag) == latte.is_rcdata_element(tag.to_lower()))
        self.check("eats_leading_newline({tag})",
              bx.eats_leading_newline(tag) == latte.eats_leading_newline(tag.to_lower()))
        self.check("tag_name_is_safe({tag})",
              bx.tag_name_is_safe(tag) == latte.tag_name_is_safe(tag))
    }
    for name: string in self.attribute_corpus() {
        self.check("attribute_name_is_safe({name})",
              bx.attribute_name_is_safe(name) == latte.attribute_name_is_safe(name))
        self.check("inline_handler({name})",
              bx.is_inline_handler_attribute(name) == latte.attribute_is_inline_handler(name))
        self.check("is_url_attribute({name})",
              bx.is_url_attribute(name) == latte.is_url_attribute(name))
    }
    for value: string in self.url_corpus() {
        self.check("scheme_is_allowed({value})",
              bx.scheme_is_allowed(value) == latte.scheme_is_allowed(value))
    }
    for value: string in self.text_corpus() {
        self.same("escape_text({value})", bx.escape_text(value), latte.escape_text(value))
        self.same("escape_attribute({value})", bx.escape_attribute(value), latte.escape_attribute(value))
    }
    for body: string in self.raw_body_corpus() {
        self.check("raw_text_is_safe({body}, script)",
              bx.raw_text_is_safe(body, "script") == latte.raw_text_is_safe(body, "script"))
        self.check("raw_text_is_safe({body}, style)",
              bx.raw_text_is_safe(body, "style") == latte.raw_text_is_safe(body, "style"))
    }
}

/// `event_names()` is written out by hand and `event_family()` is a chain of
/// comparisons, so one can grow without the other. A row in the list that the
/// family test does not know would put an event in a diagnostic that the
/// compiler then refuses.
    fn event_table_agrees() {
    for name: string in bx.event_names() {
        self.check("event_family({name}) is known", bx.event_family(name) != "")
        self.check("event_method({name})", bx.event_method(name) == "on_{name}")
    }
    self.check("an unknown event has no method", bx.event_method("wheel") == "")
    self.check("an unknown event has no family", bx.event_family("wheel") == "")
    self.check("a near miss suggests", bx.nearest_event("clcik") == "click")
    self.check("a far miss suggests nothing", bx.nearest_event("wheel") == "")
}

// -------------------------------------- section 1b: the editor vocabulary
//
// `bx/vocabulary.b` writes latte's `.bx` surface down as data, and
// `tests/w2_editor_data.b` prints it as the JSON an editor reads. Every list
// in it mirrors a predicate in `html.b`, and a predicate is a chain of `==`
// that cannot be enumerated — the same problem `event_names()` has.
//
// So the gate is **two-sided over a corpus**: for every name in the corpus,
// the predicate and the list must give the same answer. Adding a name to
// `html.b` and forgetting the list fails here, and so does the reverse. A
// one-sided check — "every listed name satisfies the predicate" — would pass
// forever while the editor quietly went blind to a new element.
//
// The corpora are wide on purpose. `is_void_element` growing a `dialog` is
// exactly the shape this has to catch, so `dialog` is in the corpus even
// though nothing in latte mentions it.

    fn element_corpus() -> List<string> {
    return ["a", "abbr", "address", "area", "article", "aside", "audio", "b",
            "base", "bdi", "bdo", "blockquote", "body", "br", "button",
            "canvas", "caption", "cite", "code", "col", "colgroup", "data",
            "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl",
            "dt", "em", "embed", "fieldset", "figcaption", "figure", "footer",
            "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
            "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins",
            "kbd", "label", "legend", "li", "link", "listing", "main", "map",
            "mark", "menu", "meta", "meter", "nav", "noscript", "object",
            "ol", "optgroup", "option", "output", "p", "picture", "pre",
            "progress", "q", "rp", "rt", "ruby", "s", "samp", "script",
            "search", "section", "select", "slot", "small", "source", "span",
            "strong", "style", "sub", "summary", "sup", "svg", "table",
            "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
            "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr"]
}

    fn attribute_name_corpus() -> List<string> {
    return ["accept", "accesskey", "action", "allowfullscreen", "alt", "async",
            "attrs", "autocomplete", "autofocus", "autoplay", "charset",
            "checked", "cite", "class", "cols", "colspan", "content",
            "contenteditable", "controls", "coords", "crossorigin", "data",
            "data-x", "datetime", "default", "defer", "dir", "disabled",
            "download", "draggable", "enctype", "for", "form", "formaction",
            "formnovalidate", "headers", "height", "hidden", "href",
            "hreflang", "id", "inert", "inputmode", "ismap", "itemscope",
            "key", "kind", "label", "lang", "list", "live", "loading", "loop",
            "max", "maxlength", "media", "method", "min", "minlength",
            "multiple", "muted", "name", "nomodule", "novalidate", "open",
            "pattern", "ping", "placeholder", "playsinline", "poster",
            "preload", "preserve", "readonly", "ref", "referrerpolicy", "rel",
            "required", "reversed", "rows", "rowspan", "sandbox", "scope",
            "selected", "shape", "size", "sizes", "span", "spellcheck", "src",
            "srcdoc", "srclang", "srcset", "start", "step", "style",
            "tabindex", "target", "title", "translate", "type", "usemap",
            "value", "width", "wrap", "xlink:href", "xml:lang"]
}

    fn scheme_corpus() -> List<string> {
    return ["http", "https", "mailto", "tel", "javascript", "data", "vbscript",
            "about", "file", "ftp", "blob", "ws", "wss", "sms", "chrome"]
}

    fn prefix_corpus() -> List<string> {
    return ["xlink", "xml", "xmlns", "on", "bind", "bnd", "svg", "aria", "x",
            "data", "html"]
}

/// The names in `bx/vocabulary.b`'s XML-namespace rows, without the colon.
    fn vocabulary_xml_prefixes() -> List<string> {
    let out: List<string> = []
    for row: bx.VocabRow in bx.namespaces() {
        if row.name == "on:" || row.name == "bind:" { continue }
        out.push(row.name.slice(0, row.name.len() - 1))
    }
    return move out
}

    fn vocabulary_reserved_names() -> List<string> {
    let out: List<string> = []
    for row: bx.VocabRow in bx.reserved_attributes() { out.push(row.name) }
    return move out
}

    fn vocabulary_agrees() {
    for tag: string in self.element_corpus() {
        self.check("voidElements lists {tag}",
              bx.is_void_element(tag) == bx.void_elements().contains(tag))
        self.check("rawTextElements lists {tag}",
              bx.is_raw_text_element(tag) == bx.raw_text_elements().contains(tag))
        self.check("rcdataElements lists {tag}",
              bx.is_rcdata_element(tag) == bx.rcdata_elements().contains(tag))
        self.check("newlineEatingElements lists {tag}",
              bx.eats_leading_newline(tag) == bx.newline_eating_elements().contains(tag))
    }
    for name: string in self.attribute_name_corpus() {
        self.check("booleanAttributes lists {name}",
              bx.is_boolean_attribute(name) == bx.boolean_attributes().contains(name))
        self.check("urlAttributes lists {name}",
              bx.is_url_attribute(name) == bx.url_attributes().contains(name))
        self.check("reservedAttributes lists {name}",
              bx.is_reserved_attribute(name) == self.vocabulary_reserved_names().contains(name))
    }
    for scheme: string in self.scheme_corpus() {
        self.check("allowedSchemes lists {scheme}",
              bx.scheme_is_allowed("{scheme}:x") == bx.allowed_schemes().contains(scheme))
    }
    for prefix: string in self.prefix_corpus() {
        self.check("namespaces lists {prefix}:",
              bx.is_xml_namespace(prefix) == self.vocabulary_xml_prefixes().contains(prefix))
    }
    // The events are read straight out of `event_names()` rather than written
    // down again, so the only thing to check is that every row has both halves
    // — a name with no family would print `"family": ""` into the JSON.
    for name: string in bx.event_names() {
        self.check("event {name} has a family", bx.event_family(name) != "")
        self.check("event {name} has a method", bx.event_method(name) != "")
    }
    self.check("no bind: conversion is missing", bx.conversions().len() == 3)
}

/// Each `$` block keyword parses as its block, and a word that is not one
/// parses as an implicit chain instead.
///
/// The dispatcher in `parse.b` is another chain of `==`, so this is the only
/// way to say the list in `vocabulary.b` is the list `parse.b` answers to. The
/// control is the half that matters: without it, a keyword deleted from the
/// dispatcher would still "parse" — as text — and every case would pass.
    fn block_keywords_parse() {
    self.same("$if parses as a block", self.first_node("$if self.on \{ <p>x</p> \}"), "if")
    self.same("$for parses as a block",
         self.first_node("$for row in self.rows \{ <p>x</p> \}"), "for")
    self.same("$match parses as a block",
         self.first_node("$match self.n \{ 0 => \{ <p>x</p> \} \}"), "match")
    self.same("$slot parses as a block", self.first_node("$slot"), "slot")
    self.same("$html parses as a block", self.first_node("$html(self.body)"), "html")
    self.same("an unknown $word is a chain, not a block",
         self.first_node("$notablock"), "implicit")
    self.same("$$ is text", self.first_node("$$notablock"), "text")
    // Every keyword the vocabulary names is one of the five above, spelled
    // with its `$`. `else` is the exception and carries none, because it
    // continues the `$if` rather than opening a block.
    for row: bx.VocabRow in bx.blocks() {
        if row.name == "else" { continue }
        self.check("{row.name} starts with a $", row.name.starts_with("$"))
        self.check("{row.name} is one parse.b dispatches on",
              ["$if", "$for", "$match", "$slot", "$html"].contains(row.name))
    }
}

/// The first word of the parse tree's first line — `if`, `for`, `text`, …
    fn first_node(markup: string) -> string {
    let doc: bx.Document = bx.parse_document(markup)
    let dump: string = doc.show()
    let lines: List<string> = dump.split("\n")
    if lines.is_empty() { return "" }
    let words: List<string> = lines[0].trim().split(" ")
    if words.is_empty() { return "" }
    return words[0]
}

/// The JSON escaper, on the four bytes JSON names and one it does not.
///
/// A note in `vocabulary.b` holds a quote and a backslash today, so a broken
/// escaper writes a file no editor can parse — and nothing else in this repo
/// parses JSON, so nothing else would notice.
    fn json_escaping() {
    self.same("a quote", bx.json_string("a\"b"), "\"a\\\"b\"")
    self.same("a backslash", bx.json_string("a\\b"), "\"a\\\\b\"")
    self.same("a newline", bx.json_string("a\nb"), "\"a\\nb\"")
    self.same("a tab", bx.json_string("a\tb"), "\"a\\tb\"")
    self.same("a bare control byte", bx.json_string("a\u{1}b"), "\"a\\u0001b\"")
    self.same("nothing to escape", bx.json_string("plain"), "\"plain\"")
}

// ------------------------------------------- section 2 and 3: the fixtures

    fn fixture(name: string) -> string {
    match fs.read("tests/w2cases/{name}.bx") {
        ok(source) => { return source }
        err(problem) => {
            self.failures = self.failures + 1
            io.println("FAIL cannot read tests/w2cases/{name}.bx: {problem.msg}")
            return ""
        }
    }
}

    fn show_tree(name: string) {
    io.println("======== parse tree: {name}.bx ========")
    let doc: bx.Document = bx.parse_document(self.fixture(name))
    io.print(doc.show())
    if !doc.is_ok() {
        io.println(doc.report())
        self.failures = self.failures + 1
    }
}

    fn compile_fixture(name: string) -> bx.Compiled {
    let options: bx.Options = new bx.Options()
    return bx.compile_source(self.fixture(name), "tests/w2cases/{name}.bx", options)
}

/// Just the `render` body — the part this lane writes. The header, the copied
/// `<beans>` block and the component assertions are shown once, for `simple`,
/// so the golden records the whole file shape without repeating it eight times.
    fn show_render(name: string) {
    io.println("======== render: {name}.bx ========")
    let compiled: bx.Compiled = self.compile_fixture(name)
    if !compiled.is_ok() {
        io.println(compiled.report("tests/w2cases/{name}.bx"))
        self.failures = self.failures + 1
        return
    }
    var inside: bool = false
    for line: string in compiled.source.split("\n") {
        if line.starts_with("partial class ") { inside = true }
        if inside { io.println(line) }
    }
}

    fn show_whole_file(name: string) {
    io.println("======== the whole generated file: {name}.bx ========")
    let compiled: bx.Compiled = self.compile_fixture(name)
    if !compiled.is_ok() {
        io.println(compiled.report("tests/w2cases/{name}.bx"))
        self.failures = self.failures + 1
        return
    }
    io.print(compiled.source)
}

// ------------------------------------------------ section 4: the drift gate

/// Regenerate a checked-in generated file and compare it with what is on disk.
///
/// A generated file is committed beside its source so a consumer never needs
/// the markup compiler. That is only safe while the two agree, and "the author
/// edited the `.bx` and forgot to regenerate" is the failure it hides. This is
/// the gate that catches it.
    fn drift(source: string, generated: string, latte_module: string) {
    let options: bx.Options = new bx.Options()
    options.latte_module = latte_module
    let compiled: bx.Compiled = bx.compile_file(source, options)
    if !compiled.is_ok() {
        io.println("FAIL {source} does not compile:")
        io.println(compiled.report(source))
        self.failures = self.failures + 1
        return
    }
    match fs.read(generated) {
        ok(on_disk) => {
            if on_disk == compiled.source {
                io.println("ok {generated} is what {source} generates")
                return
            }
            self.failures = self.failures + 1
            io.println("FAIL {generated} is stale — regenerate it:")
            io.println("    latte-bx build {source}")
            let want: List<string> = compiled.source.split("\n")
            let got: List<string> = on_disk.split("\n")
            var index: int = 0
            var shown: int = 0
            for index < want.len() || index < got.len() {
                var left: string = ""
                var right: string = ""
                if index < got.len() { left = got[index] }
                if index < want.len() { right = want[index] }
                if left != right && shown < 12 {
                    io.println("  {index + 1} on disk: {left}")
                    io.println("  {index + 1} fresh:   {right}")
                    shown = shown + 1
                }
                index = index + 1
            }
        }
        err(problem) => {
            self.failures = self.failures + 1
            io.println("FAIL cannot read {generated}: {problem.msg}")
        }
    }
}

// --------------------------------------- section 5: gate 4, the text half

/// Every `b.<method>(<seq>, …)` in a file, as `seq -> description`.
///
/// A sequence number is a source position, so the strongest thing two files
/// can agree on is what each number *means*. A file that emits both arms of
/// the fold switch gives two answers for the numbers inside a folded run —
/// `constant` in one arm, `open`/`attr`/`text` in the other — and both are
/// listed, because both are what that number means in the render that arm
/// belongs to.
    fn seq_meanings(source: string, out: Map<int, List<string>>) {
    for line: string in source.split("\n") {
        self.record_calls(line, out)
    }
}

    fn record_calls(line: string, out: Map<int, List<string>>) {
    var i: int = 0
    for i < line.len() {
        let past: int = bx.skip_beans_noise(line, i)
        if past > i {
            i = past
            continue
        }
        if line.byte_at(i) as int != 40 {
            i = i + 1
            continue
        }
        // Walk back over the method name, and over a `<Type>` if there is one.
        var start: int = i
        if start > 0 && line.byte_at(start - 1) as int == 62 {
            var angle: int = start - 1
            for angle > 0 {
                if line.byte_at(angle) as int == 60 { break }
                angle = angle - 1
            }
            start = angle
        }
        var name_stop: int = start
        for start > 0 {
            if !bx.is_ident_byte(line.byte_at(start - 1) as int) { break }
            start = start - 1
        }
        if start == 0 || name_stop == start {
            i = i + 1
            continue
        }
        // The receiver has to be the render's own Builder. Without that,
        // `self.dismiss(1)` inside a handler would read as a builder call.
        if line.byte_at(start - 1) as int != 46 || start < 2 {
            i = i + 1
            continue
        }
        if line.byte_at(start - 2) as int != 98 {
            i = i + 1
            continue
        }
        if start >= 3 && bx.is_ident_byte(line.byte_at(start - 3) as int) {
            i = i + 1
            continue
        }
        let method: string = line.slice(start, i)
        let arguments: List<string> = self.split_arguments(line, i)
        if arguments.is_empty() {
            i = i + 1
            continue
        }
        match arguments[0].trim().to_int() {
            ok(seq) => {
                var description: string = method
                if arguments.len() > 1 {
                    let second: string = arguments[1].trim()
                    if second.starts_with("\"") && second.ends_with("\"") && second.len() > 1 {
                        description = "{method} {second.slice(1, second.len() - 1)}"
                    }
                }
                if !out.contains_key(seq) { out[seq] = [] }
                match out.get(seq) {
                    some(seen) => {
                        var known: bool = false
                        for entry: string in seen {
                            if entry == description { known = true }
                        }
                        if !known { seen.push(description) }
                    }
                    none => {}
                }
            }
            err(_) => {}
        }
        i = i + 1
    }
}

/// The arguments of the call whose `(` is at `open`, split at top level.
    fn split_arguments(line: string, open: int) -> List<string> {
    let out: List<string> = []
    var closed: bool = false
    var depth: int = 0
    var run: int = open + 1
    var i: int = open
    for i < line.len() {
        let past: int = bx.skip_beans_noise(line, i)
        if past > i {
            i = past
            continue
        }
        let byte: int = line.byte_at(i) as int
        if byte == 40 || byte == 91 || byte == 123 {
            depth = depth + 1
            i = i + 1
            continue
        }
        if byte == 41 || byte == 93 || byte == 125 {
            depth = depth - 1
            if depth == 0 {
                out.push(line.slice(run, i))
                closed = true
                break
            }
            i = i + 1
            continue
        }
        if byte == 44 && depth == 1 {
            out.push(line.slice(run, i))
            run = i + 1
        }
        i = i + 1
    }
    // A call that runs past the end of the line — a handler closure. What is
    // on this line is still the seq.
    if !closed { out.push(line.slice(run, line.len())) }
    return move out
}

/// Does every number the hand-written file uses mean the same thing in the
/// generated one?
    fn compare_meanings(what: string, hand_path: string, source: string, latte_module: string) {
    var hand_text: string = ""
    match fs.read(hand_path) {
        ok(text) => { hand_text = text }
        err(problem) => {
            self.failures = self.failures + 1
            io.println("FAIL cannot read {hand_path}: {problem.msg}")
            return
        }
    }
    let options: bx.Options = new bx.Options()
    options.latte_module = latte_module
    let compiled: bx.Compiled = bx.compile_file(source, options)
    if !compiled.is_ok() {
        self.failures = self.failures + 1
        io.println("FAIL {source} does not compile:")
        io.println(compiled.report(source))
        return
    }
    var hand: Map<int, List<string>> = {}
    var made: Map<int, List<string>> = {}
    self.seq_meanings(hand_text, hand)
    self.seq_meanings(compiled.source, made)
    var numbers: List<int> = hand.keys()
    numbers.sort()
    var agreed: int = 0
    let missing: List<string> = []
    for seq: int in numbers {
        match hand.get(seq) {
            some(wanted) => {
                for description: string in wanted {
                    var found: bool = false
                    match made.get(seq) {
                        some(offered) => {
                            for entry: string in offered {
                                if entry == description { found = true }
                            }
                        }
                        none => {}
                    }
                    if found {
                        agreed = agreed + 1
                    } else {
                        var offered_text: string = "(no call at {seq})"
                        match made.get(seq) {
                            some(offered) => { offered_text = offered.join(" | ") }
                            none => {}
                        }
                        missing.push("  {seq}: hand-written `{description}`, latte-bx `{offered_text}`")
                    }
                }
            }
            none => {}
        }
    }
    io.println("{what}: {agreed} of the hand-written file's numbered calls mean the same thing in latte-bx's output")
    if missing.is_empty() {
        io.println("  every sequence number agrees")
    } else {
        io.println("  these do not:")
        for line: string in missing { io.println(line) }
    }
    var extra: List<int> = made.keys()
    extra.sort()
    let unmatched: List<string> = []
    for seq: int in extra {
        if hand.contains_key(seq) { continue }
        match made.get(seq) {
            some(offered) => { unmatched.push("{seq}: {offered.join(" | ")}") }
            none => {}
        }
    }
    if !unmatched.is_empty() {
        io.println("  numbers latte-bx uses that the hand-written file does not: {unmatched.join(", ")}")
    }
}
}

// ---------------------------------------------------------------------- main

fn main() {
    let suite: Suite = new Suite()
    io.println("======== the contract between bx/html.b and frames.b ========")
    suite.contract_agrees()
    suite.event_table_agrees()
    io.println("both copies of the escaping and refusal rules agree over the corpus")
    suite.vocabulary_agrees()
    suite.block_keywords_parse()
    suite.json_escaping()
    io.println("the editor vocabulary and the tables it mirrors agree over the corpus")

    suite.show_tree("price")
    suite.show_tree("blocks")

    suite.show_whole_file("simple")
    suite.show_render("price")
    suite.show_render("expr")
    suite.show_render("blocks")
    suite.show_render("attrs")
    suite.show_render("raw")
    suite.show_render("beans")
    suite.show_render("generic")

    io.println("======== the drift gate ========")
    suite.drift("tests/w2cases/equiv.bx", "tests/w2_equiv.b", "latte")

    io.println("======== gate 4, the text half ========")
    io.println("probes/p8_builder/pages/counter_gen.b was hand-written by W0 from")
    io.println("PLAN.md's worked example, before the emitter existed.")
    suite.compare_meanings("counter", "probes/p8_builder/pages/counter_gen.b",
                     "probes/p8_builder/pages/counter.bx", "p8_builder.core")
    suite.compare_meanings("hint", "probes/p8_builder/pages/hint_gen.b",
                     "probes/p8_builder/pages/hint.bx", "p8_builder.core")

    if suite.failures == 0 {
        io.println("======== markup: every check passed ========")
    } else {
        io.println("======== markup: {suite.failures} check(s) FAILED ========")
    }
}
