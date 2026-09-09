// emit.b — the markup tree as `Builder` calls.
//
// This file decides three things, and each of them can be wrong in a way that
// still compiles. That is why they are here together rather than spread out.
//
// **Sequence numbers.** A number is a *source position*, not a counter, and
// two frames carrying one number in two renders of one component must describe
// the same place in the file. The rules: source order from 0 per component
// per render; the arms of a branch take **disjoint
// ranges** out of the enclosing counter, so a number never means two things in
// one render; a region and a fragment body **restart at 0**; a child's frames
// are numbered in the child's own space. `Counters` below is a stack, one
// entry per scope that restarts, and `next()` is the only thing that hands a
// number out.
//
// **Constant folding.** A subtree with no expression anywhere inside it is
// serialized here, at build time, into one `constant` frame. Both arms are
// emitted:
//
//     if b.fold { b.constant(5, "…") }
//     else      { b.open(5, "span"); b.attr(6, "class", "icon"); … b.close() }
//
// The folded arm takes the first number of the range and the unfolded arm
// takes all of them; **numbering after the pair is the same either way**,
// which is what makes the debug switch comparable. The folded string is built
// by serializing the run's **own frame list** — the same list the unfolded
// calls are generated from, in one walk — so the two cannot describe different
// markup. They are still gated: `tests/markup.b` renders every case with
// `b.fold` on and off through the real `latte.Serializer` and compares bytes.
//
// **Refusals.** Everything `latte.Builder` refuses at run time is refused here
// at compile time — an unsafe tag name, an unsafe attribute name, an `on*`
// attribute, a `javascript:` URL, a `<script>` body that could close itself.
// Not for tidiness: the Builder *substitutes or drops*, and a folded constant
// subtree is serialized here where no Builder ever sees it, so anything
// refused there and accepted here would make one page say two different things
// depending on `b.fold`. The mirrored predicates live in `html.b` with the gate
// that keeps them in step.

package bx

// -------------------------------------------------------------- the counters

/// The sequence-number stack: one counter per scope that restarts at 0.
///
/// A scope is pushed by a region (`$for`) and by a fragment body (a `$slot`
/// define), because `latte.Builder` restarts numbering inside both. An element
/// does **not** push one: `open` enters a scope in the Builder for the
/// *sibling-ordering* check, but the numbers keep climbing, which is what
/// `probes/p8_builder/pages/counter_gen.b` shows.
pub class Counters {
    values: List<int> = [0]

    pub fn init() {}

    /// The next number in the innermost scope.
    pub fn next() -> int {
        let top: int = self.values.len() - 1
        let taken: int = self.values[top]
        self.values[top] = taken + 1
        return taken
    }

    /// The number `next()` would hand out, without taking it.
    pub fn peek() -> int {
        return self.values[self.values.len() - 1]
    }

    pub fn push() { self.values.push(0) }

    pub fn pop() {
        if self.values.len() <= 1 { return }
        let _: int = self.values.remove(self.values.len() - 1)
    }
}

// ------------------------------------------------- frames, for the fold only
//
// A miniature of `latte.Frame`, holding only what a *constant* subtree can
// contain. It exists so the folded HTML is produced by serializing frames
// rather than by a second walk of the AST: the constant walk emits one frame
// and one call per node, from the same line of code, so "the folded string is
// what the unfolded walk would have produced" is true by construction and not
// by inspection.

pub const CF_OPEN: int = 0
pub const CF_ATTRIBUTE: int = 1
pub const CF_FLAG: int = 2
pub const CF_TEXT: int = 3
pub const CF_CONSTANT: int = 4
pub const CF_CLOSE: int = 5

pub class CFrame {
    pub kind: int = 0
    pub seq: int = 0
    /// A tag name for `open`, an attribute name for `attribute` and `flag`.
    pub name: string = ""
    /// The attribute value, the text, or the pre-serialized HTML.
    pub value: string = ""
    pub present: bool = true

    pub fn init(kind: int, seq: int) {
        self.kind = kind
        self.seq = seq
    }
}

/// One attribute slot, in the order its frame appeared — the shape
/// `latte.emit_attributes` deduplicates.
class Slot {
    pub name: string = ""
    pub value: string = ""
    pub present: bool = true
    pub fn init(name: string, value: string, present: bool) {
        self.name = name
        self.value = value
        self.present = present
    }
}

/// The HTML of a constant frame run.
///
/// A copy of `latte.Serializer`'s walk, restricted to what a constant subtree
/// can hold. It has to be a copy: `bx` is a package under the `latte` module
/// root and "a package cannot import its own module root". The gate that keeps
/// the two honest is `tests/markup.b`, which renders every case through the
/// real serializer with `fold` on and off and compares bytes.
pub fn serialize_constant(frames: List<CFrame>) -> string {
    let parts: List<string> = []
    let _: int = serialize_siblings(frames, 0, MODE_NORMAL, parts)
    return parts.join("")
}

const MODE_NORMAL: int = 0
const MODE_RAW_TEXT: int = 1
const MODE_RCDATA: int = 2

fn serialize_siblings(frames: List<CFrame>, start: int, mode: int, out: List<string>) -> int {
    var index: int = start
    for index < frames.len() {
        if frames[index].kind == CF_CLOSE { return index }
        index = serialize_one(frames, index, mode, out)
    }
    return index
}

fn serialize_one(frames: List<CFrame>, index: int, mode: int, out: List<string>) -> int {
    let frame: CFrame = frames[index]
    if frame.kind == CF_TEXT {
        // Text and RCDATA escape the same three characters; only raw text
        // differs, and a raw-text body never arrives as `text`.
        out.push(escape_text(frame.value))
        return index + 1
    }
    if frame.kind == CF_CONSTANT {
        out.push(frame.value)
        return index + 1
    }
    if frame.kind != CF_OPEN {
        // Unreachable: only `open`, `attribute`, `flag`, `text`, `constant` and
        // `close` are ever pushed, and attributes are consumed by `open`.
        return index + 1
    }
    return serialize_element(frames, index, mode, out)
}

fn serialize_element(frames: List<CFrame>, index: int, mode: int, out: List<string>) -> int {
    let tag: string = frames[index].name
    let lowered: string = tag.to_lower()
    let attrs: List<Slot> = []
    var cursor: int = index + 1
    for cursor < frames.len() {
        let frame: CFrame = frames[cursor]
        if frame.kind == CF_ATTRIBUTE {
            attrs.push(new Slot(frame.name, frame.value, true))
            cursor = cursor + 1
            continue
        }
        if frame.kind == CF_FLAG {
            attrs.push(new Slot(frame.name, "", frame.present))
            cursor = cursor + 1
            continue
        }
        break
    }

    out.push("<")
    out.push(tag)
    emit_attribute_slots(attrs, out)
    out.push(">")

    if is_void_element(lowered) {
        // A void element takes no children; the parser has already made that
        // true, and the frame after its attributes is its `close`.
        if cursor < frames.len() { return cursor + 1 }
        return cursor
    }

    var inner: int = MODE_NORMAL
    if is_raw_text_element(lowered) { inner = MODE_RAW_TEXT }
    else if is_rcdata_element(lowered) { inner = MODE_RCDATA }

    if eats_leading_newline(lowered) && starts_with_newline(frames, cursor) {
        out.push("\n")
    }

    let after: int = serialize_siblings(frames, cursor, inner, out)
    out.push("</")
    out.push(tag)
    out.push(">")
    if after < frames.len() { return after + 1 }
    return after
}

fn starts_with_newline(frames: List<CFrame>, index: int) -> bool {
    if index >= frames.len() { return false }
    let frame: CFrame = frames[index]
    if frame.kind != CF_TEXT && frame.kind != CF_CONSTANT { return false }
    if frame.value.len() == 0 { return false }
    return frame.value.byte_at(0) as int == 10
}

/// Write an element's attributes, deduplicating by name with the **last slot
/// winning** — `latte.emit_attributes`, spelled again for the reason at the top
/// of this file. An absent flag that shadows an earlier attribute removes it,
/// because it is the last write for that name.
fn emit_attribute_slots(attrs: List<Slot>, out: List<string>) {
    var winner: Map<string, int> = {}
    var index: int = 0
    for index < attrs.len() {
        winner[attrs[index].name] = index
        index = index + 1
    }
    index = 0
    for index < attrs.len() {
        let slot: Slot = attrs[index]
        match winner.get(slot.name) {
            some(last) => {
                if last == index && slot.present {
                    out.push(" ")
                    out.push(slot.name)
                    out.push("=\"")
                    out.push(escape_attribute(slot.value))
                    out.push("\"")
                }
            }
            none => {}
        }
        index = index + 1
    }
}

// ------------------------------------------------------------ what came out

/// The generated half of one `.bx` file.
pub class Emitted {
    /// The body of `render`, one line each, already indented.
    pub lines: List<string> = []
    /// Every distinct component tag, in first-seen order, for the upcast
    /// assertions that make beansc do the "is this a Component?" check.
    pub components: List<string> = []
    pub diags: List<Diag> = []

    pub fn init() {}

    pub fn is_ok() -> bool { return self.diags.len() == 0 }
}

// ---------------------------------------------------------------- the walker

/// Turns a parsed `.bx` document into the body of `render`.
pub class Emitter {
    pub diags: List<Diag> = []
    pub components: List<string> = []
    counters: Counters = new Counters()
    lines: List<string> = []
    /// The `.bx` file's name, as it should read in the line map.
    file: string = ""
    /// The type parameters of a generic component. Markup inside one may not
    /// spell them: `partial class Grid<T>` may carry `<T>` on exactly one part,
    /// so the generated part is `partial class Grid` and `T` is not a name it
    /// can write.
    type_params: List<string> = []
    /// The last source line the line map printed, so a run of calls from one
    /// line does not repeat it.
    last_line: int = -1
    /// How deep we are inside a `$for` body — `key=` is only hoistable off a
    /// direct child of one.
    for_depth: int = 0
    /// Nesting depth of fragment-body closures and component setup closures,
    /// so `_latte_inner` and `_latte_c` never shadow themselves.
    inner_depth: int = 0
    setup_depth: int = 0
    /// How many keyless `$for` loops have been emitted, so the index variable
    /// each one keys by has a name of its own.
    ///
    /// Not the loop's sequence number: a nested loop is numbered in the region
    /// scope its parent opened, so an outer loop at 0 and the first loop in its
    /// body are BOTH 0, and both would declare `_latte_row_0`. Beans allows the
    /// shadowing and the result happens to be right, but a generated file whose
    /// correctness rests on which of two same-named variables is in scope is
    /// one nobody should have to read.
    loops: int = 0

    pub fn init(file: string) {
        self.file = file
    }

    // ------------------------------------------------------------ plumbing

    fn report(at: Span, message: string) {
        self.diags.push(new Diag(at, message))
    }

    fn write(indent: int, text: string) {
        self.lines.push("{"    ".repeat(indent)}{text}")
    }

    /// ` // counter.bx:12`, when the line has moved since the last one printed.
    fn trace(at: Span) -> string {
        if at.line == self.last_line { return "" }
        self.last_line = at.line
        return "  // {self.file}:{at.line}"
    }

    /// The Builder every call in the current scope is written on.
    ///
    /// `b` at the top, because that is what `render(b: Builder)` is handed. A
    /// fragment body gets its own, named with the reserved prefix and numbered
    /// by depth so two nested bodies never shadow each other.
    fn builder_name() -> string {
        if self.inner_depth == 0 { return "b" }
        if self.inner_depth == 1 { return "_latte_inner" }
        return "_latte_inner{self.inner_depth}"
    }

    fn setup_name() -> string {
        if self.setup_depth <= 1 { return "_latte_c" }
        return "_latte_c{self.setup_depth}"
    }

    // ------------------------------------------------------- code questions

    /// Everything that makes a fragment of author code unusable where it lands.
    ///
    /// Two rules, and the second is the one that bites. **Generated code binds
    /// names in the same scope the author's code lands in**, so a name the
    /// author picks can capture one of them. `$for b in self.books` is the
    /// case that matters: `b` is the Builder the generated render writes every
    /// call on, and a loop that rebinds it turns `b.region(0, …)` into a call
    /// on a book. Nothing about that reads as wrong, which is exactly why it
    /// has to be refused rather than documented. Every other name latte-bx
    /// binds carries the `_latte_` prefix and that prefix is refused too, so
    /// `b` is the only word this costs anyone.
    fn check_code(code: string, at: Span, what: string) {
        for name: string in self.type_params {
            if !uses_identifier(code, name) { continue }
            self.report(at, "{what} spells {name}, and the generated half of a generic component may not — `partial class` may carry its type parameters on exactly one part, so latte-bx writes `partial class` with none and {name} is not a name it can use (probes/ANSWERS.md §4). Drop the annotation and let it be inferred, or move the code that needs {name} into the <beans> block")
        }
        if uses_identifier(code, "b") {
            self.report(at, "{what} uses `b`, which is the name the generated render gives its Builder — a binding or a value called `b` in markup would capture it, and `b.open(...)` would silently become a call on whatever you named. Rename it; `self.b` is fine, only a bare `b` is not")
        }
        let reserved: string = uses_reserved_name(code)
        if reserved != "" {
            self.report(at, "{what} uses `{reserved}`, and names starting with `_latte_` belong to latte-bx — it binds them in the generated render for loop keys, fragment builders and component setters. Rename it")
        }
    }

    /// Whether `code` can be written inside a generated `"{ ... }"`.
    ///
    /// Two things have to hold and the second is not obvious. **A Beans string
    /// literal cannot span lines** — `"sum {a +\n b}"` is `error: string not
    /// closed before end of line` — and every interpolated frame is emitted as
    /// `b.text(n, "{code}")`, so a multi-line expression has no correct
    /// emission at all. Collapsing the newline to a space is the tempting fix
    /// and it is wrong: it swallows the rest of a `//` comment. And the whole
    /// `"{code}"` has to *scan* as one string literal, which a nested string
    /// holding an unmatched brace breaks (`"{f("{")}"` is
    /// `error: string never closed`).
    fn check_interpolated(code: string, at: Span, what: string) -> bool {
        if code.find_byte(10, 0) >= 0 || code.find_byte(13, 0) >= 0 {
            self.report(at, "{what} spans more than one line, and it is interpolated into a generated string — a Beans string literal cannot span lines, and joining the lines would swallow the rest of a // comment. Put the expression on one line, or compute it in a $\{ ... \} block and interpolate the result")
            return false
        }
        // **Unreachable from markup the parser accepts, and kept anyway.**
        // Every shape that breaks this probe — `$(self.f("{"))`, an attribute
        // `class={self.f("{")}` — breaks the markup-level `$( )` and `{ }`
        // scanners first, and the author gets *their* message ("a {...} value
        // was never closed — a } inside a string or a comment does not close
        // it"), which is the better one because it names what they typed.
        // `tests/markup_refusals.b` records that, and deleting this branch
        // leaves the golden unchanged. It stays because the two scanners are
        // separate code and the day they disagree this is the difference
        // between a refusal and a generated file beansc cannot lex.
        let probe: string = "\"\{{code}\}\""
        if end_of_string(probe, 0) != probe.len() {
            self.report(at, "{what} cannot be interpolated: with `\"\{\"` around it the result does not read as one Beans string. A nested string holding an unmatched brace does this — write \\\{ or \\\} inside it, exactly as you would in any Beans string")
            return false
        }
        return true
    }

    // --------------------------------------------------------- the entry point

    /// The body of `render`, from a parsed document.
    pub fn emit(doc: Document, type_params: List<string>) -> Emitted {
        self.type_params = type_params.clone()
        self.nodes(doc.nodes, 2)
        let out: Emitted = new Emitted()
        out.lines = self.lines.clone()
        out.components = self.components.clone()
        out.diags = self.diags.clone()
        return out
    }

    // ------------------------------------------------------------- content

    /// One run of siblings: merged text runs first, then folded constant runs,
    /// then everything else one at a time.
    ///
    /// **Adjacent text and expressions are one frame, not several.**
    /// `<h2>Count: $self.count</h2>` is `b.text(3, "Count: {self.count}")`, and
    /// that is not a size optimisation — it is what the wire protocol names: a
    /// text edit is `["ut",3,"Count: 4"]` (see `wire.b`), one edit carrying the
    /// whole string. Emitting the literal and the value as two frames would
    /// put a text node boundary in the DOM that the markup does not have, and
    /// would send two edits where the protocol describes one.
    fn nodes(list: List<Node>, indent: int) {
        var i: int = 0
        for i < list.len() {
            if is_text_or_expression(list[i]) {
                let stop: int = text_run_end(list, i)
                if run_has_expression(list, i, stop) {
                    self.text_run(list, i, stop, indent)
                    i = stop
                    continue
                }
            }
            if !node_is_constant(list[i]) {
                self.node(list[i], indent)
                i = i + 1
                continue
            }
            var j: int = i
            for j < list.len() {
                if !node_is_constant(list[j]) { break }
                // A constant text node that an expression follows belongs to
                // that expression's frame, not to this constant run.
                if is_text_or_expression(list[j]) {
                    let stop: int = text_run_end(list, j)
                    if run_has_expression(list, j, stop) { break }
                }
                j = j + 1
            }
            self.constant_run(list, i, j, indent)
            i = j
        }
    }

    /// `list[from .. to)` — text and expressions, at least one of them an
    /// expression — as one interpolated `text` frame.
    fn text_run(list: List<Node>, from: int, to: int, indent: int) {
        let seq: int = self.counters.next()
        let parts: List<string> = []
        var k: int = from
        for k < to {
            match list[k] as? TextNode {
                some(text) => { parts.push(escape_beans_string(text.text)) }
                none => {}
            }
            match list[k] as? ExprNode {
                some(expr) => {
                    self.check_code(expr.code, expr.span, "an interpolated expression")
                    let _: bool = self.check_interpolated(expr.code, expr.span,
                                                          "an interpolated expression")
                    parts.push("\{{expr.code}\}")
                }
                none => {}
            }
            k = k + 1
        }
        self.write(indent, "{self.builder_name()}.text({seq}, \"{parts.join("")}\"){self.trace(list[from].span)}")
    }

    /// `list[from .. to)` — every node in it constant — as the two arms of the
    /// fold switch, or as a plain walk when folding would save nothing.
    ///
    /// A **run**, not a single subtree: two constant siblings become one frame
    /// rather than two, which is the whole point of folding a page shell. Both
    /// arms draw from the same range, the folded one taking its first number,
    /// so what comes after is numbered the same either way.
    fn constant_run(list: List<Node>, from: int, to: int, indent: int) {
        let first: int = self.counters.peek()
        let at: Span = list[from].span
        let trace_before: int = self.last_line
        let frames: List<CFrame> = []
        let body: List<string> = []
        var k: int = from
        for k < to {
            self.constant_node(list[k], frames, body)
            k = k + 1
        }
        var numbered: int = 0
        for frame: CFrame in frames {
            if frame.kind != CF_CLOSE { numbered = numbered + 1 }
        }
        if numbered < 2 {
            // Folding one call into one call saves nothing and costs a branch
            // in every render, and a bare `text` run keeps its escaping in the
            // serializer where a folding bug cannot reach it.
            for line: string in body { self.write(indent, line) }
            return
        }
        let html: string = serialize_constant(frames)
        let after: int = self.last_line
        self.last_line = trace_before
        let mark: string = self.trace(at)
        self.write(indent, "if {self.builder_name()}.fold \{ {self.builder_name()}.constant({first}, \"{escape_beans_string(html)}\") \}{mark}")
        self.write(indent, "else \{")
        for line: string in body { self.write(indent + 1, line) }
        self.write(indent, "\}")
        self.last_line = after
    }

    /// One node of a constant run: its frames and its unfolded calls, from one
    /// walk, so the two can never describe different markup.
    fn constant_node(node: Node, frames: List<CFrame>, body: List<string>) {
        let b: string = self.builder_name()
        match node as? TextNode {
            some(text) => {
                let seq: int = self.counters.next()
                let frame: CFrame = new CFrame(CF_TEXT, seq)
                frame.value = text.text
                frames.push(frame)
                body.push("{b}.text({seq}, \"{escape_beans_string(text.text)}\")")
                return
            }
            none => {}
        }
        match node as? RawTextNode {
            some(raw) => {
                let seq: int = self.counters.next()
                let frame: CFrame = new CFrame(CF_CONSTANT, seq)
                frame.value = raw.text
                frames.push(frame)
                body.push("{b}.constant({seq}, \"{escape_beans_string(raw.text)}\")")
                return
            }
            none => {}
        }
        match node as? DoctypeNode {
            some(doctype) => {
                let seq: int = self.counters.next()
                let frame: CFrame = new CFrame(CF_CONSTANT, seq)
                frame.value = doctype.text
                frames.push(frame)
                body.push("{b}.constant({seq}, \"{escape_beans_string(doctype.text)}\")")
                return
            }
            none => {}
        }
        match node as? ElementNode {
            some(element) => {
                self.check_element(element)
                let seq: int = self.counters.next()
                let open: CFrame = new CFrame(CF_OPEN, seq)
                open.name = element.tag
                frames.push(open)
                let mark: string = self.trace(element.span)
                body.push("{b}.open({seq}, \"{escape_beans_string(element.tag)}\"){mark}")
                for attr: Attr in element.attrs {
                    match attr as? LiteralAttr {
                        some(literal) => {
                            let a: int = self.counters.next()
                            let frame: CFrame = new CFrame(CF_ATTRIBUTE, a)
                            frame.name = literal.attr_name
                            frame.value = literal.value
                            frames.push(frame)
                            body.push("{b}.attr({a}, \"{escape_beans_string(literal.attr_name)}\", \"{escape_beans_string(literal.value)}\")")
                        }
                        none => {}
                    }
                    match attr as? FlagAttr {
                        some(flag) => {
                            let a: int = self.counters.next()
                            let frame: CFrame = new CFrame(CF_FLAG, a)
                            frame.name = flag.attr_name
                            frame.value = ""
                            frames.push(frame)
                            body.push("{b}.flag({a}, \"{escape_beans_string(flag.attr_name)}\", true)")
                        }
                        none => {}
                    }
                }
                for child: Node in element.children {
                    self.constant_node(child, frames, body)
                }
                frames.push(new CFrame(CF_CLOSE, 0))
                body.push("{b}.close()")
                return
            }
            none => {}
        }
        self.report(node.span, "{node.kind()} reached the constant walk, which only holds text, raw text, a doctype and elements — this is a latte-bx bug, please report it")
    }

    /// One node that is not part of a constant run.
    fn node(node: Node, indent: int) {
        let b: string = self.builder_name()
        match node as? TextNode {
            some(text) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.text({seq}, \"{escape_beans_string(text.text)}\")")
                return
            }
            none => {}
        }
        match node as? RawTextNode {
            some(raw) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.constant({seq}, \"{escape_beans_string(raw.text)}\")")
                return
            }
            none => {}
        }
        match node as? DoctypeNode {
            some(doctype) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.constant({seq}, \"{escape_beans_string(doctype.text)}\")")
                return
            }
            none => {}
        }
        match node as? ExprNode {
            some(expr) => {
                self.check_code(expr.code, expr.span, "an interpolated expression")
                let seq: int = self.counters.next()
                if !self.check_interpolated(expr.code, expr.span, "an interpolated expression") { return }
                self.write(indent, "{b}.text({seq}, \"\{{expr.code}\}\"){self.trace(expr.span)}")
                return
            }
            none => {}
        }
        match node as? RawHtmlNode {
            some(html) => {
                self.check_code(html.code, html.span, "$html")
                let seq: int = self.counters.next()
                self.write(indent, "{b}.raw({seq}, {html.code}){self.trace(html.span)}")
                return
            }
            none => {}
        }
        match node as? CodeNode {
            some(code) => {
                self.check_code(code.code, code.span, "a $\{ \} block")
                let _: string = self.trace(code.span)
                for line: string in dedent_lines(code.code) {
                    self.write(indent, line)
                }
                return
            }
            none => {}
        }
        match node as? IfNode {
            some(branch) => { self.emit_if(branch, indent); return }
            none => {}
        }
        match node as? ForNode {
            some(loop) => { self.emit_for(loop, indent); return }
            none => {}
        }
        match node as? MatchNode {
            some(subject) => { self.emit_match(subject, indent); return }
            none => {}
        }
        match node as? SlotNode {
            some(slot) => { self.emit_slot(slot, indent); return }
            none => {}
        }
        match node as? ElementNode {
            some(element) => {
                if element.component { self.emit_component(element, indent) }
                else { self.emit_element(element, indent) }
                return
            }
            none => {}
        }
        // Unreachable by construction: `Parser.parse_beans` never returns a
        // node into the tree — it lifts the block into `Document.beans`, and
        // refuses one written at any nesting depth above zero. Kept, with a
        // message of its own, because it costs nothing and because the day
        // that invariant changes this is the difference between a diagnostic
        // about the program and one about the emitter.
        match node as? BeansNode {
            some(_) => {
                self.report(node.span, "a <beans> block is only legal at the top level of a file, not inside markup")
                return
            }
            none => {}
        }
        self.report(node.span, "latte-bx does not know how to emit a {node.kind()} node — this is a latte-bx bug, please report it")
    }

    // ------------------------------------------------------------- elements

    /// Everything about an element that is refused rather than emitted.
    ///
    /// Every one of these is something `latte.Builder` refuses at run time by
    /// substituting or dropping. Accepting it here would make the folded and
    /// the unfolded arm of one subtree disagree, because the folded arm is
    /// serialized in this file and never passes through a Builder.
    fn check_element(element: ElementNode) {
        if !tag_name_is_safe(element.tag) {
            self.report(element.span, "<{element.tag}> is not a tag name latte can write — a tag is a letter followed by letters, digits and hyphens. latte.Builder replaces an unsafe name with <span> at run time, and a folded subtree would keep the name as written, so the two would disagree")
        }
        for attr: Attr in element.attrs {
            var name: string = ""
            match attr as? LiteralAttr {
                some(literal) => { name = literal.attr_name }
                none => {}
            }
            match attr as? FlagAttr {
                some(flag) => { name = flag.attr_name }
                none => {}
            }
            match attr as? ExprAttr {
                some(expr) => { name = expr.attr_name }
                none => {}
            }
            if name == "" { continue }
            if !attribute_name_is_safe(name) {
                self.report(attr.span, "{name} is not an attribute name latte can write — a name is letters, digits, `_`, `:`, `.` and `-`, and may not start with a digit. latte.Builder drops such an attribute at run time, and a folded subtree would keep it")
            }
            if is_inline_handler_attribute(name) {
                self.report(attr.span, "{name} starts with on, and latte refuses every attribute whose name does — latte.Builder drops it at run time and a folded subtree would keep it. Write on:<event>=\{fn(e: <EventType>) \{ ... \}\} for a handler")
            }
        }
        // A literal URL with a refused scheme. The Builder substitutes
        // `about:blank` at run time; a folded subtree would carry the
        // `javascript:` through untouched, so refuse it where it is visible.
        for attr: Attr in element.attrs {
            match attr as? LiteralAttr {
                some(literal) => {
                    if is_url_attribute(literal.attr_name) && !scheme_is_allowed(literal.value) {
                        self.report(attr.span, "{literal.attr_name}=\"{literal.value}\" carries a scheme latte does not allow — the list is http, https, mailto, tel and a relative URL. latte.Builder replaces it with about:blank at run time, which a folded subtree would not, so a literal one is refused here")
                    }
                }
                none => {}
            }
        }
        if is_raw_text_element(element.tag) {
            for child: Node in element.children {
                match child as? RawTextNode {
                    some(raw) => {
                        if !raw_text_is_safe(raw.text, element.tag) {
                            self.report(element.span, "the body of this <{element.tag}> holds `</{element.tag}` or `<!--`, either of which ends the element early in a browser whatever the language inside thinks. latte.Serializer drops such a body with a fault, so the page would silently lose it")
                        }
                    }
                    none => {}
                }
            }
        }
    }

    fn emit_element(element: ElementNode, indent: int) {
        let b: string = self.builder_name()
        self.check_element(element)
        let seq: int = self.counters.next()
        self.write(indent, "{b}.open({seq}, \"{escape_beans_string(element.tag)}\"){self.trace(element.span)}")
        var bound_value: string = ""
        var bound_span: Span = element.span
        for attr: Attr in element.attrs {
            bound_value = self.emit_attribute(element, attr, indent, bound_value)
            match attr as? BindAttr {
                some(bind) => { bound_span = bind.span }
                none => {}
            }
        }
        if bound_value != "" {
            // `bind:value` on a <textarea>: the value is the element's text, so
            // the write-back sits in the attribute run and the value itself is
            // the only child.
            if element.children.len() > 0 {
                self.report(bound_span, "a <textarea> with bind:value has its value as its content, so it cannot have children as well — remove them, or drop the binding and write the text yourself")
            }
            let seq2: int = self.counters.next()
            self.write(indent, "{b}.text({seq2}, \"\{{bound_value}\}\")")
        }
        self.nodes(element.children, indent)
        self.write(indent, "{b}.close()")
    }

    /// One attribute in the attribute run. Answers the `bind:value` place a
    /// `<textarea>` still has to write as its content, or `""`.
    fn emit_attribute(element: ElementNode, attr: Attr, indent: int, bound: string) -> string {
        let b: string = self.builder_name()
        match attr as? LiteralAttr {
            some(literal) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.attr({seq}, \"{escape_beans_string(literal.attr_name)}\", \"{escape_beans_string(literal.value)}\")")
                return bound
            }
            none => {}
        }
        match attr as? FlagAttr {
            some(flag) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.flag({seq}, \"{escape_beans_string(flag.attr_name)}\", true)")
                return bound
            }
            none => {}
        }
        match attr as? ExprAttr {
            some(expr) => {
                self.check_code(expr.code, expr.span, "an attribute expression")
                let seq: int = self.counters.next()
                if is_boolean_attribute(expr.attr_name) {
                    self.write(indent, "{b}.flag({seq}, \"{escape_beans_string(expr.attr_name)}\", {expr.code})")
                    return bound
                }
                if !self.check_interpolated(expr.code, expr.span, "an attribute expression") { return bound }
                self.write(indent, "{b}.attr({seq}, \"{escape_beans_string(expr.attr_name)}\", \"\{{expr.code}\}\")")
                return bound
            }
            none => {}
        }
        match attr as? EventAttr {
            some(event) => {
                self.check_code(event.code, event.span, "an event handler")
                let method: string = event_method(event.event)
                if method == "" {
                    self.report(event.span, "on:{event.event} is not an event latte has — the table is {event_list()}")
                    return bound
                }
                let seq: int = self.counters.next()
                self.write_call(indent, "{b}.{method}({seq}, ", event.code, ")")
                return bound
            }
            none => {}
        }
        match attr as? BindAttr {
            some(bind) => { return self.emit_bind(element, bind, indent, bound) }
            none => {}
        }
        match attr as? SplatAttr {
            some(splat) => {
                self.check_code(splat.code, splat.span, "attrs=\{ \}")
                let seq: int = self.counters.next()
                self.write(indent, "{b}.attrs({seq}, {splat.code})")
                return bound
            }
            none => {}
        }
        match attr as? RefAttr {
            some(handle) => {
                self.check_code(handle.code, handle.span, "ref=\{ \}")
                let seq: int = self.counters.next()
                self.write(indent, "{b}.reference({seq}, fn(_latte_handle: Reference) \{ {handle.code} = _latte_handle \})")
                return bound
            }
            none => {}
        }
        match attr as? PreserveAttr {
            some(_) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.preserve({seq})")
                return bound
            }
            none => {}
        }
        match attr as? KeyAttr {
            some(key) => {
                self.report(key.span, "key=\{ \} names the identity of one row of a $for, so it belongs on a tag directly inside a $for body. Here it names nothing the differ can use")
                return bound
            }
            none => {}
        }
        self.report(attr.span, "latte-bx does not know how to emit the attribute {attr.name()} — this is a latte-bx bug, please report it")
        return bound
    }

    /// `bind:value` and `bind:checked`: the value out, then the handler that
    /// writes it back.
    fn emit_bind(element: ElementNode, bind: BindAttr, indent: int, bound: string) -> string {
        let b: string = self.builder_name()
        self.check_code(bind.code, bind.span, "a bind: place")
        if bind.target == "checked" {
            let seq: int = self.counters.next()
            self.write(indent, "{b}.flag({seq}, \"checked\", {bind.code})")
            let handler: int = self.counters.next()
            self.write(indent, "{b}.on_change({handler}, fn(e: InputEvent) \{ {bind.code} = e.checked \})")
            return bound
        }
        var out: string = bound
        let lowered: string = element.tag.to_lower()
        if lowered == "textarea" {
            if !self.check_interpolated(bind.code, bind.span, "a bind:value place") { return out }
            out = bind.code
        } else {
            let seq: int = self.counters.next()
            if !self.check_interpolated(bind.code, bind.span, "a bind:value place") { return out }
            self.write(indent, "{b}.attr({seq}, \"value\", \"\{{bind.code}\}\")")
        }
        let handler: int = self.counters.next()
        if bind.modifier == "" {
            self.write(indent, "{b}.on_input({handler}, fn(e: InputEvent) \{ {bind.code} = e.value \})")
            return out
        }
        if bind.modifier == "bool" {
            self.write(indent, "{b}.on_input({handler}, fn(e: InputEvent) \{ {bind.code} = e.value == \"true\" \})")
            return out
        }
        // `.int` and `.float`: a value that will not convert leaves the field
        // alone. Clearing it would delete what the reader typed halfway through
        // a number.
        var conversion: string = "to_int"
        if bind.modifier == "float" { conversion = "to_float" }
        self.write(indent, "{b}.on_input({handler}, fn(e: InputEvent) \{")
        self.write(indent + 1, "match e.value.{conversion}() \{")
        self.write(indent + 2, "ok(_latte_value) => \{ {bind.code} = _latte_value \}")
        self.write(indent + 2, "err(_) => \{\}")
        self.write(indent + 1, "\}")
        self.write(indent, "\})")
        return out
    }

    /// A call whose one argument is author code that may span lines.
    ///
    /// The code keeps its own shape — a handler closure is written the way the
    /// author wrote it — but its *base* indentation is the `.bx` file's, so it
    /// is stripped and the call's is put back. Without that, a handler written
    /// three tags deep in the markup arrives three levels too far right and its
    /// closing brace does not line up with the call it closes.
    fn write_call(indent: int, head: string, code: string, tail: string) {
        let pieces: List<string> = dedent_lines(code)
        if pieces.len() == 1 {
            self.write(indent, "{head}{code}{tail}")
            return
        }
        var i: int = 0
        for i < pieces.len() {
            if i == 0 {
                self.write(indent, "{head}{pieces[0]}")
            } else if i == pieces.len() - 1 {
                self.write(indent, "{pieces[i]}{tail}")
            } else {
                self.write(indent, pieces[i])
            }
            i = i + 1
        }
    }

    // ------------------------------------------------------------ components

    fn emit_component(element: ElementNode, indent: int) {
        let b: string = self.builder_name()
        self.note_component(element.tag)
        for attr: Attr in element.attrs {
            match attr as? KeyAttr {
                some(key) => {
                    self.report(key.span, "key=\{ \} names the identity of one row of a $for, so it belongs on a tag directly inside a $for body. Here it names nothing the differ can use")
                }
                none => {}
            }
        }
        let seq: int = self.counters.next()
        self.setup_depth = self.setup_depth + 1
        let c: string = self.setup_name()
        self.write(indent, "{b}.component<{element.tag}>({seq}, fn({c}: {element.tag}) \{{self.trace(element.span)}")
        for attr: Attr in element.attrs {
            self.emit_parameter(element, attr, c, indent + 1)
        }
        // The children that are not `$slot:name { ... }` definitions are the
        // component's default child content, which is the `body` field a
        // `$slot` with no name places.
        let content: List<Node> = []
        for child: Node in element.children {
            var is_define: bool = false
            match child as? SlotNode {
                some(slot) => { is_define = slot.mode == "define" }
                none => {}
            }
            if !is_define { content.push(child) }
        }
        if content.len() > 0 {
            self.emit_fragment_field(c, "body", "", "", content, indent + 1,
                                     element.span)
        }
        for child: Node in element.children {
            match child as? SlotNode {
                some(slot) => {
                    if slot.mode != "define" { continue }
                    self.emit_fragment_field(c, slot.field(), slot.param_name,
                                             slot.param_type, slot.body, indent + 1,
                                             slot.span)
                }
                none => {}
            }
        }
        // `ref=` last, so the parent's field is published only once the child
        // is completely configured. In source order it would mean two things:
        // `<Grid ref={self.grid} rows={self.rows}/>` would publish before
        // `rows` was set and `<Grid rows={self.rows} ref={self.grid}/>` after,
        // and the same markup meaning two things by attribute order is not
        // something machine-written code should have.
        for attr: Attr in element.attrs {
            match attr as? RefAttr {
                some(handle) => { self.emit_component_ref(handle, c, indent + 1) }
                none => {}
            }
        }
        self.write(indent, "\})")
        self.setup_depth = self.setup_depth - 1
    }

    /// `ref=` on a component tag: an assignment inside the setup closure.
    ///
    /// **Not** `b.reference(...)`, and the difference is forced rather than
    /// chosen. Every attribute-position call needs `in_attributes`, which only
    /// `open()` sets, and a component tag opens no element — so a `Reference`
    /// there has no spelling any emission can reach. The assignment is also
    /// the better answer: it hands back the concrete type, so
    /// `self.grid.reload()` needs no downcast, and it is filled at **mount**,
    /// not after the applier has run, because a component instance exists as
    /// soon as it is activated.
    ///
    /// The place is written as `Option<T>`, so a child that is never reached —
    /// a branch arm that did not run — is `none` rather than a stale instance
    /// the author cannot tell from a live one. A field declared as a bare `T`
    /// is a beansc type error naming the author's own field, which is the
    /// diagnostic they can act on.
    ///
    /// It takes **no sequence number**: it is not a Builder call at all, so a
    /// `ref=` on a component tag never shifts the numbering of anything
    /// around it.
    fn emit_component_ref(handle: RefAttr, c: string, indent: int) {
        self.check_code(handle.code, handle.span, "ref=\{ \}")
        self.write(indent, "{handle.code} = some({c})")
    }

    fn note_component(tag: string) {
        for seen: string in self.components {
            if seen == tag { return }
        }
        self.components.push(tag)
    }

    /// One parameter on a component tag: its Beans field, by its Beans name.
    fn emit_parameter(element: ElementNode, attr: Attr, c: string, indent: int) {
        match attr as? LiteralAttr {
            some(literal) => {
                self.write(indent, "{c}.{literal.attr_name} = \"{escape_beans_string(literal.value)}\"")
                return
            }
            none => {}
        }
        match attr as? FlagAttr {
            some(flag) => {
                self.write(indent, "{c}.{flag.attr_name} = true")
                return
            }
            none => {}
        }
        match attr as? ExprAttr {
            some(expr) => {
                self.check_code(expr.code, expr.span, "a component parameter")
                self.write_call(indent, "{c}.{expr.attr_name} = ", expr.code, "")
                return
            }
            none => {}
        }
        // `ref=` is not a parameter — `emit_component` writes it last, after
        // everything else the setup closure sets. `key=` was already refused.
        match attr as? RefAttr {
            some(_) => { return }
            none => {}
        }
        match attr as? KeyAttr {
            some(_) => { return }
            none => {}
        }
        // Unreachable by construction: `Parser.classify` sends every attribute
        // on a component tag to `classify_parameter`, which refuses `attrs`,
        // `preserve` and any name that is not a Beans field, and refuses `on:`
        // and `bind:` in `classify_event`/`classify_bind` before that. So no
        // Splat, Preserve, Event or Bind attribute can reach a component tag.
        // Deleting this line leaves `tests/markup_refusals.b`'s golden
        // unchanged, which is the evidence, and it stays for the same reason
        // the BeansNode branch above does.
        self.report(attr.span, "{attr.name()} is not something a component tag can take — a component takes its parameters by their Beans names")
    }

    /// `c.row = fn(inner: Builder, order: Order) { ... }`.
    ///
    /// A fragment body restarts numbering at 0, the way a region does: the
    /// frames it writes are separated from their surroundings by
    /// `fragment_open`/`fragment_close`, and `latte.Builder.fragment` enters a
    /// scope around the call.
    fn emit_fragment_field(c: string, field: string, param: string,
                           param_type: string, body: List<Node>, indent: int,
                           at: Span) {
        if param != "" {
            self.check_code(param_type, at, "a $slot parameter type")
            self.check_code(param, at, "a $slot parameter name")
        }
        self.inner_depth = self.inner_depth + 1
        let inner: string = self.builder_name()
        if param == "" {
            self.write(indent, "{c}.{field} = fn({inner}: Builder) \{")
        } else {
            self.write(indent, "{c}.{field} = fn({inner}: Builder, {param}: {param_type}) \{")
        }
        self.counters.push()
        self.nodes(body, indent + 1)
        self.counters.pop()
        self.write(indent, "\}")
        self.inner_depth = self.inner_depth - 1
    }

    // ---------------------------------------------------------------- blocks

    /// `$if c { } else if d { } else { }`.
    ///
    /// Every arm draws from the **enclosing** counter, in order, so the arms
    /// hold disjoint ranges and a number never means two things in one render.
    /// That is what lets the differ compare a `constant` frame by number.
    fn emit_if(node: IfNode, indent: int) {
        if node.branches.is_empty() { return }
        var index: int = 0
        for index < node.branches.len() {
            let branch: Branch = node.branches[index]
            var head: string = ""
            if index == 0 {
                self.check_code(branch.header, branch.span, "an $if condition")
                head = "if {branch.header} \{"
            } else if branch.header == "" {
                head = "\} else \{"
            } else {
                self.check_code(branch.header, branch.span, "an $if condition")
                head = "\} else if {branch.header} \{"
            }
            self.write(indent, "{head}{self.trace(branch.span)}")
            self.nodes(branch.body, indent + 1)
            index = index + 1
        }
        self.write(indent, "\}")
    }

    /// `$for row: Row in self.rows { }` — one region per row.
    ///
    /// `seq` names the LOOP and is the same on every row; the key names the
    /// row. Numbering inside the body restarts at 0, so a loop body is numbered
    /// once no matter how many rows it produces — which is why a 50,000-row
    /// table needs no 50,000 numbers.
    fn emit_for(node: ForNode, indent: int) {
        let b: string = self.builder_name()
        self.check_code(node.header, node.span, "a $for header")
        let seq: int = self.counters.next()
        let key: string = self.hoist_key(node)
        var expression: string = key
        var index_name: string = ""
        if key == "" {
            // No `key=`: key by position. A reordered list is then a rewrite
            // rather than a move, which is a real cost and is documented rather
            // than left to be discovered.
            index_name = "_latte_row_{self.loops}"
            self.loops = self.loops + 1
            self.write(indent, "var {index_name}: int = 0")
            expression = index_name
        }
        self.write(indent, "for {node.header} \{{self.trace(node.span)}")
        self.write(indent + 1, "{b}.region({seq}, \"\{{expression}\}\")")
        self.counters.push()
        self.for_depth = self.for_depth + 1
        self.nodes(node.body, indent + 1)
        self.for_depth = self.for_depth - 1
        self.counters.pop()
        self.write(indent + 1, "{b}.end_region()")
        if index_name != "" {
            self.write(indent + 1, "{index_name} += 1")
        }
        self.write(indent, "\}")
    }

    /// Take the `key={...}` off a direct child of a `$for` body, so it names
    /// the region rather than becoming an HTML attribute nobody asked for.
    fn hoist_key(node: ForNode) -> string {
        var found: string = ""
        for child: Node in node.body {
            match child as? ElementNode {
                some(element) => {
                    let kept: List<Attr> = []
                    for attr: Attr in element.attrs {
                        var code: string = ""
                        match attr as? KeyAttr {
                            some(key) => { code = key.code }
                            none => {}
                        }
                        if code == "" {
                            kept.push(attr)
                            continue
                        }
                        if found != "" {
                            self.report(attr.span, "two key=\{ \} in one $for body — a row has one identity, so put the key on the one tag that is the row")
                            continue
                        }
                        self.check_code(code, attr.span, "a key= expression")
                        if !self.check_interpolated(code, attr.span, "a key= expression") { continue }
                        found = code
                    }
                    element.attrs = move kept
                }
                none => {}
            }
        }
        return found
    }

    /// `$match v { some(x) => { } none => { } }` — arms take disjoint ranges,
    /// like the arms of an `$if`.
    fn emit_match(node: MatchNode, indent: int) {
        self.check_code(node.header, node.span, "a $match subject")
        self.write(indent, "match {node.header} \{{self.trace(node.span)}")
        for arm: MatchArm in node.arms {
            self.check_code(arm.pattern, arm.span, "a $match pattern")
            self.write(indent + 1, "{arm.pattern} => \{")
            self.nodes(arm.body, indent + 2)
            self.write(indent + 1, "\}")
        }
        self.write(indent, "\}")
    }

    // ----------------------------------------------------------------- slots

    fn emit_slot(slot: SlotNode, indent: int) {
        let b: string = self.builder_name()
        if slot.mode == "define" {
            self.report(slot.span, "$slot:{slot.field()} \{ ... \} supplies a template to a component, so it only reads that way as a direct child of a component tag")
            return
        }
        if slot.mode == "place_expr" {
            self.check_code(slot.code, slot.span, "a $slot expression")
            let seq: int = self.counters.next()
            self.write(indent, "{b}.fragment({seq}, {slot.code}){self.trace(slot.span)}")
            return
        }
        if slot.mode == "place_arg" {
            self.check_code(slot.code, slot.span, "a $slot argument")
            let seq: int = self.counters.next()
            self.inner_depth = self.inner_depth + 1
            let inner: string = self.builder_name()
            self.inner_depth = self.inner_depth - 1
            self.write(indent, "{b}.fragment({seq}, fn({inner}: Builder) \{ self.{slot.field()}({inner}, {slot.code}) \}){self.trace(slot.span)}")
            return
        }
        let seq: int = self.counters.next()
        self.write(indent, "{b}.fragment({seq}, self.{slot.field()}){self.trace(slot.span)}")
    }
}

// --------------------------------------------------------------- constantness

/// Whether a subtree holds no expression anywhere inside it.
///
/// Constant means two things at once: serializing it is a copy, and diffing it
/// is a number and a string comparison rather than a walk. Everything that
/// could evaluate differently between two renders makes a node not constant —
/// and so does `preserve` and `ref`, which are not values but *instructions to
/// the differ* that folding the subtree away would silently delete.
pub fn node_is_constant(node: Node) -> bool {
    match node as? TextNode {
        some(_) => { return true }
        none => {}
    }
    match node as? RawTextNode {
        some(_) => { return true }
        none => {}
    }
    match node as? DoctypeNode {
        some(_) => { return true }
        none => {}
    }
    match node as? ElementNode {
        some(element) => {
            if element.component { return false }
            for attr: Attr in element.attrs {
                if !attribute_is_constant(attr) { return false }
            }
            for child: Node in element.children {
                if !node_is_constant(child) { return false }
            }
            return true
        }
        none => {}
    }
    return false
}

/// Whether an attribute is a fixed pair of bytes rather than a value or an
/// instruction.
pub fn attribute_is_constant(attr: Attr) -> bool {
    match attr as? LiteralAttr {
        some(_) => { return true }
        none => {}
    }
    match attr as? FlagAttr {
        some(_) => { return true }
        none => {}
    }
    return false
}

// ------------------------------------------------------------------ indenting

/// `code` split into lines, with the `.bx` file's own indentation taken off
/// every line but the first.
///
/// The first line is already positioned by whatever writes it; the rest carry
/// the markup file's indentation, which has nothing to do with the generated
/// file's. The amount taken off is the **smallest** indentation any later
/// non-blank line has, so the block's internal shape survives — a nested `if`
/// inside a handler stays nested.
pub fn dedent_lines(code: string) -> List<string> {
    let pieces: List<string> = code.split("\n")
    if pieces.len() <= 1 { return move pieces }
    var base: int = -1
    var i: int = 1
    for i < pieces.len() {
        let line: string = pieces[i]
        var lead: int = 0
        for lead < line.len() {
            let b: int = line.byte_at(lead) as int
            if b != 32 && b != 9 { break }
            lead = lead + 1
        }
        if lead < line.len() {
            if base < 0 || lead < base { base = lead }
        }
        i = i + 1
    }
    if base <= 0 { return move pieces }
    let out: List<string> = []
    i = 0
    for i < pieces.len() {
        if i == 0 {
            out.push(pieces[0])
        } else if pieces[i].len() <= base {
            out.push(pieces[i].trim())
        } else {
            out.push(pieces[i].slice(base, pieces[i].len()))
        }
        i = i + 1
    }
    return move out
}

/// The first `_latte_…` identifier `code` uses, or `""`.
///
/// Every name latte-bx binds in generated code carries this prefix — the loop
/// key counters, the fragment builders, the component setters, the ref sink —
/// so one refusal covers all of them and the set can grow without taking
/// another ordinary word out of the author's vocabulary. A name after a `.` is
/// a member, not a binding, so `self._latte_row` is not a use.
pub fn uses_reserved_name(code: string) -> string {
    var i: int = 0
    for i < code.len() {
        let past: int = skip_beans_noise(code, i)
        if past > i {
            i = past
            continue
        }
        let b: int = code.byte_at(i) as int
        if !is_ident_start_byte(b) {
            i = i + 1
            continue
        }
        let start: int = i
        for is_ident_byte(byte_of(code, i)) {
            i = i + 1
        }
        let name: string = code.slice(start, i)
        if !name.starts_with("_latte_") { continue }
        var before: int = start - 1
        for is_space_byte(byte_of(code, before)) {
            before = before - 1
        }
        if byte_of(code, before) == 46 { continue }
        return name
    }
    return ""
}

/// Whether a node is literal text or an interpolated expression — the two
/// kinds that merge into one `text` frame.
pub fn is_text_or_expression(node: Node) -> bool {
    match node as? TextNode {
        some(_) => { return true }
        none => {}
    }
    match node as? ExprNode {
        some(_) => { return true }
        none => {}
    }
    return false
}

/// The exclusive end of the maximal text-and-expression run starting at `from`.
pub fn text_run_end(list: List<Node>, from: int) -> int {
    var i: int = from
    for i < list.len() {
        if !is_text_or_expression(list[i]) { break }
        i = i + 1
    }
    return i
}

/// Whether `list[from .. to)` holds an expression, and so has to become one
/// interpolated frame rather than a constant.
pub fn run_has_expression(list: List<Node>, from: int, to: int) -> bool {
    var i: int = from
    for i < to {
        match list[i] as? ExprNode {
            some(_) => { return true }
            none => {}
        }
        i = i + 1
    }
    return false
}
