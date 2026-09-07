// parse.b — tokens to `Node`, and every diagnostic on the way.
//
// Not a translation of anything; gpui has no markup layer. This is the second
// half of the `bx` front end. `lex.b` decides where a name, a `"..."` and a
// `{...}` start and stop; this file decides what they mean, and it decides it
// by *shape alone*. It never consults the attribute table, never resolves a
// colour and never looks at a tag name to see whether crema has such an
// element. That separation is what lets `bx/attrs.b` grow without touching
// this file, and it is what makes `bg="rd"` a table error that names the
// nearest real colour instead of a parse error that names nothing.
//
// **The split rule for ramp attributes**, because it is the one real decision
// in the file and a wrong guess is silent:
//
//   Split the name on hyphens. The **step** is the last segment, extended
//   leftwards over any immediately preceding `neg` segments. Everything to
//   the left is the **family**, with its hyphens turned into underscores. A
//   name with no hyphen at all is not a ramp — it is a flag.
//
//   gap-2         -> gap / 2              mt-1p5        -> mt / 1p5
//   w-full        -> w / full             rounded-lg    -> rounded / lg
//   border-t-2    -> border_t / 2         gap-x-4       -> gap_x / 4
//   rounded-tl-lg -> rounded_tl / lg      w-1/2         -> w / 1/2
//   m-neg-4       -> m / neg-4
//
// The obvious rule — "the first hyphen followed by something a step could
// start with" — gets `border-t-2` wrong, because `t` looks exactly like a
// step and is in fact half the family. Taking the *last* hyphen instead gets
// every one of those right and fails on exactly one case, `m-neg-4`, where
// the negative marker is part of the step. So the rule is "last hyphen, minus
// the `neg` markers", which is one sentence and covers all nine. Every case
// above is in the golden.
//
// Note what is deliberately *not* decided here: whether `border_t` is a real
// family, whether `1/2` is a real step, or whether the two go together. That
// is `bx/attrs.b`'s job, and the parser handing on a family and a step it
// cannot vouch for is the point — a table that owns validity can say "no such
// step `1p6`, did you mean `1p5`?", and a parser that owned it could not.
//
// **Errors accumulate.** A parser that reports one fault per run makes the
// author compile ten times to find ten mistakes, so every recovery path here
// either consumes at least one token or ends the tag, and a fault never stops
// the walk. Two recoveries are worth naming:
//
//   * A close tag that names an *enclosing* open tag is not consumed by the
//     element that read it. `<a><b><c></a>` unwinds through `c` and `b`,
//     reporting each one, and `a` takes the close — three tags, two
//     diagnostics, one correct tree.
//   * A close tag that names nothing open at all is taken as closing the
//     current element, because that is nearly always what was meant. One
//     diagnostic naming both tags, and the rest of the file still parses.

package bx

// -------------------------------------------------------------- the result

/// What one `parse_tag` found: the tree, where the tag ended, and everything
/// wrong with it.
///
/// `end` is a byte offset into the source the caller handed in, pointing just
/// past the tag's last `>`. A driver walking a `.bx` file copies the opaque
/// Beans up to the `<`, emits the tag, and resumes at `end`.
pub class TagParse {
    /// The tag, or `none` when there was not enough of one to build.
    pub root: Option<ElementNode> = none
    /// The byte offset just past the tag.
    pub end: int = 0
    /// Everything found wrong, in source order.
    pub diags: List<Diag> = []

    /// Whether nothing was found wrong. A `none` root always reports, so a
    /// clean parse always has a tree.
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

/// Parse the tag that starts at byte `from`.
///
/// `from` must be at the `<`; finding it is the driver's job, because only
/// the driver knows which `<` in a `.bx` file opens a tag and which one is a
/// less-than in the Beans around it.
pub fn parse_tag(source: string, from: int) -> TagParse {
    return parse_with(Lexer.at(source, from))
}

/// The same, for a driver that scanned the file itself and already knows the
/// line and column of `from`. Saves a pass over everything before it.
pub fn parse_tag_at(source: string, from: int, line: int, col: int) -> TagParse {
    let lex: Lexer = new Lexer(source)
    lex.seek_at(from, line, col)
    return parse_with(lex)
}

/// The one tag in `source`, for a caller that wants a value or a message and
/// has no use for offsets.
///
/// Every diagnostic goes into the message, one per line: a `Result` carries
/// one `Error`, and losing the other nine would undo the whole reason the
/// parser accumulates them.
pub fn parse_one(source: string) -> Result<ElementNode> {
    let parsed: TagParse = parse_tag(source, 0)
    if !parsed.is_ok() {
        return err(parsed.report(), "bx_parse")
    }
    var i: int = parsed.end
    for i < source.len() {
        if !is_space_byte(source.byte_at(i) as int) {
            let trailing: Span = span_of(source, i)
            let where: string = trailing.show()
            return err("{where}: error: there is more than one tag here — parse_one takes exactly one, use parse_tag to walk a file", "bx_parse")
        }
        i = i + 1
    }
    return match parsed.root {
        some(el) => ok(el),
        none => err("there is no tag in this source — a bx expression starts with <", "bx_parse"),
    }
}

/// Drive a lexer that is already positioned.
fn parse_with(lex: Lexer) -> TagParse {
    let parser: Parser = new Parser(lex)
    let out: TagParse = new TagParse()
    out.root = parser.parse_top()
    out.end = parser.last_end
    out.diags = lex.diags.clone()
    return out
}

// -------------------------------------------------------- ramp attributes

/// A family and a step, split out of a hyphenated attribute name.
///
/// A struct, not a class: two strings, copied once, no identity. See RULES.md,
/// "Value type or class?".
pub struct RampSplit {
    /// The family, hyphens already normalised to underscores — `border_t`.
    pub family: string = ""
    /// The step exactly as written — `2`, `neg-4`, `1/2`. The table
    /// normalises it; the parser must not, because only the table knows
    /// whether `1p5` and `1_5` are the same step.
    pub step: string = ""
}

/// Split a hyphenated attribute name into a family and a step.
///
/// The rule is stated in full at the top of this file. In one line: the step
/// is the last hyphen-separated segment, plus any `neg` markers immediately
/// in front of it; the family is everything else, underscored.
pub fn split_ramp(name: string) -> RampSplit {
    let parts: List<string> = name.split("-")
    var cut: int = parts.len() - 1
    // Walk left over `neg` markers, but never past the first segment: a ramp
    // always has a family, even when the author wrote a strange one.
    for cut > 1 {
        match parts.get(cut - 1) {
            some(segment) => {
                if segment != "neg" {
                    break
                }
                cut = cut - 1
            }
            none => { break }
        }
    }
    let dash: string = "-"
    let family: List<string> = parts.slice(0, cut)
    let step: List<string> = parts.slice(cut, parts.len())
    return RampSplit { family: underscored(family.join(dash)), step: step.join(dash) }
}

/// Hyphens become underscores.
///
/// Every name this package hands on ends up in a Beans call — `.font_family(..)`,
/// `.on_click(..)` — and `font-family` is not a Beans identifier. The *step*
/// is never put through this, because a step's hyphen is meaningful (`neg-4`)
/// and the table is what turns it into a name.
pub fn underscored(name: string) -> string {
    return name.replace("-", "_")
}

/// The line and column of byte `at`, counted from the top of `source`.
fn span_of(source: string, at: int) -> Span {
    let lex: Lexer = Lexer.at(source, at)
    return lex.span()
}

// -------------------------------------------------------------- the parser

/// The recursive-descent parser over one tag.
///
/// Package-private: `parse_tag` is the whole public surface, because a caller
/// holding a half-driven parser could read past the tag it asked for, and
/// reading past a tag means reading Beans this package must not touch.
///
/// The one-token lookahead is **lazy** for that reason. An eager one would
/// fetch the token after the tag's last `>`, which is opaque Beans, and could
/// invent a diagnostic — an unterminated string, say — in code `bx` never
/// looks at. Nothing is lexed until a decision needs it.
class Parser {
    /// The token source, and the owner of the diagnostic list.
    lex: Lexer
    /// The token that has been read but not consumed, if any.
    pending: Option<Token> = none
    /// The tags currently open, outermost first. A close tag that names one
    /// of these belongs to an ancestor, not to the element that read it.
    open_tags: List<string> = []
    /// A close tag that was consumed by an element it does not close. Every
    /// element unwinds until the one it names takes it. Empty when nothing is
    /// unwinding.
    unwind: string = ""
    /// The byte offset just past the last consumed token.
    last_end: int = 0

    fn init(lex: Lexer) {
        self.lex = lex
        self.last_end = lex.off
    }

    /// The token under the cursor, lexing it if it has not been read yet.
    fn look() -> Token {
        match self.pending {
            some(t) => { return t }
            none => {}
        }
        let fresh: Token = self.lex.next_token()
        self.pending = some(fresh)
        return fresh
    }

    /// Consume the token under the cursor.
    fn eat() {
        let t: Token = self.look()
        self.last_end = t.end
        self.pending = none
    }

    /// Note a fault.
    fn fault(at: Span, message: string) {
        self.lex.report(at, message)
    }

    /// Whether `tag` is one of the tags currently open.
    ///
    /// Written as a loop rather than `List.contains` on purpose: RULES.md's
    /// standing rule is that a reference-typed `==` inside a collection
    /// helper is the shape several backend faults took, and a four-line loop
    /// over a handful of open tags costs nothing and cannot be one of them.
    fn is_open(tag: string) -> bool {
        for open: string in self.open_tags {
            if open == tag {
                return true
            }
        }
        return false
    }

    /// The whole entry point: one tag, starting at the cursor.
    fn parse_top() -> Option<ElementNode> {
        let t: Token = self.look()
        if t.kind != TokenKind.open_start {
            self.fault(t.span, "a bx tag starts with < — found {t.describe()}")
            return none
        }
        return self.parse_element()
    }

    /// One element, from its `<` to its `/>` or its `</name>`.
    fn parse_element() -> Option<ElementNode> {
        let open: Span = self.look().span
        self.eat()
        let head: Token = self.look()
        if head.kind != TokenKind.name {
            self.fault(head.span, "< has no tag name after it — write <div ...> or <br />")
            return none
        }
        let el: ElementNode = ElementNode.of(head.value, open)
        self.eat()
        self.parse_attrs(el)
        let shut: Token = self.look()
        if shut.kind == TokenKind.self_close {
            self.eat()
            return some(el)
        }
        if shut.kind != TokenKind.tag_end {
            self.fault(open, "<{el.tag} was never finished — add > to open it, or /> to close it")
            return some(el)
        }
        self.eat()
        self.parse_children(el)
        return some(el)
    }

    /// Every attribute up to the `>` or `/>` that ends the open tag.
    fn parse_attrs(el: ElementNode) {
        for {
            let t: Token = self.look()
            if t.kind == TokenKind.name {
                self.parse_attr(el)
                continue
            }
            if t.kind == TokenKind.equals {
                self.fault(t.span, "a stray = — a value belongs to the attribute name in front of it")
                self.eat()
                continue
            }
            if t.kind == TokenKind.text {
                self.attr_junk(el, t)
                continue
            }
            if t.kind == TokenKind.code {
                self.attr_junk(el, t)
                continue
            }
            if t.kind == TokenKind.unknown {
                self.attr_junk(el, t)
                continue
            }
            // `>`, `/>`, `<`, `</` and the end of the file all end the run of
            // attributes. The caller decides which of them was legal.
            break
        }
    }

    /// Report a token that cannot be an attribute, and step over it.
    fn attr_junk(el: ElementNode, t: Token) {
        self.fault(t.span, "{t.describe()} is not an attribute of <{el.tag}> — an attribute is a name, name=\"text\" or name=\{expr\}")
        self.eat()
    }

    /// One attribute: a name, then optionally `=` and a value.
    fn parse_attr(el: ElementNode) {
        let head: Token = self.look()
        let name: string = head.value
        let at: Span = head.span
        self.eat()
        if self.look().kind != TokenKind.equals {
            self.bare_attr(el, name, at)
            return
        }
        self.eat()
        let value: Token = self.look()
        if value.kind == TokenKind.code {
            self.eat()
            self.code_attr(el, name, at, value.value)
            return
        }
        if value.kind == TokenKind.text {
            self.eat()
            self.text_attr(el, name, at, value.value)
            return
        }
        // Do not consume: whatever it is, the attribute loop knows what to do
        // with it and this way `<div gap= >` still finds the `>`.
        self.fault(at, "{name}= has no value — write {name}=\"text\" or {name}=\{expr\}")
    }

    /// `flex`, `gap-2` — a name with no value.
    fn bare_attr(el: ElementNode, name: string, at: Span) {
        if name.starts_with("on:") {
            self.fault(at, "{name} has no value — write {name}=\{fn(e: input.ClickEvent) \{ .. \}\}")
            return
        }
        if !self.plain_name(name, at) {
            return
        }
        if !name.contains("-") {
            el.attrs.push(FlagAttr.of(name, at))
            return
        }
        let split: RampSplit = split_ramp(name)
        if split.step.is_empty() {
            self.fault(at, "{name} has an empty step — write a step after the hyphen, as in gap-2")
        }
        el.attrs.push(RampAttr.of(split.family, split.step, at))
    }

    /// `bg="red"` — a name and a string literal.
    ///
    /// The value carries the *resolved* escapes, because what reads it next
    /// is the attribute table at compile time, not a Beans literal. A
    /// `TextNode` keeps the raw form instead, and ast.b says why.
    fn text_attr(el: ElementNode, name: string, at: Span, value: string) {
        if name.starts_with("on:") {
            self.fault(at, "{name} needs a \{code\} value, not a string — write {name}=\{fn(e: input.ClickEvent) \{ .. \}\}")
            return
        }
        if !self.plain_name(name, at) {
            return
        }
        el.attrs.push(TextAttr.of(underscored(name), value, at))
    }

    /// `w={expr}` or `on:click={...}` — a name and Beans code.
    fn code_attr(el: ElementNode, name: string, at: Span, code: string) {
        if !name.starts_with("on:") {
            if !self.plain_name(name, at) {
                return
            }
            el.attrs.push(ExprAttr.of(underscored(name), code, at))
            return
        }
        let event: string = name.slice(3, name.len())
        if event.is_empty() {
            self.fault(at, "on: has no event name after it — write on:click=\{fn(e: input.ClickEvent) \{ .. \}\}")
            return
        }
        el.attrs.push(HandlerAttr.of(underscored(event), code, at))
    }

    /// Whether an attribute name carries no namespace. `on:` is handled by
    /// its callers before they get here, so any surviving `:` is a namespace
    /// bx does not have.
    fn plain_name(name: string, at: Span) -> bool {
        if !name.contains(":") {
            return true
        }
        self.fault(at, "{name} is not an attribute — on: is the only namespace bx knows")
        return false
    }

    /// Every child up to the close tag, and the close tag itself.
    fn parse_children(el: ElementNode) {
        self.open_tags.push(el.tag)
        for {
            if !self.unwind.is_empty() {
                // Something below us read a close tag belonging to an
                // ancestor. Either it is ours, or we are one more unclosed
                // tag between it and its owner.
                if self.unwind == el.tag {
                    self.unwind = ""
                } else {
                    self.fault(el.span, "<{el.tag}> was never closed — add </{el.tag}> before </{self.unwind}>")
                }
                break
            }
            let t: Token = self.look()
            if t.kind == TokenKind.eof {
                self.fault(el.span, "<{el.tag}> was never closed — add </{el.tag}>")
                break
            }
            if t.kind == TokenKind.close_start {
                if self.take_close(el) {
                    break
                }
                continue
            }
            if t.kind == TokenKind.open_start {
                match self.parse_element() {
                    some(child) => { el.children.push(child) }
                    none => {}
                }
                continue
            }
            if t.kind == TokenKind.code {
                el.children.push(HoleNode.of(t.value, t.span))
                self.eat()
                continue
            }
            if t.kind == TokenKind.text {
                // The raw form, not the resolved one: a `TextNode` becomes a
                // Beans string literal and Beans resolves its own escapes, so
                // `"Count: {n}"` passes straight through and interpolates.
                el.children.push(TextNode.of(t.raw, t.span))
                self.eat()
                continue
            }
            self.fault(t.span, "{t.describe()} is not a child of <{el.tag}> — a child is a <tag>, a \{expr\} or a \"literal\"")
            self.eat()
        }
        self.open_tags.pop()
    }

    /// Read one whole `</name>` and decide what it closes.
    ///
    /// Answers `true` when `el` is finished — either because the close names
    /// it, or because a recovery accepted the close on its behalf.
    fn take_close(el: ElementNode) -> bool {
        let at: Span = self.look().span
        self.eat()
        let head: Token = self.look()
        if head.kind != TokenKind.name {
            self.fault(at, "</ has no tag name after it — write </{el.tag}>")
            return false
        }
        let tag: string = head.value
        self.eat()
        if self.look().kind == TokenKind.tag_end {
            self.eat()
        } else {
            self.fault(at, "</{tag} is missing its > — write </{tag}>")
        }
        if tag == el.tag {
            return true
        }
        if self.is_open(tag) {
            // It belongs to an ancestor. Say what is missing here, and let
            // every element between us and the owner say the same.
            self.fault(el.span, "<{el.tag}> was never closed — add </{el.tag}> before </{tag}>")
            self.unwind = tag
            return true
        }
        // It closes nothing that is open, so it was almost certainly meant to
        // close this. Taking it keeps one mistake to one diagnostic.
        self.fault(at, "</{tag}> does not close <{el.tag}> — change it to </{el.tag}>")
        return true
    }
}
