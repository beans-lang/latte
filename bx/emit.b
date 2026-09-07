// emit.b — a `Node` tree to the Beans chain it means.
//
// The last file in the pipeline and the smallest one, because everything it
// could have decided was decided somewhere else. `bx/lex.b` and `bx/parse.b`
// say what the markup *is*; `bx/attrs.b` and `bx/colors.b` say what each
// attribute *becomes*. This file says only where the calls go, in what order,
// and which imports the result names.
//
//     <div flex gap-2 bg="red" on:click={fn(e: int) { io.println("hi") }}>
//         {inner}
//     </div>
//
//     element.div()
//         .flex()
//         .gap(style.Gap.s2)
//         .bg(style.Fill.of_rgba(color.Rgba.from_hex_alpha(0xff0000ff)))
//         .on_click(fn(e: int) { io.println("hi") })
//         .child(inner)
//
// ------------------------------------------------------------ an expression
//
// `emit` answers an **expression**: no `let`, no type annotation, no
// semicolon, no trailing newline and no package clause. That is what lets one
// driver put the same text after `let d: element.Div =`, inside a `return`,
// or as an argument to another call. The header the driver writes around it
// is the driver's; this file only says which import paths it has to contain.
//
// ------------------------------------------------------ package-qualified
//
// `element.div()`, not `div()`. DESIGN.md sketches the bare form because that
// is what a hand-written chain looks like from *inside* `crema.element`; from
// the `package main` a `.bx` file compiles to, `div()` does not resolve. The
// style and colour calls coming out of `bx/attrs.b` were already qualified,
// so this is the whole emitted text reading one way rather than two. It is
// also a checked claim and not a preference: tests/probe_bx_emit.b compiles
// what comes out.
//
// ------------------------------------------------------------------- order
//
// **Attributes in source order, then children in source order.** The order is
// not cosmetic. Two attributes writing the same `StyleRefinement` field —
// `w-4 w-8` — resolve last-one-wins, so a chain that reordered them would
// mean something the author did not write. `bx/ast.b` keeps `attrs` and
// `children` in source order for this, and the walk here never sorts.
//
// Attributes come before children because that is what a hand-written chain
// does and because `.child(..)` is where the line gets long; it reads better
// last. Nothing in crema requires it — `Styled` and `ParentElement` both
// answer `Self` — so this is a style choice and it is the only one.
//
// ------------------------------------------------ what a bare string became
//
// A diagnostic. There is nothing else honest to emit.
//
// gpui writes `impl IntoElement for String` with `type Element = StyledText`,
// so `.child("hi")` works there. crema **dropped that**: `element/element.b`
// says so in its header ("`IntoElement::Element`. The last one is gpui's way
// of saying `String: IntoElement<Element = StyledText>`"), `IntoElement` here
// carries only `into_any_element()`, and `string` does not implement it. The
// `StyledText` that does exist — `style/styled_text.b` — is a *styling*
// interface on the chain, not an element, and `crema/ui` is an empty folder.
// `crema.text` is the font, shaping and rasterising layer; it has no element
// in it either.
//
// So `.child("hi")` does not compile, and tests/probe_bx_emit.b proves that
// by trying it rather than by asserting it. Emitting an invented
// `.child(text("hi"))` would move a compile error from bx, where it can name
// the line of markup, to beansc, where it names a generated file. The
// diagnostic names the missing feature instead, and `{expr}` stays available
// underneath for anything that *is* an element.
//
// ----------------------------------------------------------------- imports
//
// `Emission.imports` is the exposure, and it is a superset by design.
// `attr_imports()` names `crema.style` and `crema.color` together rather than
// making this file sniff its own output for a `style.` prefix, which is what
// its doc comment asks for. An import a chain does not use costs nothing —
// beansc accepts it silently, checked, not assumed.
//
// Two things contribute no import and cannot: a `{code}` hole and a dotted
// tag name. bx does not read Beans, so it cannot know what package
// `theme.accent` or `ui.Panel` lives in. Those are the author's to import,
// and saying so is better than guessing.
//
// --------------------------------------------------------------- diagnostics
//
// Every fault from every table reaches the caller with its span, and the walk
// never stops at the first one. A `Result<string>` carries one `Error`, so the
// frozen pair flattens them one per line exactly the way `parse_one` does;
// `emit_tag` and `emit_expr` hand back the `List<Diag>` instead, which is what
// a driver printing them next to `TagParse.diags` wants. Both print through
// `Diag.show()`, so the two halves of bx report in one format.

package bx

// ------------------------------------------------------------- the tag table

/// One tag name and what it constructs.
///
/// A table and not an `if` chain so that a `<canvas>` or an `<img>`, the day
/// crema grows one, is one row here and nothing else anywhere.
pub struct TagRow {
    /// The tag as written, with no dot in it: `div`.
    pub tag: string = ""
    /// The constructor, package-qualified: `element.div()`.
    pub call: string = ""
    /// The import path `call` names, or "" when it names none.
    pub import_path: string = ""
    /// Whether the constructed type implements `style.Styled` and
    /// `element.InteractiveElement`. That is what decides whether the tag can
    /// carry an attribute at all, and it is read off the `implements` clause,
    /// not guessed from the name.
    pub styled: bool = false
    /// Whether it implements `element.ParentElement` and so can hold a child.
    pub parent: bool = false
    /// Why it cannot, in one phrase, for the diagnostic that refuses one.
    pub note: string = ""
}

/// Every tag bx knows.
///
/// It is short because crema's element surface is short. There are exactly
/// two `pub fn` constructors in `crema.element` that take no arguments —
/// `div()` at element/div.b:189 and `empty()` at element/element.b:416 — and
/// `Canvas<T>` is the only other element, which takes two closures and a type
/// parameter and so cannot come from a bare tag. Nothing was invented to make
/// the table look fuller.
///
/// The two flags are what `implements` says, verbatim:
///
///     Div   implements Element, style.Styled, InteractiveElement, ParentElement
///     Empty implements Element
///
/// so `<empty flex>` and `<empty>x</empty>` are diagnostics rather than
/// generated code that fails to build. A row that lied about either flag
/// would turn a bx error into a beansc error about a generated file, which is
/// the trade this whole package exists to avoid.
///
/// Plain `pub static`, initialised once before `main` from literals only. It
/// reads no other static, which is the rule RULES.md gives for keeping file
/// order from mattering (`bx/emit.b` sorts before `bx/lex.b`).
pub class Tags {
    /// The rows, in the order a suggestion walks them.
    pub static rows: List<TagRow> = [
        TagRow {
            tag: "div", call: "element.div()", import_path: "crema.element",
            styled: true, parent: true, note: "",
        },
        TagRow {
            tag: "empty", call: "element.empty()", import_path: "crema.element",
            styled: false, parent: false,
            note: "element.Empty implements Element and nothing else",
        },
    ]

    /// The table is never instantiated; every member is static.
    pub fn init() {}
}

/// Every tag bx knows, for a suggestion.
pub fn tag_names() -> List<string> {
    var out: List<string> = []
    for row: TagRow in Tags.rows {
        out.push(row.tag)
    }
    return move out
}

/// The tags as a phrase: `<div>, <empty>`.
fn tag_list() -> string {
    var parts: List<string> = []
    for row: TagRow in Tags.rows {
        parts.push("<{row.tag}>")
    }
    let sep: string = ", "
    return parts.join(sep)
}

// ------------------------------------------------------------- the result

/// What one emit produced: the text, the imports it names, and everything
/// found wrong on the way.
///
/// The parse half of bx answers a `TagParse` for the same reason and with the
/// same three questions on it, so a driver holds one shape either side.
pub class Emission {
    /// The chain. Only meaningful when `is_ok()`: a walk that faulted keeps
    /// going so it can report the rest of the tree, and what it built along
    /// the way is bx's guess, not an answer.
    pub text: string = ""
    /// The import paths the text names, deduplicated, in the order they were
    /// reached — the constructor's first, then the attribute tables'.
    ///
    /// A superset, deliberately. `attr_imports()` names `crema.style` and
    /// `crema.color` together, so a chain that only sets `flex` lists both;
    /// its doc comment asks callers not to work the pair out from the emitted
    /// strings, and an unused import compiles.
    ///
    /// A `{code}` hole and a dotted tag contribute nothing, because bx does
    /// not read Beans and cannot know where `theme.accent` or `ui.Panel`
    /// lives. Those imports belong to whoever wrote the markup.
    pub imports: List<string> = []
    /// Everything found wrong, in source order.
    pub diags: List<Diag> = []

    /// An empty emission. The walk fills it.
    pub fn init() {}

    /// Whether nothing was found wrong.
    pub fn is_ok() -> bool {
        return self.diags.is_empty()
    }

    /// Every diagnostic, one per line, in the form beansc uses — the same
    /// text `TagParse.report` produces, so a driver can print the parse and
    /// the emit halves together without reformatting either.
    pub fn report() -> string {
        let lines: List<string> = []
        for d: Diag in self.diags {
            lines.push(d.show())
        }
        let nl: string = "\n"
        return lines.join(nl)
    }
}

// --------------------------------------------------------------- entry points

/// One tag as a Beans expression: `element.div().flex().gap(style.Gap.s2)...`
///
/// No trailing newline, no `let`, no semicolon — an expression, so it can go
/// anywhere an expression goes.
///
/// Every diagnostic goes into the message, one per line. A `Result` carries
/// one `Error` and losing the other nine would undo the reason the walk
/// accumulates them at all; `parse_one` flattens for the same reason. A caller
/// that wants them apart, or wants the imports, calls `emit_expr`.
pub fn emit(root: ElementNode) -> Result<string> {
    return finish(emit_expr(root))
}

/// The same, indented as a multi-line chain starting at `depth` levels of
/// four spaces, which is what a real file wants.
///
/// `depth` is where the line the expression *starts on* sits, not where the
/// calls sit — the calls go one level deeper, and the constructor is never
/// indented at all because the caller has already put the cursor there. So
/// `emit_indented(root, 1)` is what a statement inside a function body wants:
///
///     fn view() -> element.Div \{
///         return element.div()
///             .flex()
///             .child(element.div()
///                 .gap(style.Gap.s2))
///     \}
///
/// A nested tag opens inline after `.child(` and its own calls step in one
/// more level, which is what a hand-written chain looks like and is the whole
/// point of the exercise.
pub fn emit_indented(root: ElementNode, depth: int) -> Result<string> {
    return finish(emit_tag(root, depth))
}

/// The same as `emit_indented`, with the imports and the diagnostics kept
/// apart instead of flattened into one message. What a driver wants.
pub fn emit_tag(root: ElementNode, depth: int) -> Emission {
    return run(root, depth, true)
}

/// The same as `emit`, kept apart the same way.
pub fn emit_expr(root: ElementNode) -> Emission {
    return run(root, 0, false)
}

/// Every import path this tag's chain needs, for a caller holding only the
/// frozen pair. The shape is the same either way, so the one-line form
/// answers it.
pub fn emit_imports(root: ElementNode) -> List<string> {
    let produced: Emission = emit_expr(root)
    return produced.imports.clone()
}

/// Walk one tag and pack the result.
fn run(root: ElementNode, depth: int, multiline: bool) -> Emission {
    let emitter: Emitter = new Emitter(multiline)
    let text: string = emitter.tag(root, depth + 1)
    let out: Emission = new Emission()
    out.text = text
    out.imports = emitter.imports.clone()
    out.diags = emitter.diags.clone()
    return out
}

/// An `Emission` as the `Result` the frozen pair answers.
fn finish(produced: Emission) -> Result<string> {
    if !produced.is_ok() {
        return err(produced.report(), "bx_emit")
    }
    return ok(produced.text)
}

// -------------------------------------------------------------- the walk

/// The walk over one tag.
///
/// Package-private, and stateful only in the two things that have to outlive
/// a node: the imports reached so far and the faults found so far. Everything
/// else is a parameter, so a nested tag is the same call one level down.
class Emitter {
    /// Whether each call goes on a line of its own.
    multiline: bool = false
    /// The import paths the text names so far, in discovery order.
    imports: List<string> = []
    /// Everything found wrong, in source order.
    diags: List<Diag> = []

    fn init(multiline: bool) {
        self.multiline = multiline
    }

    /// One tag as a chain, with its call lines at `depth` levels of four
    /// spaces.
    ///
    /// The constructor is never indented: the caller has already put the
    /// cursor where the expression starts. A tag with no attributes and no
    /// children is therefore one line, `element.div()`, with no gratuitous
    /// break in it.
    fn tag(node: ElementNode, depth: int) -> string {
        let row: TagRow = self.row_for(node)
        var parts: List<string> = []
        parts.push(row.call)
        for a: Attr in node.attrs {
            match self.attr_text(a, row, node.tag) {
                some(call) => { parts.push(self.line(call, depth)) },
                none => {},
            }
        }
        for c: Node in node.children {
            match self.child_text(c, row, node.tag, depth) {
                some(call) => { parts.push(self.line(call, depth)) },
                none => {},
            }
        }
        // A `List<string>` joined at the end: Beans has no `+` for strings
        // and a chain is an unbounded number of pieces (spec/SYNTAX.md,
        // "Strings"). `bx/ast.b` builds its tree dump the same way.
        return parts.join("")
    }

    /// One call, on its own line when the chain is a multi-line one and on
    /// the same line when it is a single expression.
    fn line(call: string, depth: int) -> string {
        if !self.multiline {
            return call
        }
        return "\n{indent4(depth)}{call}"
    }

    /// The row `node.tag` names.
    ///
    /// Two namespaces, and the dot is what tells them apart.
    ///
    /// An **undotted** name is bx's: it has to be in the table, and one that
    /// is not is a diagnostic naming the nearest that is.
    ///
    /// A **dotted** name is the author's. `<ui.Panel>` emits `ui.Panel()` and
    /// bx does not check it, for the same reason `ExprAttr` does not look
    /// inside `{code}`: bx does not know what the driver's file imports,
    /// beansc does, and "no function 'Panel'" from beansc is a better message
    /// than anything bx could invent. bx/lex.b already admits a dot in a tag
    /// name for exactly this, and says so.
    ///
    /// A passed-through tag is taken to be styled and to take children,
    /// because bx cannot know and refusing would make the escape hatch
    /// useless. If it is neither, beansc names the method that is missing.
    ///
    /// An unknown tag still answers a row, so the walk carries on and the
    /// attributes under it get reported in the same run. The text it builds
    /// is not an answer — `Emission.text` says so — but `span()` is at least
    /// a name beansc can point at rather than a marker only bx understands.
    fn row_for(node: ElementNode) -> TagRow {
        if node.tag.contains(".") {
            return self.passthrough(node.tag)
        }
        for row: TagRow in Tags.rows {
            if row.tag == node.tag {
                self.need(row.import_path)
                return row
            }
        }
        let near: string = nearest_name(node.tag, tag_names())
        if near.len() > 0 {
            self.fault(node.span,
                "there is no <{node.tag}> in crema — did you mean <{near}>?")
        } else {
            self.fault(node.span,
                "there is no <{node.tag}> in crema — the tags are {tag_list()}, and a dotted name like <ui.Panel> calls a constructor of your own")
        }
        return self.passthrough(node.tag)
    }

    /// A tag bx does not own, emitted as the nullary call it reads as.
    fn passthrough(tag: string) -> TagRow {
        return TagRow {
            tag: tag, call: "{tag}()", import_path: "",
            styled: true, parent: true, note: "",
        }
    }

    /// One attribute as a call, or `none` with the fault filed.
    ///
    /// The whole of the decision is `bx/attrs.b`'s; this reads the answer and
    /// notes where it came from. The one thing decided here is the tag-level
    /// refusal, because only this file knows which tag the attribute sat on.
    fn attr_text(a: Attr, row: TagRow, tag: string) -> Option<string> {
        if !row.styled {
            self.fault(a.span,
                "<{tag}> takes no attributes — {row.note}. Write <div> to style something")
            return none
        }
        match attr_call(a) {
            ok(call) => {
                self.need_all(attr_imports())
                return some(call)
            },
            err(e) => {
                self.fault(a.span, strip_span(e.msg, a.span))
                return none
            },
        }
    }

    /// One child as a `.child(..)` call, or `none` with the fault filed.
    ///
    /// The `as?` chain is `bx/ast.b`'s design read back: an unrecognised
    /// `Node` subclass is a diagnostic rather than a non-exhaustive match, so
    /// a `<slot>` node added later is a message here and not a compile error
    /// in a file its author never opened. RULES.md measured a miss at 12 ns
    /// native, so the likely arm goes first; the advice to put it last is for
    /// a per-frame chain, and a compiler is not one.
    fn child_text(c: Node, row: TagRow, tag: string, depth: int) -> Option<string> {
        if !row.parent {
            self.fault(c.span,
                "<{tag}> takes no children — {row.note}. Write <div> to hold something")
            return none
        }
        match c as? ElementNode {
            some(el) => { return some(".child({self.tag(el, depth + 1)})") },
            none => {},
        }
        match c as? HoleNode {
            some(h) => {
                if h.code.trim().is_empty() {
                    self.fault(h.span,
                        "an empty \{\} is not a child — put the expression that makes the element inside it")
                    return none
                }
                return some(".child({h.code})")
            },
            none => {},
        }
        match c as? TextNode {
            some(t) => {
                // The one place bx has to say "crema cannot do this yet". See
                // the file header for the evidence; the short version is that
                // `string` does not implement `element.IntoElement` and there
                // is no type in crema that turns one into an element.
                self.fault(t.span,
                    "crema has no text element, so a \"..\" child has nothing to become — gpui's String: IntoElement was dropped (element/element.b). Write the child as \{..\} once there is something to call")
                return none
            },
            none => {},
        }
        self.fault(c.span, "bx has no rule for a {c.kind()} child")
        return none
    }

    /// Note a fault. The walk carries on: a compiler that reports one error
    /// per run makes the author build ten times to find ten mistakes, which
    /// is the same rule bx/parse.b's recoveries are written to.
    fn fault(at: Span, message: string) {
        self.diags.push(Diag.of(at, message))
    }

    /// Record one import path, once.
    fn need(path: string) {
        if path.is_empty() {
            return
        }
        if !self.imports.contains(path) {
            self.imports.push(path)
        }
    }

    /// Record several.
    fn need_all(paths: List<string>) {
        for path: string in paths {
            self.need(path)
        }
    }
}

// -------------------------------------------------------------- small parts

/// `depth` levels of four spaces, the indent generated Beans is written at.
///
/// `bx/ast.b` has `indent`, two spaces, for the tree dump a golden file
/// prints. This is the other one and they are not interchangeable: this text
/// goes into source, so it has to match what a person writing that file by
/// hand would type.
///
/// A negative depth answers "" rather than panicking. `string.repeat` panics
/// on a negative count (spec/SYNTAX.md, "Strings"), and a caller's arithmetic
/// slipping below zero should not take a compiler down with it.
pub fn indent4(depth: int) -> string {
    if depth <= 0 {
        return ""
    }
    return "    ".repeat(depth)
}

/// A table message with its `line:col: ` prefix taken back off.
///
/// `bx/attrs.b` puts the span at the front of every message because a
/// `Result<string>` is the only place it has to put it. A `Diag` carries the
/// span as a field and prints it itself, so leaving the prefix in would print
/// it twice and the two halves of bx would not report in one format. The span
/// is known here, so the prefix is matched exactly rather than searched for.
fn strip_span(message: string, span: Span) -> string {
    let prefix: string = "{span.show()}: "
    if message.starts_with(prefix) {
        return message.slice(prefix.len(), message.len())
    }
    return message
}
