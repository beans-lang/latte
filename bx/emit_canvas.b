// emit_canvas.b — the markup tree as `Builder` calls.
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
// are numbered in the child's own space. `CanvasCounters` below is a stack, one
// entry per scope that restarts, and `next()` is the only thing that hands a
// number out.
//
// **No constant folding.** latte folds an expression-free subtree into one
// HTML string, because its output is text. latte's output is native
// controls, so there is nothing to fold into — and an unchanging subtree costs
// nothing anyway: the differ compares it once per render and finds no
// difference, which is one integer comparison per attribute and no platform
// call at all.
//
// The removed machinery is worth naming so nobody restores it by reflex: latte
// has a second serializer that must produce byte-identical output to the
// unfolded walk, a mirrored predicate table, and a gate that runs both. None
// of it has a counterpart here.
//
// (latte's own explanation, for the reader who knows that codebase:) A subtree
// with no expression anywhere inside it is
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
// markup. They are still gated there by latte's own `tests/markup.b`, which
// renders every case with `b.fold` on and off through the real
// `latte.Serializer` and compares bytes. **That file is latte's, not this
// repository's** — said plainly because a reader who greps for it here finds
// nothing and cannot tell a missing gate from a borrowed sentence.
//
// **Refusals.** latte's refusals are about HTML as a document a browser will
// execute — an `on*` attribute, a `javascript:` URL, a `<script>` body that
// could close itself. None of that reaches here, because latte's output is
// objects rather than bytes and there is nothing to inject into. What is
// refused here instead is a name that is not a name: a tag becomes a type or a
// table lookup in generated Beans, and a bad one produces a file that does not
// parse, with the error landing on a line the author never wrote.
//
// The refusals that matter most are the ones for things latte *has* and
// latte has not. `<!DOCTYPE>`, `$html`, `attrs=` and `preserve` are all
// refused in `parse.b`, by name, with a message about the program — never left
// to fall through to a generic "no such attribute", and never emitted as a
// `Builder` call that does not exist. A markup compiler whose output only
// fails at `beansc` time is a markup compiler that reports its own bugs as the
// author's.

package bx

import latte.visual

// -------------------------------------------------------------- the counters

/// The sequence-number stack: one counter per scope that restarts at 0.
///
/// A scope is pushed by a loop body (`$for`) and by a fragment body (a `$slot`
/// define), because both are emitted once and run many times — so a number
/// from the enclosing scope would name every turn or every placement. An
/// element does **not** push one: the numbers keep climbing across `open`.
///
/// A restart on its own is not enough, and this is the half that is easy to
/// miss: two scopes that both start at 0 hand out the same numbers. What tells
/// them apart is something from outside, added by whoever runs the body —
/// `emit_for` sets `row_name` so a key becomes `c{seq}.{row}`, and
/// `Builder.fragment` qualifies by the placement site. A `push()` without one
/// of those is a collision waiting for the second caller.
pub class CanvasCounters {
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

// ------------------------------------------------------------ what came out

/// The generated half of one `.bx` file.
pub class CanvasEmitted {
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
pub class CanvasEmitter {
    pub diags: List<Diag> = []
    pub components: List<string> = []
    counters: CanvasCounters = new CanvasCounters()
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
    /// The loop-row variable in scope, or `""` outside every loop. A child
    /// component inside a loop takes its key from it.
    row_name: string = ""

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
            self.report(at, "{what} spells {name}, and the generated half of a generic component may not — `partial class` may carry its type parameters on exactly one part, so latte-bx writes `partial class` with none and {name} is not a name it can use. Drop the annotation and let it be inferred, or move the code that needs {name} into the <beans> block")
        }
        if uses_identifier(code, "b") {
            self.report(at, "{what} uses `b`, which is the name the generated render gives its Builder — a binding or a value called `b` in markup would capture it, and `b.open(...)` would silently become a call on whatever you named. Rename it; `self.b` is fine, only a bare `b` is not")
        }
        let reserved: string = canvas_uses_reserved_name(code)
        if reserved != "" {
            self.report(at, "{what} uses `{reserved}`, and names starting with `_latte_` belong to latte-bx — it binds them in the generated render for loop keys, fragment builders and component setters. Rename it")
        }
    }

    /// Whether `code` can be written inside a generated `"{ ... }"`.
    ///
    /// Two things have to hold and the second is not obvious. **A Beans string
    /// literal cannot span lines** — `"sum {a +\n b}"` is `error: string not
    /// closed before end of line` — and every canvas_interpolated frame is emitted as
    /// `b.text(n, "{code}")`, so a multi-line expression has no correct
    /// emission at all. Collapsing the newline to a space is the tempting fix
    /// and it is wrong: it swallows the rest of a `//` comment. And the whole
    /// `"{code}"` has to *scan* as one string literal, which a nested string
    /// holding an unmatched brace breaks (`"{f("{")}"` is
    /// `error: string never closed`).
    fn check_interpolated(code: string, at: Span, what: string) -> bool {
        if code.find_byte(10, 0) >= 0 || code.find_byte(13, 0) >= 0 {
            self.report(at, "{what} spans more than one line, and it is canvas_interpolated into a generated string — a Beans string literal cannot span lines, and joining the lines would swallow the rest of a // comment. Put the expression on one line, or compute it in a $\{ ... \} block and interpolate the result")
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
            self.report(at, "{what} cannot be canvas_interpolated: with `\"\{\"` around it the result does not read as one Beans string. A nested string holding an unmatched brace does this — write \\\{ or \\\} inside it, exactly as you would in any Beans string")
            return false
        }
        return true
    }

    // --------------------------------------------------------- the entry point

    /// The body of `render`, from a parsed document.
    pub fn emit(doc: Document, type_params: List<string>) -> CanvasEmitted {
        self.type_params = type_params.clone()
        self.nodes(doc.nodes, 2)
        let out: CanvasEmitted = new CanvasEmitted()
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
            if canvas_is_text_or_expression(list[i]) {
                let stop: int = canvas_text_run_end(list, i)
                if canvas_run_has_expression(list, i, stop) {
                    self.text_run(list, i, stop, indent)
                    i = stop
                    continue
                }
            }
            // latte folds a subtree with no expression in it into one string,
            // because its output is HTML and a string is what the wire
            // carries. latte's output is a tree of native controls: there is
            // no string to fold into, and an unchanging subtree already costs
            // nothing after its first render because the differ finds no
            // difference in it. So every node is emitted, once, as itself.
            self.node(list[i], indent)
            i = i + 1
        }
    }

    /// `list[from .. to)` — text and expressions, at least one of them an
    /// expression — as one canvas_interpolated `text` frame.
    fn text_run(list: List<Node>, from: int, to: int, indent: int) {
        let seq: int = self.counters.next()
        let parts: List<string> = []
        var k: int = from
        for k < to {
            match list[k] as? TextNode {
                some(text) => { parts.push(canvas_escape_beans_string(text.text)) }
                none => {}
            }
            match list[k] as? ExprNode {
                some(expr) => {
                    self.check_code(expr.code, expr.span, "an canvas_interpolated expression")
                    let _: bool = self.check_interpolated(expr.code, expr.span,
                                                          "an canvas_interpolated expression")
                    parts.push("\{{expr.code}\}")
                }
                none => {}
            }
            k = k + 1
        }
        let body: string = parts.join("")
        self.write(indent, "{self.builder_name()}.text(\"{body}\"){self.trace(list[from].span)}")
    }



    /// One node that is not part of a constant run.
    fn node(node: Node, indent: int) {
        let b: string = self.builder_name()
        match node as? TextNode {
            some(text) => {
                let seq: int = self.counters.next()
                self.write(indent, "{b}.text(\"{canvas_escape_beans_string(text.text)}\")")
                return
            }
            none => {}
        }
        match node as? ExprNode {
            some(expr) => {
                self.check_code(expr.code, expr.span, "an canvas_interpolated expression")
                let seq: int = self.counters.next()
                if !self.check_interpolated(expr.code, expr.span, "an canvas_interpolated expression") { return }
                self.write(indent, "{b}.text(\"\{{expr.code}\}\"){self.trace(expr.span)}")
                return
            }
            none => {}
        }
        match node as? CodeNode {
            some(code) => {
                self.check_code(code.code, code.span, "a $\{ \} block")
                let _: string = self.trace(code.span)
                for line: string in canvas_dedent_lines(code.code) {
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

    /// Refuse anything the generated file could not express.
    ///
    /// latte's version of this method is mostly about HTML as a *document*: a
    /// tag name that would serialize into something else, an inline `onclick=`
    /// string a browser would evaluate, a `javascript:` URL. None of that
    /// exists here. latte's output is a tree of native controls, so the only
    /// thing that can go wrong at this level is a name that is not a name —
    /// and that matters because a tag becomes a type or a table lookup in
    /// generated Beans, and a bad one produces a file that does not parse with
    /// the error landing on a line the author never wrote.
    ///
    /// The attribute *vocabulary* is checked in the parser, not here, so a
    /// misspelled attribute is reported at its own position with a suggestion
    /// rather than at the element's.
    fn check_element(element: ElementNode) {
        if visual.is_tag(element.tag) && element.children.len() > 0 {
            self.report(element.span, "<{element.tag}> is a drawing leaf and cannot hold children")
        }
        if element.tag == "Path" {
            var has_data: bool = false
            for attr: Attr in element.attrs { if attr.name() == "d" { has_data = true } }
            if !has_data { self.report(element.span, "<Path> needs d= with SVG path data") }
        }
        if !canvas_tag_name_is_safe(element.tag) {
            self.report(element.span, "<{element.tag}> is not a name — a tag is a letter followed by letters, digits and underscores")
            return
        }
        if !element.component && !canvas_is_widget_tag(element.tag) {
            let gone: string = canvas_retired_tag(element.tag)
            if gone != "" {
                self.report(element.span, gone)
                return
            }
            let near: string = canvas_nearest_of(element.tag, canvas_widget_tags())
            if near == "" {
                self.report(element.span, "<{element.tag}> is not a control latte has — the controls are {canvas_widget_list()}, and a capitalised name that is not one of them is taken to be a component")
            } else {
                self.report(element.span, "<{element.tag}> is not a control latte has — did you mean <{near}>?")
            }
        }
        // A scroll view scrolls one content view on every platform here, so
        // the extras would be laid on top of it rather than after it.
        if !element.component && element.tag == "ScrollView" &&
           element.children.len() > 1 {
            self.report(element.span, "<ScrollView> holds {element.children.len()} children, and a scroll view scrolls one — put them in a <VStack> inside it")
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
            if !canvas_attribute_name_is_safe(name) {
                self.report(attr.span, "{name} is not an attribute name — a name is a letter followed by letters, digits and underscores")
                continue
            }
            // A real attribute on a control that has not got it. Components
            // are exempt: their attributes are fields beansc checks.
            // `attribute_call` first, so a misspelling stays a misspelling.
            if !element.component && canvas_attribute_call(name) != "" &&
               !canvas_tag_carries(element.tag, name) {
                self.report(attr.span, "<{element.tag}> has no {name} — {name} is carried by {canvas_tags_carrying(name)}")
            }
        }
    }

    fn emit_element(element: ElementNode, indent: int) {
        let b: string = self.builder_name()
        self.check_element(element)
        self.write(indent, "{b}.open(\"{canvas_escape_beans_string(element.tag)}\"){self.trace(element.span)}")
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
            // A control bound with `bind:` shows the bound value as its text.
            if element.children.len() > 0 {
                self.report(bound_span, "<{element.tag}> with bind: shows the bound value as its text, so it cannot have children as well — remove them, or drop the binding and write the text yourself")
            }
            self.write(indent, "{b}.text(\"\{{bound_value}\}\")")
        }
        self.nodes(element.children, indent)
        self.write(indent, "{b}.close()")
    }

    /// One attribute in the attribute run. Answers the `bind:` place a control
    /// still has to show as its text, or `""`.
    ///
    /// This is where the two markup languages differ most. latte writes every
    /// attribute as a string, because HTML attributes *are* strings, and uses a
    /// table only to tell a boolean one apart. latte's control properties are
    /// typed — a flag, a number, a word out of a fixed set — so the emitted
    /// call is typed too, and the type is decided here from
    /// `widgets.attribute_call`.
    ///
    /// The payoff is that a wrong type is a beansc error at the author's own
    /// expression rather than a string that parses to something unintended:
    /// `spacing={self.name}` says `expected f64, got string`, which is the
    /// sentence the author needs.
    fn emit_attribute(element: ElementNode, attr: Attr, indent: int, bound: string) -> string {
        let b: string = self.builder_name()
        match attr as? KeyAttr {
            some(keyed) => {
                self.check_code(keyed.code, keyed.span, "key=\{ \}")
                if !self.check_interpolated(keyed.code, keyed.span, "key=\{ \}") { return bound }
                self.write(indent, "{b}.key(\"\{{keyed.code}\}\")")
                return bound
            }
            none => {}
        }
        match attr as? LiteralAttr {
            some(literal) => {
                if element.tag == "Path" && literal.attr_name == "d" {
                    let problem: string = visual.path_problem(literal.value)
                    if problem != "" { self.report(literal.span, problem) }
                }
                self.emit_typed(element.tag, literal.attr_name, canvas_quoted(literal.value),
                                literal.value, literal.span, indent)
                return bound
            }
            none => {}
        }
        match attr as? FlagAttr {
            some(flag) => {
                // `<CheckBox checked />` — present means true.
                if canvas_attribute_call(flag.attr_name) != "flag" {
                    self.report(flag.span, "{flag.attr_name} is not a true/false attribute, so it needs a value: {flag.attr_name}=\{ ... \}")
                    return bound
                }
                self.write(indent, "{b}.flag(\"{canvas_escape_beans_string(flag.attr_name)}\", true)")
                return bound
            }
            none => {}
        }
        match attr as? ExprAttr {
            some(expr) => {
                self.check_code(expr.code, expr.span, "an attribute expression")
                self.emit_typed(element.tag, expr.attr_name, expr.code, "", expr.span, indent)
                return bound
            }
            none => {}
        }
        match attr as? EventAttr {
            some(event) => {
                self.check_code(event.code, event.span, "an event handler")
                if !canvas_is_event(event.event) {
                    self.report(event.span, "on:{event.event} is not an event latte raises — the table is {canvas_event_list()}")
                    return bound
                }
                self.write_call(indent,
                    "{b}.on(\"{canvas_escape_beans_string(event.event)}\", ", event.code, ")")
                return bound
            }
            none => {}
        }
        match attr as? BindAttr {
            some(bind) => { return self.emit_bind(element, bind, indent, bound) }
            none => {}
        }
        self.report(attr.span, "latte-bx does not know how to emit the attribute {attr.name()} — this is a latte-bx bug, please report it")
        return bound
    }

    /// `bind:value` and `bind:checked`: the value out, then the handler that
    /// writes it back.
    ///
    /// Two calls from one attribute, and that is the whole of two-way binding.
    /// The control shows the place, and a handler puts what the user did back
    /// into it — so `bind:value={self.note}` is exactly `value={self.note}`
    /// plus `on:change={fn(e) { self.note = ... }}` written once.
    fn emit_bind(element: ElementNode, bind: BindAttr, indent: int, bound: string) -> string {
        let b: string = self.builder_name()
        self.check_code(bind.code, bind.span, "a bind: place")
        if bind.target == "checked" {
            self.write(indent, "{b}.flag(\"checked\", {bind.code})")
            self.write(indent, "{b}.on(\"change\", fn(_e: UiEvent) \{ {bind.code} = _e.index != 0 \})")
            return bound
        }
        if bind.target != "value" {
            self.report(bind.span, "bind:{bind.target} is not something latte binds — it binds value on a text field and checked on a check box")
            return bound
        }
        if !self.check_interpolated(bind.code, bind.span, "a bind:value place") { return bound }
        // The value is the control's text, so it is written as the element's
        // content rather than as an attribute, and the caller emits it after
        // the attribute run.
        self.write(indent, "{b}.on(\"commit\", fn(_e: UiEvent) \{ {bind.code} = _e.text \})")
        return bind.code
    }

    /// One typed attribute call.
    ///
    /// `code` is the Beans expression to pass. `literal` is the same value as
    /// written in the markup when it came from a canvas_quoted string, `""` otherwise.
    ///
    /// `align` and `justify` need the literal: the set of words is closed, so a
    /// misspelling is refused here rather than reaching the Builder at run time.
    fn emit_typed(tag: string, name: string, code: string, literal: string, at: Span, indent: int) {
        let b: string = self.builder_name()
        let call: string = canvas_attribute_call(name)
        if tag == "Table" && name == "columns" {
            if literal != "" { self.report(at, "Table columns takes a List<string> expression"); return }
            self.write(indent, "{b}.columns({code})")
            return
        }
        if tag == "Table" && name == "source" {
            if literal != "" { self.report(at, "Table source takes a TableRows expression"); return }
            self.write(indent, "{b}.table_source({code})")
            return
        }
        if tag == "Table" && name == "editable_when" {
            if literal != "" { self.report(at, "Table editable_when takes a TableEditRule expression"); return }
            self.write(indent, "{b}.editable_when({code})")
            return
        }
        if call == "column_widths" {
            if literal != "" { self.report(at, "{name} takes a typed expression"); return }
            self.write(indent, "{b}.column_widths({code})")
            return
        }
        if call == "items" || call == "labels" {
            if literal != "" {
                self.report(at, "{name} takes a List<string> expression, such as {name}=\{self.choices\}")
                return
            }
            if call == "items" { self.write(indent, "{b}.items({code})") }
            else { self.write(indent, "{b}.labels({code})") }
            return
        }
        if call == "text" {
            self.write(indent, "{b}.text({canvas_interpolated(code)})")
            return
        }
        if call == "a11y_label" {
            self.write(indent, "{b}.a11y_label({canvas_interpolated(code)})")
            return
        }
        if call == "flag" {
            self.write(indent, "{b}.flag(\"{canvas_escape_beans_string(name)}\", {code})")
            return
        }
        if call == "number" {
            self.write(indent, "{b}.number(\"{canvas_escape_beans_string(name)}\", ({code}) as f64)")
            return
        }
        if call == "word" {
            // A colour is not a closed set, so it may be computed. `canvas_quoted`
            // wrote `code` for a literal, so both spellings emit one call.
            if canvas_is_colour_attribute(name) {
                self.write(indent, "{b}.word(\"{canvas_escape_beans_string(name)}\", {code})")
                return
            }
            if literal == "" {
                self.report(at, "{name} takes one of a fixed set of words, so it needs a literal: {name}=\"{canvas_word_example(name)}\"")
                return
            }
            if name == "transition_easing" && visual.easing_code(literal) < 0 {
                self.report(at, "transition_easing must be linear or ease_in_out")
                return
            }
            self.write(indent, "{b}.word(\"{canvas_escape_beans_string(name)}\", \"{canvas_escape_beans_string(literal)}\")")
            return
        }
        let near: string = canvas_nearest_attribute(name)
        if near == "" {
            self.report(at, "{name} is not an attribute latte knows — the list is {canvas_attribute_list()}")
        } else {
            self.report(at, "{name} is not an attribute latte knows — did you mean {near}?")
        }
    }

    fn write_call(indent: int, head: string, code: string, tail: string) {
        let pieces: List<string> = canvas_dedent_lines(code)
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
        // The key is the markup site, plus the row when the site is inside a
        // loop. That is what makes a child component keep its own state: the
        // same site on the next render is the same child, and the third row is
        // not handed the second row's.
        let key: string = "\"c{self.site_of(seq)}\""
        self.write(indent, "{b}.child<{element.tag}>({key}, fn({c}: {element.tag}) \{{self.trace(element.span)}")
        for attr: Attr in element.attrs {
            // A placement is the parent's to write, on the call and not on `c`.
            if canvas_is_placement_attribute(attr.name()) { continue }
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
        self.write(indent, "\}){self.placements_of(element)}")
        self.setup_depth = self.setup_depth - 1
    }

    /// Every placement on a component tag, chained on the call that shows it:
    /// `}).number("margin_left", (8) as f64).word("align", "center")`.
    fn placements_of(element: ElementNode) -> string {
        var chained: string = ""
        for attr: Attr in element.attrs {
            if !canvas_is_placement_attribute(attr.name()) { continue }
            chained = "{chained}{self.placement_call(attr)}"
        }
        return chained
    }

    /// One placement as a chained call, or `""` after a report.
    fn placement_call(attr: Attr) -> string {
        let name: string = attr.name()
        match attr as? LiteralAttr {
            some(literal) => {
                return self.placement_typed(name, canvas_quoted(literal.value), literal.value, literal.span)
            }
            none => {}
        }
        match attr as? ExprAttr {
            some(expr) => {
                self.check_code(expr.code, expr.span, "a placement")
                if expr.code.contains("\n") {
                    self.report(expr.span, "{name}=\{ \} on a component tag is chained onto the call that shows it, so it takes an expression written on one line")
                    return ""
                }
                return self.placement_typed(name, expr.code, "", expr.span)
            }
            none => {}
        }
        self.report(attr.span, "{name} is not a true/false attribute, so it needs a value: {name}=\{ ... \}")
        return ""
    }

    /// The same value rules a control's attribute follows, as a chained call.
    fn placement_typed(name: string, code: string, literal: string, at: Span) -> string {
        if canvas_attribute_call(name) == "number" {
            return ".number(\"{canvas_escape_beans_string(name)}\", ({code}) as f64)"
        }
        if literal == "" {
            self.report(at, "{name} takes one of a fixed set of words, so it needs a literal: {name}=\"center\"")
            return ""
        }
        return ".word(\"{canvas_escape_beans_string(name)}\", \"{canvas_escape_beans_string(literal)}\")"
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

    /// The identity of one emission site, as the *contents* of a Beans string
    /// literal.
    ///
    /// Two parts, and neither is enough on its own. The sequence number says
    /// where in the file the site is, so two sites in one render differ. The
    /// row says which turn of the enclosing `$for` is running, so two turns of
    /// one site differ — a loop body is emitted once and run many times, and
    /// the number in it is the same on every turn.
    ///
    /// One helper for a component tag and for a `$slot` placement because they
    /// ask the same question — *which child is this?* — and they were not
    /// answered the same way. `emit_component` had the row from the start;
    /// `emit_slot` wrote the bare number, so a `$slot` inside a `$for` handed
    /// every row one placement site, and a template with a component tag in it
    /// collided with itself on the second row.
    fn site_of(seq: int) -> string {
        if self.row_name == "" { return "{seq}" }
        return "{seq}.\{{self.row_name}\}"
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
                self.write(indent, "{c}.{literal.attr_name} = \"{canvas_escape_beans_string(literal.value)}\"")
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
        // Unreachable by construction. `Parser.classify` refuses `attrs` and
        // `preserve` by name before it splits on the tag kind, sends `on:` and
        // `bind:` to `classify_event`/`classify_bind`, which refuse both on a
        // component tag, and sends everything else on a component tag to
        // `classify_parameter`, which takes only a Beans identifier. `key=` and
        // `ref=` are handled above. So nothing reaches this line today; it
        // stays for the reason the `BeansNode` branch in `node` does — it costs
        // nothing, and the day that invariant changes it is the difference
        // between a diagnostic about the program and one about the emitter.
        self.report(attr.span, "{attr.name()} is not something a component tag can take — a component takes its parameters by their Beans names")
    }

    /// `c.row = fn(inner: Builder, order: Order) { ... }`.
    ///
    /// **A fragment body restarts numbering at 0**, the way a `$for` body
    /// does, because the body is emitted here — at its definition site — and
    /// run somewhere else entirely: against the builder of whichever component
    /// places it, at whatever depth that component's own render had reached.
    /// There is no number from this file that would mean anything over there.
    ///
    /// The restart is what makes the placement site load-bearing.
    /// `Builder.fragment(seq, body)` qualifies every child key the body writes
    /// with its own `seq`, exactly as `emit_for` qualifies with the row — a
    /// counter that starts again needs something from outside it to tell its
    /// numbers apart, and `seq` is the only thing the placing side has.
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

    /// `$for row: Row in self.rows { ... }` — a Beans loop, emitted as one.
    ///
    /// latte wraps each turn in a `region`, because its wire protocol needs a
    /// name for the run of frames one iteration produced. latte needs none:
    /// the loop body's `key={...}` becomes `Builder.key` on the element
    /// itself, and the differ matches keyed siblings wherever they moved to.
    /// One fewer concept, and the key lands on the thing it identifies.
    ///
    /// A body with no `key=` is matched by position. That is a real cost on a
    /// reordered list — every row after the change is rewritten — and it is
    /// the cost the golden file in `tests/diff.b` records beside the keyed one.
    fn emit_for(node: ForNode, indent: int) {
        self.check_code(node.header, node.span, "a $for header")
        let row: string = "_latte_row_{self.loops}"
        self.loops = self.loops + 1
        self.write(indent, "var {row}: int = 0")
        self.write(indent, "for {node.header} \{{self.trace(node.span)}")
        self.counters.push()
        self.for_depth = self.for_depth + 1
        let outer: string = self.row_name
        self.row_name = row
        self.nodes(node.body, indent + 1)
        self.row_name = outer
        self.for_depth = self.for_depth - 1
        self.counters.pop()
        self.write(indent + 1, "{row} += 1")
        self.write(indent, "\}")
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
        // Unreachable by construction: `parse_slot_define` refuses a body
        // outside a component tag, and `emit_component` takes the defines that
        // *are* direct children out of the run before it walks it, so no define
        // node ever reaches `node()`. Kept, with a message of its own, for the
        // reason the `BeansNode` branch there is.
        if slot.mode == "define" {
            self.report(slot.span, "$slot:{slot.field()} \{ ... \} supplies a template to a component, so it only reads that way as a direct child of a component tag")
            return
        }
        // The placement site, the same two-part identity a component tag gets:
        // where in the file, and which turn of the enclosing loop. Both halves
        // are needed — `Builder.fragment` keys everything the template writes
        // by this string, and a `$slot` in a `$for` is one emitted call run
        // once per row, so the number alone would hand every row one site.
        if slot.mode == "place_expr" {
            self.check_code(slot.code, slot.span, "a $slot expression")
            let site: string = self.site_of(self.counters.next())
            self.write(indent, "{b}.fragment(\"{site}\", {slot.code}){self.trace(slot.span)}")
            return
        }
        if slot.mode == "place_arg" {
            self.check_code(slot.code, slot.span, "a $slot argument")
            let site: string = self.site_of(self.counters.next())
            self.inner_depth = self.inner_depth + 1
            let inner: string = self.builder_name()
            self.inner_depth = self.inner_depth - 1
            self.write(indent, "{b}.fragment(\"{site}\", fn({inner}: Builder) \{ self.{slot.field()}({inner}, {slot.code}) \}){self.trace(slot.span)}")
            return
        }
        let site: string = self.site_of(self.counters.next())
        self.write(indent, "{b}.fragment(\"{site}\", self.{slot.field()}){self.trace(slot.span)}")
    }
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
pub fn canvas_dedent_lines(code: string) -> List<string> {
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
pub fn canvas_uses_reserved_name(code: string) -> string {
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

/// Whether a node is literal text or an canvas_interpolated expression — the two
/// kinds that merge into one `text` frame.
pub fn canvas_is_text_or_expression(node: Node) -> bool {
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
pub fn canvas_text_run_end(list: List<Node>, from: int) -> int {
    var i: int = from
    for i < list.len() {
        if !canvas_is_text_or_expression(list[i]) { break }
        i = i + 1
    }
    return i
}

/// Whether `list[from .. to)` holds an expression, and so has to become one
/// canvas_interpolated frame rather than a constant.
pub fn canvas_run_has_expression(list: List<Node>, from: int, to: int) -> bool {
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

// ----------------------------------------------------- expressions as strings

/// A markup literal, as a Beans string expression.
///
/// The value is escaped for embedding, not canvas_interpolated: `text="a {b}"` in
/// markup means the seven characters, and a literal that happened to contain a
/// brace must not become an interpolation in generated code.
pub fn canvas_quoted(value: string) -> string {
    return "\"{canvas_escape_beans_string(value)}\""
}

/// A Beans expression as a string expression.
///
/// A canvas_quoted literal is already one and passes through; anything else is
/// wrapped in an interpolation, so `text={self.count}` works for an `int` and
/// for anything else with a `show`.
pub fn canvas_interpolated(code: string) -> string {
    if code.len() >= 2 && code.byte_at(0) as int == 34 &&
       code.byte_at(code.len() - 1) as int == 34 {
        return code
    }
    return "\"\{{code}\}\""
}
