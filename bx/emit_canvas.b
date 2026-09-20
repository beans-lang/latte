// emit_canvas.b — the markup tree as `Builder` calls.
// Sequence numbers, why nothing folds, and what is refused: docs/notes.md.

package bx

import latte.visual

// -------------------------------------------------------------- the counters

/// One counter per scope that restarts at 0: a loop body and a fragment body.
/// A restart needs a qualifier from outside it, or two scopes hand out one set.
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
    /// The type parameters of a generic component, which markup may not spell:
    /// `<T>` rides on one part, so the generated part cannot name it.
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
    /// The loop-row variable in scope, or `""` outside every loop. A child
    /// component inside a loop takes its key from it.
    row_name: string = ""

    /// How many keyless `$for` loops have been emitted, so each index variable
    /// gets a name of its own. Not the sequence number: nested loops share one.
    loops: int = 0

    /// The same rules the parser used, so a tag it already refused is not
    /// refused twice with a different list of names.
    rules: CanvasRules = new CanvasRules()

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

    /// The Builder this scope writes on: `b` at the top, because that is what
    /// `render(b: Builder)` is handed, and a numbered one inside a fragment.
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

    /// What makes author code unusable where it lands. Generated code binds
    /// in the same scope, so `$for b in ...` would capture the Builder.
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

    /// Whether `code` can be written inside a generated `"{ ... }"`: a Beans
    /// literal cannot span lines, and the whole must scan as one string.
    fn check_interpolated(code: string, at: Span, what: string) -> bool {
        if code.find_byte(10, 0) >= 0 || code.find_byte(13, 0) >= 0 {
            self.report(at, "{what} spans more than one line, and it is interpolated into a generated string — a Beans string literal cannot span lines, and joining the lines would swallow the rest of a // comment. Put the expression on one line, or compute it in a $\{ ... \} block and interpolate the result")
            return false
        }
        // Unreachable from markup the parser accepts: the `{ }` scanner
        // refuses first. Kept because the two scanners are separate code.
        let probe: string = "\"\{{code}\}\""
        if end_of_string(probe, 0) != probe.len() {
            self.report(at, "{what} cannot be interpolated: with `\"\{\"` around it the result does not read as one Beans string. A nested string holding an unmatched brace does this — write \\\{ or \\\} inside it, exactly as you would in any Beans string")
            return false
        }
        return true
    }

    /// Whether `code`, which is already a string expression, is one Beans
    /// literal. A literal that spans lines has no emission at all.
    fn check_literal(code: string, at: Span, what: string) -> bool {
        if code.find_byte(10, 0) >= 0 || code.find_byte(13, 0) >= 0 {
            self.report(at, "{what} spans more than one line, and it is written into a generated file as it stands — a Beans string literal cannot span lines. Put it on one line, or build it in a $\{ ... \} block")
            return false
        }
        if end_of_string(code, 0) != code.len() {
            self.report(at, "{what} does not read as one Beans string — a nested string holding an unmatched brace does this. Write \\\{ or \\\} inside it, exactly as you would in any Beans string")
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

    /// One run of siblings. Adjacent text and expressions are **one** frame:
    /// a control has one text, so two frames would be two controls' worth.
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
            // Nothing folds here. The html target folds a subtree into one
            // string; a tree of controls has no string to fold into.
            self.node(list[i], indent)
            i = i + 1
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
                some(text) => { parts.push(canvas_escape_beans_string(text.text)) }
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
                self.check_code(expr.code, expr.span, "an interpolated expression")
                let seq: int = self.counters.next()
                if !self.check_interpolated(expr.code, expr.span, "an interpolated expression") { return }
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
        // Unreachable: `parse_beans` lifts the block into `Document.beans`
        // and refuses a nested one. Kept so a changed invariant says so.
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

    /// Refuse anything the generated file could not express — here, that is
    /// only a name that is not a name. The vocabulary is the parser's.
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
            // The parser refuses these at the same span, with the same rules
            // and a suggestion; this is the backstop for an unparsed tree.
            if self.rules.tag_refusal(element.tag) != "" { return }
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

    /// One attribute, and the `bind:` place a control shows as its text.
    /// Typed, so a wrong type is a beansc error at the author's expression.
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
    /// writes it back. Two calls from one attribute, and that is all of it.
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
        // The value is the control's text, so the caller writes it after the
        // attribute run rather than as an attribute here.
        self.write(indent, "{b}.on(\"commit\", fn(_e: UiEvent) \{ {bind.code} = _e.text \})")
        return bind.code
    }

    /// One typed attribute call. `literal` is the markup's own text when the
    /// value was quoted: a closed set of words is checked against it here.
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
        if call == "text" || call == "a11y_label" {
            self.emit_interpolated_call(call, code, at, indent)
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

    /// A call whose argument is an expression inside a generated string.
    /// Every site that embeds markup code in a Beans string literal is here.
    fn emit_interpolated_call(call: string, code: string, at: Span, indent: int) {
        let made: string = canvas_interpolated(code)
        // Whatever goes in has to scan as one Beans string literal. A wrapped
        // expression and a literal that is already one fail that differently.
        if made != code {
            if !self.check_interpolated(code, at, "an attribute expression") { return }
        } else if !self.check_literal(made, at, "an attribute value") { return }
        self.write(indent, "{self.builder_name()}.{call}({made})")
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
        // The markup site plus the row, which is what makes a child keep its
        // own state: the same site next render is the same child.
        let key: string = "\"c{self.site_of(seq)}\""
        self.write(indent, "{b}.child<{element.tag}>({key}, fn({c}: {element.tag}) \{{self.trace(element.span)}")
        for attr: Attr in element.attrs {
            // A placement is the parent's to write, on the call and not on `c`.
            if canvas_is_placement_attribute(attr.name()) { continue }
            self.emit_parameter(element, attr, c, indent + 1)
        }
        // The children that are not `$slot:name` defines are the default
        // content, which is what a `$slot` with no name places.
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
        // `ref=` last, so the field is published only once the child is
        // configured — in source order, attribute order would decide.
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

    /// `ref=` on a component tag: an assignment in the setup closure, not a
    /// Builder call — so it takes no sequence number and hands back `Option<T>`.
    fn emit_component_ref(handle: RefAttr, c: string, indent: int) {
        self.check_code(handle.code, handle.span, "ref=\{ \}")
        self.write(indent, "{handle.code} = some({c})")
    }

    /// One emission site's identity: where in the file, and which turn of the
    /// enclosing `$for`. Neither half alone tells two children apart.
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
        // Unreachable: `Parser.classify` refuses every other shape on a
        // component tag. Kept so a changed invariant says so.
        self.report(attr.span, "{attr.name()} is not something a component tag can take — a component takes its parameters by their Beans names")
    }

    /// `c.row = fn(inner: Builder, order: Order) { ... }`. The body restarts
    /// numbering at 0, so `Builder.fragment` qualifies it by the placing site.
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

    /// `$if c { } else if d { } else { }`. Every arm draws from the enclosing
    /// counter, so the arms hold disjoint ranges and a number means one thing.
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

    /// `$for row: Row in self.rows { ... }`, emitted as a Beans loop. A body
    /// with no `key=` is matched by position, which rewrites a reordered list.
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
        // Unreachable: `emit_component` takes the defines out of the run
        // before it walks it. Kept so a changed invariant says so.
        if slot.mode == "define" {
            self.report(slot.span, "$slot:{slot.field()} \{ ... \} supplies a template to a component, so it only reads that way as a direct child of a component tag")
            return
        }
        // The placement site: where in the file, and which turn of the loop.
        // The number alone would hand every row of a `$for` one site.
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

/// `code` split into lines, less the markup file's own indentation on every
/// line but the first. The smallest one is taken, so nesting survives.
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

/// The first `_latte_…` identifier `code` uses, or `""`. Every name latte-bx
/// binds carries the prefix, so one refusal covers all of them.
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

/// Whether a node is literal text or an interpolated expression — the two
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
/// interpolated frame rather than a constant.
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

/// A markup literal, as a Beans string expression: escaped for embedding, not
/// interpolated, so `text="a {b}"` stays the seven characters it names.
pub fn canvas_quoted(value: string) -> string {
    return "\"{canvas_escape_beans_string(value)}\""
}

/// A Beans expression as a string expression. A quoted literal passes through;
/// anything else is wrapped, so `text={self.count}` works for any `show`.
pub fn canvas_interpolated(code: string) -> string {
    if code.len() >= 2 && code.byte_at(0) as int == 34 &&
       code.byte_at(code.len() - 1) as int == 34 {
        return code
    }
    return "\"\{{code}\}\""
}
