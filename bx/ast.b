// ast.b — what a `.bx` file means, as a class hierarchy.
//
// This file is the contract the rest of `latte.bx` is written against: the
// lexer and parser build these, the emitter walks them, and neither knows
// anything about the other. It is the first file in the package and the only
// one that may not depend on another file in it.
//
// A hierarchy rather than an enum, kept from crema for the reason crema gave:
// an enum would be shorter today and would fight us at the first extension.
// `$slot`, a `live` subtree, a desktop-only node — each is a new variant, and
// a new variant is a compile error in every `match` that ever looked at a
// `Node`. A subclass is additive. The emitter recovers the concrete type with
// `as?`, and an unrecognised node is a diagnostic rather than a non-exhaustive
// match.
//
// What changed from crema's version: `RampAttr` and the colour table are gone
// (latte passes `class` through untouched), and the block nodes latte's markup
// language actually has — `$if`, `$for`, `$match`, `${}`, `$slot`, `$html`,
// `<beans>` — are here instead.

package bx

/// Where something sat in the source, one-based, for diagnostics.
///
/// Carried by every token, attribute and node. A parser that loses position
/// can still parse; it just cannot tell anyone what went wrong, and the whole
/// value of a markup language over hand-written builder calls is that it can
/// point at the line you got wrong.
pub struct Span {
    /// One-based line.
    pub line: int = 1
    /// One-based column, counted in bytes, not glyphs.
    pub col: int = 1

    /// The span at a line and column.
    pub static fn at(line: int, col: int) -> Span {
        return Span { line: line, col: col }
    }

    /// `line:col`, the form every diagnostic in the toolchain uses.
    pub fn show() -> string {
        return "{self.line}:{self.col}"
    }
}

// ---------------------------------------------------------------- attributes

/// One attribute on a tag.
///
/// Nine forms, and the parser decides which by shape alone — it never consults
/// the HTML tables. That separation is what lets `html.b` change without
/// touching the parser.
pub abstract class Attr {
    /// Where it sat.
    pub span: Span = Span {}

    pub fn init(span: Span) {
        self.span = span
    }

    /// The attribute's name as written, for diagnostics. For a handler it is
    /// the event (`click`, not `on:click`); for a binding it is the target
    /// (`value`, not `bind:value.int`).
    pub abstract fn name() -> string

    /// A one-line form for the golden files.
    pub abstract fn show() -> string
}

/// `class="counter"` — a literal attribute, passed through byte for byte.
///
/// `value` has HTML character references already resolved, because it is
/// re-escaped on the way out and resolving twice would double-encode. See
/// `resolve_references` in html.b.
pub class LiteralAttr extends Attr {
    pub attr_name: string = ""
    pub value: string = ""

    pub fn init(attr_name: string, value: string, span: Span) {
        self.attr_name = attr_name
        self.value = value
        super.init(span)
    }

    pub static fn of(attr_name: string, value: string, span: Span) -> LiteralAttr {
        return new LiteralAttr(attr_name, value, span)
    }

    pub override fn name() -> string { return self.attr_name }

    pub override fn show() -> string {
        return "lit {self.attr_name}=\"{self.value}\" @{self.span.show()}"
    }
}

/// `href={self.url}` — an expression attribute, escaped for attribute context.
///
/// `code` is the source between the braces, verbatim, brace-balanced and
/// otherwise unexamined. latte-bx does not parse Beans — beansc does, and it
/// gives a better error than a guess from here would.
pub class ExprAttr extends Attr {
    pub attr_name: string = ""
    pub code: string = ""

    pub fn init(attr_name: string, code: string, span: Span) {
        self.attr_name = attr_name
        self.code = code
        super.init(span)
    }

    pub static fn of(attr_name: string, code: string, span: Span) -> ExprAttr {
        return new ExprAttr(attr_name, code, span)
    }

    pub override fn name() -> string { return self.attr_name }

    pub override fn show() -> string {
        return "expr {self.attr_name}=\{{self.code}\} @{self.span.show()}"
    }
}

/// `disabled` — a bare name, present or absent.
pub class FlagAttr extends Attr {
    pub attr_name: string = ""

    pub fn init(attr_name: string, span: Span) {
        self.attr_name = attr_name
        super.init(span)
    }

    pub static fn of(attr_name: string, span: Span) -> FlagAttr {
        return new FlagAttr(attr_name, span)
    }

    pub override fn name() -> string { return self.attr_name }

    pub override fn show() -> string {
        return "flag {self.attr_name} @{self.span.show()}"
    }
}

/// `on:click={fn(e: MouseEvent) { ... }}` — a DOM event.
///
/// Separate from `ExprAttr` because the emitted name is built differently
/// (`click` becomes `on_click`) and because it is validated against the event
/// table rather than passed through. Keeping them apart is what lets
/// `on:clcik` say "no such event, did you mean click?".
pub class EventAttr extends Attr {
    pub event: string = ""
    pub code: string = ""

    pub fn init(event: string, code: string, span: Span) {
        self.event = event
        self.code = code
        super.init(span)
    }

    pub static fn of(event: string, code: string, span: Span) -> EventAttr {
        return new EventAttr(event, code, span)
    }

    pub override fn name() -> string { return self.event }

    pub override fn show() -> string {
        return "on:{self.event}=\{{self.code}\} @{self.span.show()}"
    }
}

/// `bind:value={self.note}`, `bind:value.int={self.n}`, `bind:checked={self.on}`.
///
/// One attribute that becomes two frames: the value out, and the handler that
/// writes it back. `modifier` carries the conversion, because the compiler
/// does not know the field's type.
pub class BindAttr extends Attr {
    /// `value` or `checked`.
    pub target: string = ""
    /// `""`, `int`, `float` or `bool`.
    pub modifier: string = ""
    /// The place to write back to.
    pub code: string = ""

    pub fn init(target: string, modifier: string, code: string, span: Span) {
        self.target = target
        self.modifier = modifier
        self.code = code
        super.init(span)
    }

    pub static fn of(target: string, modifier: string, code: string, span: Span) -> BindAttr {
        return new BindAttr(target, modifier, code, span)
    }

    pub override fn name() -> string { return self.target }

    pub override fn show() -> string {
        if self.modifier == "" {
            return "bind:{self.target}=\{{self.code}\} @{self.span.show()}"
        }
        return "bind:{self.target}.{self.modifier}=\{{self.code}\} @{self.span.show()}"
    }
}

/// `key={row.id}` — list identity, hoisted onto the enclosing `$for`'s region.
pub class KeyAttr extends Attr {
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> KeyAttr {
        return new KeyAttr(code, span)
    }

    pub override fn name() -> string { return "key" }

    pub override fn show() -> string {
        return "key=\{{self.code}\} @{self.span.show()}"
    }
}

/// `ref={self.input}` — a handle to the element or child, filled in after render.
pub class RefAttr extends Attr {
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> RefAttr {
        return new RefAttr(code, span)
    }

    pub override fn name() -> string { return "ref" }

    pub override fn show() -> string {
        return "ref=\{{self.code}\} @{self.span.show()}"
    }
}

/// `attrs={extra}` — splat a `Map<string, string>` of pass-through attributes.
pub class SplatAttr extends Attr {
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> SplatAttr {
        return new SplatAttr(code, span)
    }

    pub override fn name() -> string { return "attrs" }

    pub override fn show() -> string {
        return "attrs=\{{self.code}\} @{self.span.show()}"
    }
}

/// `preserve` — render this subtree once and never diff into it.
pub class PreserveAttr extends Attr {
    pub fn init(span: Span) {
        super.init(span)
    }

    pub static fn of(span: Span) -> PreserveAttr {
        return new PreserveAttr(span)
    }

    pub override fn name() -> string { return "preserve" }

    pub override fn show() -> string {
        return "preserve @{self.span.show()}"
    }
}

// --------------------------------------------------------------------- nodes

/// One node in a `.bx` tree.
pub abstract class Node {
    /// Where it sat.
    pub span: Span = Span {}

    pub fn init(span: Span) {
        self.span = span
    }

    /// A short kind name, for diagnostics and goldens.
    pub abstract fn kind() -> string

    /// A tree form for the golden files, indented by `depth` levels of two
    /// spaces. Every subclass prints its own line and then its children.
    pub abstract fn show(depth: int) -> string
}

/// A tag: `<div class="a">...</div>`, `<br />`, or `<Hint text="hi" />`.
///
/// One class for both an HTML element and a component tag, because everything
/// but the emission is identical: the same attribute grammar, the same
/// children, the same close rules. `component` says which, and it is decided
/// by the tag's spelling (see `names_a_component` in html.b), not by a table
/// of known types — there is no component registry and none is needed.
pub class ElementNode extends Node {
    /// The tag as written, e.g. `div`, `Hint`, `ui.Button`.
    pub tag: string = ""
    /// Its attributes, in source order. Order is preserved because the frames
    /// are ordered and a serializer writes them in the order it is given.
    pub attrs: List<Attr> = []
    /// Its children, in source order.
    pub children: List<Node> = []
    /// Whether the tag named a component rather than an HTML element.
    pub component: bool = false
    /// Whether it was written `<br />` rather than `<br></br>`.
    pub self_closed: bool = false

    pub fn init(tag: string, component: bool, span: Span) {
        self.tag = tag
        self.component = component
        super.init(span)
    }

    pub static fn of(tag: string, component: bool, span: Span) -> ElementNode {
        return new ElementNode(tag, component, span)
    }

    pub override fn kind() -> string {
        if self.component { return "component" }
        return "element"
    }

    pub override fn show(depth: int) -> string {
        // A `List<string>` joined at the end, because Beans has no `+` for
        // strings. Interpolation covers a fixed number of pieces; a loop
        // needs the list.
        let parts: List<string> = []
        parts.push("{indent(depth)}<{self.tag}> {self.kind()} @{self.span.show()}\n")
        for a: Attr in self.attrs {
            parts.push("{indent(depth + 1)}. {a.show()}\n")
        }
        for c: Node in self.children {
            parts.push(c.show(depth + 1))
        }
        return parts.join("")
    }
}

/// Literal text between tags.
///
/// `text` holds the characters the author meant: whitespace already
/// normalised, character references already resolved, `\}` already unescaped.
/// It is *not* HTML — the serializer escapes it, so a `<` in here is a less
/// than sign and will leave as `&lt;`.
pub class TextNode extends Node {
    pub text: string = ""

    pub fn init(text: string, span: Span) {
        self.text = text
        super.init(span)
    }

    pub static fn of(text: string, span: Span) -> TextNode {
        return new TextNode(text, span)
    }

    pub override fn kind() -> string { return "text" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}text \"{self.text}\" @{self.span.show()}\n"
    }
}

/// The body of a `<script>` or `<style>`: text that is not escaped.
///
/// A raw-text element's content is not HTML text — `<` in a script is a
/// less-than sign to JavaScript and escaping it would break the program. It
/// reaches the frame stream as `constant`, which is the trusted path and is
/// correct here because the bytes are the author's literal source with no
/// expression in them: interpolation inside a `<script>` is refused at parse
/// time, so there is nothing in one that a value could reach.
pub class RawTextNode extends Node {
    pub text: string = ""

    pub fn init(text: string, span: Span) {
        self.text = text
        super.init(span)
    }

    pub static fn of(text: string, span: Span) -> RawTextNode {
        return new RawTextNode(text, span)
    }

    pub override fn kind() -> string { return "rawtext" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}rawtext {self.text.len()} bytes @{self.span.show()}\n"
    }
}

/// `<!DOCTYPE html>`.
///
/// Its own node because it is neither an element nor text, and because a
/// layout component genuinely needs one: a page whose shell has no doctype is
/// a page in quirks mode, which is a rendering difference nobody would trace
/// back to the markup compiler. It is constant by construction and folds into
/// an enclosing constant subtree like anything else.
pub class DoctypeNode extends Node {
    /// The declaration exactly as written, angle brackets and all.
    pub text: string = ""

    pub fn init(text: string, span: Span) {
        self.text = text
        super.init(span)
    }

    pub static fn of(text: string, span: Span) -> DoctypeNode {
        return new DoctypeNode(text, span)
    }

    pub override fn kind() -> string { return "doctype" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}doctype {self.text} @{self.span.show()}\n"
    }
}

/// `$self.count` or `$(self.a + self.b)` — an escaped expression.
pub class ExprNode extends Node {
    /// The Beans expression, verbatim, without any `$` or parentheses.
    pub code: string = ""
    /// `implicit` for `$self.count`, `explicit` for `$(...)`. Kept for the
    /// goldens: the two forms must produce the same frame, and a golden that
    /// shows which form was written is what proves it.
    pub form: string = "implicit"

    pub fn init(code: string, form: string, span: Span) {
        self.code = code
        self.form = form
        super.init(span)
    }

    pub static fn of(code: string, form: string, span: Span) -> ExprNode {
        return new ExprNode(code, form, span)
    }

    pub override fn kind() -> string { return "expr" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}{self.form} \{{self.code}\} @{self.span.show()}\n"
    }
}

/// `$html(self.rendered)` — raw HTML, unescaped. The only bypass there is.
pub class RawHtmlNode extends Node {
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> RawHtmlNode {
        return new RawHtmlNode(code, span)
    }

    pub override fn kind() -> string { return "html" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}html \{{self.code}\} @{self.span.show()}\n"
    }
}

/// One arm of a `$if`: a header and a body. An `else` arm has an empty header.
pub class Branch {
    pub span: Span = Span {}
    /// The Beans condition, verbatim. Empty for the final `else`.
    pub header: string = ""
    pub body: List<Node> = []

    pub fn init(header: string, span: Span) {
        self.header = header
        self.span = span
    }

    pub static fn of(header: string, span: Span) -> Branch {
        return new Branch(header, span)
    }
}

/// `$if c { } else if d { } else { }`.
pub class IfNode extends Node {
    pub branches: List<Branch> = []

    pub fn init(span: Span) {
        super.init(span)
    }

    pub static fn of(span: Span) -> IfNode {
        return new IfNode(span)
    }

    pub override fn kind() -> string { return "if" }

    pub override fn show(depth: int) -> string {
        let parts: List<string> = []
        parts.push("{indent(depth)}if @{self.span.show()}\n")
        for b: Branch in self.branches {
            if b.header == "" {
                parts.push("{indent(depth + 1)}else @{b.span.show()}\n")
            } else {
                parts.push("{indent(depth + 1)}when \{{b.header}\} @{b.span.show()}\n")
            }
            for c: Node in b.body {
                parts.push(c.show(depth + 2))
            }
        }
        return parts.join("")
    }
}

/// `$for row: Row in self.rows { }` — Beans' one loop keyword, all five shapes.
///
/// The body is always wrapped in a region, because a loop body is emitted once
/// and rendered many times: without a region the same sequence number would
/// name every row.
pub class ForNode extends Node {
    /// The loop header, verbatim — everything between `$for` and the `{`.
    pub header: string = ""
    pub body: List<Node> = []

    pub fn init(header: string, span: Span) {
        self.header = header
        super.init(span)
    }

    pub static fn of(header: string, span: Span) -> ForNode {
        return new ForNode(header, span)
    }

    pub override fn kind() -> string { return "for" }

    pub override fn show(depth: int) -> string {
        let parts: List<string> = []
        parts.push("{indent(depth)}for \{{self.header}\} @{self.span.show()}\n")
        for c: Node in self.body {
            parts.push(c.show(depth + 1))
        }
        return parts.join("")
    }
}

/// One arm of a `$match`: a pattern and a body.
pub class MatchArm {
    pub span: Span = Span {}
    /// The pattern, verbatim, without the `=>`.
    pub pattern: string = ""
    pub body: List<Node> = []

    pub fn init(pattern: string, span: Span) {
        self.pattern = pattern
        self.span = span
    }

    pub static fn of(pattern: string, span: Span) -> MatchArm {
        return new MatchArm(pattern, span)
    }
}

/// `$match v { some(x) => { } none => { } }`.
pub class MatchNode extends Node {
    /// The subject, verbatim — everything between `$match` and the `{`.
    pub header: string = ""
    pub arms: List<MatchArm> = []

    pub fn init(header: string, span: Span) {
        self.header = header
        super.init(span)
    }

    pub static fn of(header: string, span: Span) -> MatchNode {
        return new MatchNode(header, span)
    }

    pub override fn kind() -> string { return "match" }

    pub override fn show(depth: int) -> string {
        let parts: List<string> = []
        parts.push("{indent(depth)}match \{{self.header}\} @{self.span.show()}\n")
        for a: MatchArm in self.arms {
            parts.push("{indent(depth + 1)}arm \{{a.pattern}\} @{a.span.show()}\n")
            for c: Node in a.body {
                parts.push(c.show(depth + 2))
            }
        }
        return parts.join("")
    }
}

/// `${ let total: int = a + b }` — statements, copied verbatim, no markup inside.
pub class CodeNode extends Node {
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> CodeNode {
        return new CodeNode(code, span)
    }

    pub override fn kind() -> string { return "code" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}code \{{self.code}\} @{self.span.show()}\n"
    }
}

/// A `$slot` in one of its five forms.
///
/// | written | `mode` | means |
/// |---|---|---|
/// | `$slot` | `place` | place `self.body` |
/// | `$slot(expr)` | `place_expr` | place the `fn(Builder)` that `expr` answers |
/// | `$slot:name` | `place` | place `self.name` |
/// | `$slot:name as expr` | `place_arg` | place `self.name`, passing `expr` |
/// | `$slot:name as x: T { ... }` | `define` | supply `name` at a component tag |
///
/// A `define` is only legal as a direct child of a component tag; every other
/// form is only legal inside the component that declares the slot. A body is
/// what tells them apart, which is why the parser decides on the body and not
/// on the punctuation.
pub class SlotNode extends Node {
    /// `place`, `place_expr`, `place_arg` or `define`.
    pub mode: string = "place"
    /// The slot's field name. Empty means `body`, the default child content.
    pub slot_name: string = ""
    /// For `place_expr`, the fragment expression; for `place_arg`, the
    /// argument to pass. Empty otherwise.
    pub code: string = ""
    /// For `define`, the parameter's name. Empty for a zero-argument template.
    pub param_name: string = ""
    /// For `define`, the parameter's Beans type.
    pub param_type: string = ""
    /// For `define`, the template's markup.
    pub body: List<Node> = []

    pub fn init(mode: string, slot_name: string, span: Span) {
        self.mode = mode
        self.slot_name = slot_name
        super.init(span)
    }

    pub static fn of(mode: string, slot_name: string, span: Span) -> SlotNode {
        return new SlotNode(mode, slot_name, span)
    }

    /// The field this slot reads or writes: `body` when none was named.
    pub fn field() -> string {
        if self.slot_name == "" { return "body" }
        return self.slot_name
    }

    pub override fn kind() -> string { return "slot" }

    pub override fn show(depth: int) -> string {
        let parts: List<string> = []
        let head: string = "{indent(depth)}slot {self.mode} {self.field()}"
        if self.mode == "define" {
            if self.param_name == "" {
                parts.push("{head} @{self.span.show()}\n")
            } else {
                parts.push("{head} as {self.param_name}: {self.param_type} @{self.span.show()}\n")
            }
            for c: Node in self.body {
                parts.push(c.show(depth + 1))
            }
            return parts.join("")
        }
        if self.code == "" {
            return "{head} @{self.span.show()}\n"
        }
        return "{head} \{{self.code}\} @{self.span.show()}\n"
    }
}

/// The `<beans>` block: Beans source, copied through byte for byte.
///
/// A raw-text element the way `<script>` is in HTML, so nothing inside it is
/// markup and nothing inside it is scanned. A `$`, a `<` or a brace in there
/// is just Beans.
pub class BeansNode extends Node {
    /// Everything between `<beans>` and `</beans>`, verbatim.
    pub code: string = ""
    /// Where `code` starts in the whole file, in bytes.
    ///
    /// The span says where the `<beans>` tag is; this says where its content
    /// is, and the difference matters because every diagnostic about the
    /// author's own Beans is found at an offset inside `code` and has to be
    /// reported at a line number in the file they are looking at.
    pub start: int = 0

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> BeansNode {
        return new BeansNode(code, span)
    }

    pub override fn kind() -> string { return "beans" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}beans {self.code.len()} bytes @{self.span.show()}\n"
    }
}

/// `depth` levels of two spaces.
pub fn indent(depth: int) -> string {
    return "  ".repeat(depth)
}
