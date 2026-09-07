// ast.b — what a `.bx` file means, as a class hierarchy.
//
// This file is the contract the rest of `bx` is written against: the lexer and
// parser build these, the emitter walks them, and neither knows anything about
// the other. It is deliberately the first file in the package and the only one
// that may not depend on another `bx` file.
//
// A hierarchy rather than an enum, on purpose. An enum would be shorter today
// and would fight us at the first extension: `<slot>`, `<for>`, a desktop-only
// node — each of those is a new variant, and a new variant is a compile error
// in every `match` that ever looked at a `Node`, including the ones a desktop
// crate would own and we would not. A subclass is additive. The emitter
// recovers the concrete type the way `crema.element` recovers `ElementState`,
// with `as?`, and an unrecognised node is a diagnostic rather than a
// non-exhaustive match. `crema.element` made this trade first and for the same
// reason — see the note on `ElementState` in element/frame.b.

package bx

/// Where something sat in the source, one-based, for diagnostics.
///
/// Carried by every token, attribute and node. A parser that loses position
/// can still parse; it just cannot tell anyone what went wrong, and the whole
/// value of a markup language over a fluent chain is that it can point at the
/// line you got wrong.
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
/// Five forms, and the parser decides which by shape alone — it never consults
/// the attribute table. That separation is what lets `bx/attrs.b` change
/// without touching the parser, and it is what makes a misspelled attribute a
/// *table* error naming the nearest real one rather than a parse error.
pub abstract class Attr {
    /// Where it sat.
    pub span: Span = Span {}

    /// Every attribute knows where it came from and nothing else in common.
    pub fn init(span: Span) {
        self.span = span
    }

    /// The attribute's name as written, for diagnostics and for sorting. For
    /// a ramp this is the family without the step (`gap`, not `gap-2`); for a
    /// handler it is the event (`click`, not `on:click`).
    pub abstract fn name() -> string

    /// A one-line form for the golden files.
    pub abstract fn show() -> string
}

/// A bare name with no value: `flex`, `relative`, `truncate`.
///
/// Emits a no-argument call — `.flex()`.
pub class FlagAttr extends Attr {
    /// The attribute as written.
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

/// A family and a Tailwind step: `gap-2`, `p-4`, `w-full`, `rounded-lg`,
/// `mt-1p5`, `m-neg-4`.
///
/// The parser splits on the *last* hyphen run that yields a known step only in
/// the sense that it hands both halves on; deciding whether `gap` is a family
/// and `2` is a step is the table's job, not the parser's. `family` is the
/// text before the split, `step` the text after, both exactly as written.
///
/// Emits the table form — `.gap(style.Gap.s2)`. `docs/FLUENT.md` explains why
/// crema has no `gap_2()` method to call: 3,011 generated methods replaced by
/// three constant tables, at a measured cost of 2 ns.
pub class RampAttr extends Attr {
    /// The family, e.g. `gap`, `mt`, `rounded_tl`. Hyphens inside the family
    /// are already normalised to underscores.
    pub family: string = ""
    /// The step suffix as written, e.g. `2`, `full`, `1p5`, `neg-4`, `lg`.
    pub step: string = ""

    pub fn init(family: string, step: string, span: Span) {
        self.family = family
        self.step = step
        super.init(span)
    }

    pub static fn of(family: string, step: string, span: Span) -> RampAttr {
        return new RampAttr(family, step, span)
    }

    pub override fn name() -> string { return self.family }

    pub override fn show() -> string {
        return "ramp {self.family}={self.step} @{self.span.show()}"
    }
}

/// A name and a string literal: `bg="red"`, `id="row-7"`, `font-family="Inter"`.
///
/// The value is the literal's *contents*, with escapes already resolved. What
/// it becomes is the table's decision: a colour name is resolved to channels at
/// compile time and emitted as a literal, an id is emitted as a string.
pub class TextAttr extends Attr {
    /// The attribute as written, hyphens normalised to underscores.
    pub attr_name: string = ""
    /// The literal's contents, escapes resolved.
    pub value: string = ""

    pub fn init(attr_name: string, value: string, span: Span) {
        self.attr_name = attr_name
        self.value = value
        super.init(span)
    }

    pub static fn of(attr_name: string, value: string, span: Span) -> TextAttr {
        return new TextAttr(attr_name, value, span)
    }

    pub override fn name() -> string { return self.attr_name }

    pub override fn show() -> string {
        return "text {self.attr_name}=\"{self.value}\" @{self.span.show()}"
    }
}

/// A name and a Beans expression: `w={my_width}`, `bg={theme.accent}`.
///
/// `code` is the source between the braces, verbatim, brace-balanced and
/// otherwise unexamined. bx does not parse Beans — beansc does, and it will
/// give a better error than we would. The escape hatch for every attribute the
/// table does not cover, and the reason a missing table entry is never a wall.
pub class ExprAttr extends Attr {
    /// The attribute as written, hyphens normalised to underscores.
    pub attr_name: string = ""
    /// The Beans expression, verbatim, without the braces.
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
        return "expr {self.attr_name}=\{...\} @{self.span.show()}"
    }
}

/// An event and a Beans expression: `on:click={fn(e: input.ClickEvent) { .. }}`.
///
/// Separate from `ExprAttr` because the emitted name is built differently
/// (`click` becomes `on_click`) and because the table validates it against a
/// different list — the `InteractiveElement` handlers, not the `Styled` ones.
/// Keeping them apart is what lets `on:clcik` say "no such event, did you mean
/// click?" instead of "no such style helper".
pub class HandlerAttr extends Attr {
    /// The event as written after `on:`, hyphens normalised to underscores.
    pub event: string = ""
    /// The Beans expression, verbatim, without the braces.
    pub code: string = ""

    pub fn init(event: string, code: string, span: Span) {
        self.event = event
        self.code = code
        super.init(span)
    }

    pub static fn of(event: string, code: string, span: Span) -> HandlerAttr {
        return new HandlerAttr(event, code, span)
    }

    pub override fn name() -> string { return self.event }

    pub override fn show() -> string {
        return "on:{self.event}=\{...\} @{self.span.show()}"
    }
}

// --------------------------------------------------------------------- nodes

/// One node in a `.bx` tree.
pub abstract class Node {
    /// Where it sat.
    pub span: Span = Span {}

    /// Every node knows where it came from.
    pub fn init(span: Span) {
        self.span = span
    }

    /// A short kind name, for diagnostics and goldens.
    pub abstract fn kind() -> string

    /// A tree form for the golden files, indented by `depth` levels of two
    /// spaces. Every subclass prints its own line and then its children.
    pub abstract fn show(depth: int) -> string
}

/// A tag: `<div flex gap-2>...</div>` or `<div flex />`.
pub class ElementNode extends Node {
    /// The tag as written, e.g. `div`. Which Beans constructor that becomes is
    /// the emitter's decision.
    pub tag: string = ""
    /// Its attributes, in source order. Order is preserved because the emitted
    /// chain is order-sensitive: two attributes that write the same
    /// `StyleRefinement` field must land in the order the author wrote them.
    pub attrs: List<Attr> = []
    /// Its children, in source order.
    pub children: List<Node> = []

    pub fn init(tag: string, span: Span) {
        self.tag = tag
        super.init(span)
    }

    pub static fn of(tag: string, span: Span) -> ElementNode {
        return new ElementNode(tag, span)
    }

    pub override fn kind() -> string { return "element" }

    pub override fn show(depth: int) -> string {
        // A `List<string>` joined at the end, because Beans has no `+` for
        // strings (spec/SYNTAX.md, "Strings"). Interpolation covers a fixed
        // number of pieces; a loop needs the list.
        let parts: List<string> = []
        parts.push("{indent(depth)}<{self.tag}> @{self.span.show()}\n")
        for a: Attr in self.attrs {
            parts.push("{indent(depth + 1)}. {a.show()}\n")
        }
        for c: Node in self.children {
            parts.push(c.show(depth + 1))
        }
        return parts.join("")
    }
}

/// An expression in child position: `{inner}`, `{rows.get(i)}`.
///
/// Emits `.child(<code>)`. Like `ExprAttr`, the code is verbatim.
pub class HoleNode extends Node {
    /// The Beans expression, verbatim, without the braces.
    pub code: string = ""

    pub fn init(code: string, span: Span) {
        self.code = code
        super.init(span)
    }

    pub static fn of(code: string, span: Span) -> HoleNode {
        return new HoleNode(code, span)
    }

    pub override fn kind() -> string { return "hole" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}\{{self.code}\} @{self.span.show()}\n"
    }
}

/// A string literal in child position: `"Count: {n}"`.
///
/// The contents are kept with escapes *unresolved*, because a Beans string
/// literal is what gets emitted and Beans resolves its own escapes — resolving
/// them here and re-escaping them there is two chances to get it wrong for no
/// gain. Beans interpolation (`{n}`) therefore passes straight through and
/// works, which is the whole reason to allow a literal child at all.
pub class TextNode extends Node {
    /// The literal's contents, escapes unresolved, without the quotes.
    pub raw: string = ""

    pub fn init(raw: string, span: Span) {
        self.raw = raw
        super.init(span)
    }

    pub static fn of(raw: string, span: Span) -> TextNode {
        return new TextNode(raw, span)
    }

    pub override fn kind() -> string { return "text" }

    pub override fn show(depth: int) -> string {
        return "{indent(depth)}\"{self.raw}\" @{self.span.show()}\n"
    }
}

/// `depth` levels of two spaces.
pub fn indent(depth: int) -> string {
    return "  ".repeat(depth)
}
