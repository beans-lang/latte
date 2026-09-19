// parse.b — a `.bx` file, markup first.
//
// crema's parser was handed a starting offset and read one tag; the driver
// decided which `<` opened a tag by looking at what came before it. That
// heuristic is gone. **A `.bx` file is markup, and outside the `<beans>` block
// a `<` always opens a tag.** A literal less-than is `&lt;`, the way it is in
// every other HTML-shaped language.
//
// Three rules run the whole parser and each has its own entry point below.
//
// **A `$` is a transition only when the next character starts an identifier,
// or is `(` or `{`.** `dollar_starts_transition` in lex.b is the whole rule, so
// `$5.00`, `US$` and `$ 20` are text and need no escape.
//
// **A header runs to the first `{` that is not inside parentheses, brackets or
// a string.** The header is then copied through and never inspected, which is
// why an unfamiliar Beans construct in one still works.
//
// **A `}` in text closes a block, but only at the block's own level.** Inside
// a tag it is a brace. That is why `parse_nodes` takes a terminator: an
// element's children are read with `stop_close_tag` and a block's body with
// `stop_brace`, and the same byte means two things in the two modes without a
// flag anywhere else.

package bx

/// How a run of nodes ends.
///
/// `stop_eof` at the top of the file, `stop_close_tag` inside an element, and
/// `stop_brace` inside a `$if` / `$for` / `$match` arm body. The mode is what
/// makes a bare `}` a terminator at block level and a brace everywhere else,
/// resolving that ambiguity with one comparison rather than a flag threaded
/// through the parser.
pub const STOP_EOF: int = 0
pub const STOP_CLOSE_TAG: int = 1
pub const STOP_BRACE: int = 2

/// A parsed `.bx` file.
pub class Document {
    /// The markup, in source order, with the `<beans>` element removed.
    pub nodes: List<Node> = []
    /// The `<beans>` element, if the file has one.
    pub beans: Option<BeansNode> = none
    /// Everything found wrong, in source order.
    pub diags: List<Diag> = []

    pub fn init() {}

    pub fn is_ok() -> bool {
        return self.diags.len() == 0
    }

    /// Every diagnostic, one per line.
    pub fn report() -> string {
        let lines: List<string> = []
        for d: Diag in self.diags {
            lines.push(d.show())
        }
        return lines.join("\n")
    }

    /// A tree form for the golden files.
    pub fn show() -> string {
        let parts: List<string> = []
        for n: Node in self.nodes {
            parts.push(n.show(0))
        }
        match self.beans {
            some(block) => { parts.push(block.show(0)) }
            none => {}
        }
        return parts.join("")
    }
}

/// Parse a whole `.bx` source.
/// Parses one file for one target.
///
/// The target changes what a tag means, what an attribute may be and which
/// forms have something to compile into. It changes nothing about the syntax:
/// the same lexer runs, the same nodes come out, the same spans point at the
/// same bytes, and `tests/w3_shared_syntax.b` runs one fixture through both
/// targets and asserts the trees are identical.
pub fn parse_document(source: string) -> Document {
    return parse_document_for(source, Target.html)
}

pub fn parse_document_for(source: string, target: Target) -> Document {
    let parser: Parser = new Parser(new Lexer(source), target.rules())
    let out: Document = new Document()
    out.nodes = condense(parser.parse_nodes(STOP_EOF, false), false)
    out.beans = parser.beans
    out.diags = parser.lex.diags.clone()
    return out
}

/// Where the cursor was, so a lookahead can put it back.
///
/// `$if c { } else { }` is why: after the body's `}` the parser has to look
/// past whitespace for `else`, and when it is not there the whitespace belongs
/// to the enclosing content and must not have been eaten.
pub struct Mark {
    pub off: int = 0
    pub line: int = 1
    pub col: int = 1
}

pub class Parser {
    pub lex: Lexer = new Lexer("")
    /// The `<beans>` element, once one has been seen. One per file.
    pub beans: Option<BeansNode> = none
    /// How deep inside a tag or a block the cursor is. Zero at the top level of
    /// the file, which is the only place a `<beans>` block is legal.
    ///
    /// `parse_beans` never puts a node in the tree — it lifts the block into
    /// `beans` — so without this counter a `<beans>` written inside a `<div>`
    /// was **silently hoisted out**: the Beans came through at the top of the
    /// generated file and the `<div>` rendered empty. The emitter carries a
    /// message for that shape and could never reach it.
    nesting: int = 0

    /// What this file is compiling into. Consulted for every decision that
    /// differs between the two, and for none that does not.
    pub rules: TargetRules = new HtmlRules()

    pub fn init(lex: Lexer, rules: TargetRules) {
        self.lex = lex
        self.rules = rules
    }

    // ------------------------------------------------------------ cursor

    fn mark() -> Mark {
        return Mark { off: self.lex.off, line: self.lex.line, col: self.lex.col }
    }

    fn restore(at: Mark) {
        self.lex.off = at.off
        self.lex.line = at.line
        self.lex.col = at.col
    }

    fn peek() -> int { return self.lex.peek() }

    fn ahead(n: int) -> int { return self.lex.byte_ahead(n) }

    fn span() -> Span { return self.lex.span() }

    fn report(at: Span, message: string) { self.lex.report(at, message) }

    /// Whether the word `word` starts at the cursor and is not the front of a
    /// longer identifier — `else` matches in `else {` and not in `elsewhere`.
    fn word_ahead(word: string) -> bool {
        let stop: int = self.lex.off + word.len()
        if stop > self.lex.src.len() { return false }
        if !self.lex.src.range_equals(self.lex.off, stop, word) { return false }
        return !is_ident_byte(byte_of(self.lex.src, stop))
    }

    /// Step over the identifier at the cursor and answer it.
    fn take_ident() -> string {
        let start: int = self.lex.off
        for is_ident_byte(self.peek()) {
            self.lex.bump()
        }
        return self.lex.src.slice(start, self.lex.off)
    }

    // ------------------------------------------------------------ content

    /// Read nodes until `stop` says to stop.
    ///
    /// `component_children` is true while reading the children of a component
    /// tag, which is the one place a `$slot:name { ... }` may *define* a
    /// template rather than place one.
    pub fn parse_nodes(stop: int, component_children: bool) -> List<Node> {
        // Every recursive call reads the inside of a tag or a block; only the
        // document's own call passes STOP_EOF. So this one line is the whole
        // "am I at the top level" question, and it cannot be forgotten at one
        // of the eight call sites.
        if stop != STOP_EOF { self.nesting = self.nesting + 1 }
        let out: List<Node> = []
        var text: List<string> = []
        var text_at: Span = self.span()
        var has_text: bool = false

        for true {
            if self.lex.at_end() {
                if stop == STOP_CLOSE_TAG {
                    self.report(self.span(), "the file ended inside a tag — add the missing closing tag")
                }
                if stop == STOP_BRACE {
                    self.report(self.span(), "the file ended inside a block — add the missing \}")
                }
                break
            }
            let b: int = self.peek()

            if b == 125 && stop == STOP_BRACE {
                break
            }
            if b == 92 {
                // `\}` and `\{` are the only escapes markup text has. Every
                // other backslash is a backslash, so a Windows path and a
                // regexp survive being written in running text.
                let next: int = self.ahead(1)
                if next == 125 || next == 123 {
                    if !has_text { text_at = self.span() ; has_text = true }
                    text.push(self.lex.src.slice(self.lex.off + 1, self.lex.off + 2))
                    self.lex.bump()
                    self.lex.bump()
                    continue
                }
            }
            if b == 36 {
                if self.ahead(1) == 36 {
                    // `$$` is the escape for a literal dollar in front of a
                    // word. Everywhere else a `$` needs no escape at all.
                    if !has_text { text_at = self.span() ; has_text = true }
                    text.push("$")
                    self.lex.bump()
                    self.lex.bump()
                    continue
                }
                if dollar_starts_transition(self.lex.src, self.lex.off) {
                    flush_text(out, text, text_at, has_text, self.rules)
                    text = []
                    has_text = false
                    match self.parse_transition(component_children) {
                        some(node) => { out.push(node) }
                        none => {}
                    }
                    continue
                }
            }
            if b == 60 {
                if self.ahead(1) == 47 {
                    if stop == STOP_CLOSE_TAG { break }
                    let at: Span = self.span()
                    self.report(at, "a closing tag with nothing open — remove it, or add the opening tag it closes")
                    self.skip_past(62)
                    continue
                }
                flush_text(out, text, text_at, has_text, self.rules)
                text = []
                has_text = false
                match self.parse_tag() {
                    some(node) => { out.push(node) }
                    none => {}
                }
                continue
            }
            if !has_text {
                text_at = self.span()
                has_text = true
            }
            text.push(self.lex.src.slice(self.lex.off, self.lex.off + 1))
            self.lex.bump()
        }
        flush_text(out, text, text_at, has_text, self.rules)
        if stop != STOP_EOF { self.nesting = self.nesting - 1 }
        return move out
    }

    /// Step past the next `stop` byte, for error recovery.
    fn skip_past(stop: int) {
        for !self.lex.at_end() {
            let b: int = self.peek()
            self.lex.bump()
            if b == stop { return }
        }
    }

    // -------------------------------------------------------------- tags

    /// Read one `<...>`. The cursor is on the `<`.
    fn parse_tag() -> Option<Node> {
        let at: Span = self.span()
        if self.ahead(1) == 33 {
            return self.parse_bang(at)
        }
        self.lex.bump()
        if !is_name_start_byte(self.peek()) {
            self.report(at, "a < that does not open a tag — outside the <beans> block every < opens one, so write &lt; for a literal less-than sign")
            return none
        }
        let name_start: int = self.lex.off
        for is_name_byte(self.peek()) {
            self.lex.bump()
        }
        let tag: string = self.lex.src.slice(name_start, self.lex.off)

        if tag == "beans" {
            return self.parse_beans(at)
        }
        if tag.to_lower() == "beans" {
            self.report(at, "the Beans block is spelled <beans>, all lowercase — a capitalised tag names a component")
            return none
        }

        let component: bool = self.rules.names_a_component(tag)
        if !component {
            let unknown_tag: string = self.rules.tag_refusal(tag)
            if unknown_tag != "" { self.report(at, unknown_tag) }
        }
        // `<Grid<int>>`. A tag name stops at the `<` — `is_name_byte` does not
        // include one — so this checks the byte that follows the name, not a
        // substring of it: `tag` itself can never contain a `<`, so a check
        // like `tag.contains("<")` would never fire here.
        if component && self.peek() == 60 {
            self.report(at, "a closed generic component tag is not supported — reflection has no zero-argument initializer for a closed generic, on either backend, so latte cannot activate {tag}<...> through markup. Wrap it in a non-generic component, as in a Rows class that extends {tag}<Order>")
            self.skip_past(62)
            return none
        }
        let node: ElementNode = ElementNode.of(tag, component, at)
        self.parse_attributes(node)
        if self.lex.at_end() {
            self.report(at, "<{tag}> was never finished — add the missing >")
            return some(node)
        }
        // `parse_attributes` leaves the cursor on `>` or at a `/>`.
        if self.peek() == 47 {
            self.lex.bump()
            if self.peek() != 62 {
                self.report(self.span(), "a / inside <{tag}> that does not close it — write /> to close the tag")
            } else {
                self.lex.bump()
            }
            node.self_closed = true
            self.finish_empty(node, at)
            return some(node)
        }
        self.lex.bump()
        if self.rules.is_void_element(tag) {
            node.self_closed = true
            self.finish_empty(node, at)
            return some(node)
        }
        if !component && self.rules.is_raw_text_element(tag) {
            self.parse_raw_text(node, at)
            return some(node)
        }
        node.children = condense(self.parse_nodes(STOP_CLOSE_TAG, component), self.rules.preserves_whitespace(tag))
        self.expect_close(tag, at)
        return some(node)
    }

    /// A void or self-closed element takes no children; check nothing follows
    /// that says otherwise.
    fn finish_empty(node: ElementNode, at: Span) {
        if node.component { return }
        if !self.rules.is_void_element(node.tag) { return }
        if !node.self_closed { return }
    }

    /// Read `</tag>`, having read the children.
    fn expect_close(tag: string, at: Span) {
        if self.lex.at_end() {
            self.report(at, "<{tag}> was never closed — add </{tag}>")
            return
        }
        // The cursor sits on `</`.
        self.lex.bump()
        self.lex.bump()
        let name_start: int = self.lex.off
        for is_name_byte(self.peek()) {
            self.lex.bump()
        }
        let closing: string = self.lex.src.slice(name_start, self.lex.off)
        if closing != tag {
            self.report(at, "<{tag}> is closed by </{closing}> — the names have to match")
        }
        self.lex.skip_space()
        if self.peek() == 62 {
            self.lex.bump()
        } else {
            self.report(self.span(), "</{closing}> was never finished — add the missing >")
        }
    }

    /// `<!-- ... -->` and `<!DOCTYPE ...>`.
    fn parse_bang(at: Span) -> Option<Node> {
        let src: string = self.lex.src
        if src.range_equals(self.lex.off, clamp_offset(self.lex.off + 4, src.len()), "<!--") {
            let close: int = find_from(src, "-->", self.lex.off + 4)
            if close < 0 {
                self.report(at, "a comment was never closed — add the missing -->")
                self.lex.advance_to(src.len())
                return none
            }
            self.lex.advance_to(close + 3)
            // A markup comment is a note to the reader of the `.bx` file. It
            // is not emitted: an HTML comment that reaches the browser is
            // bytes on every render for something no user sees, and a
            // component that wants one can write `$html("<!-- … -->")`.
            return none
        }
        let close: int = src.find_byte(62, self.lex.off)
        if close < 0 {
            self.report(at, "a <! declaration was never closed — add the missing >")
            self.lex.advance_to(src.len())
            return none
        }
        let text: string = src.slice(self.lex.off, close + 1)
        self.lex.advance_to(close + 1)
        if !text.to_lower().starts_with("<!doctype") {
            self.report(at, "{text} is not markup latte knows — only <!-- comments --> and <!DOCTYPE ...> may start with <!")
            return none
        }
        let refusal: string = self.rules.doctype_refusal(text)
        if refusal != "" { self.report(at, refusal); return none }
        return some(DoctypeNode.of(text, at))
    }

    /// The `<beans>` element: raw text, copied through byte for byte.
    fn parse_beans(at: Span) -> Option<Node> {
        self.lex.skip_space()
        if self.peek() != 62 {
            self.report(at, "<beans> takes no attributes — it holds Beans and nothing else")
            self.skip_past(62)
        } else {
            self.lex.bump()
        }
        let start: int = self.lex.off
        let close: int = find_from(self.lex.src, "</beans>", start)
        if close < 0 {
            self.report(at, "<beans> was never closed — add </beans>")
            self.lex.advance_to(self.lex.src.len())
            return none
        }
        let code: string = self.lex.src.slice(start, close)
        self.lex.advance_to(close + 8)
        // Consumed first, so the rest of the file still parses, and only then
        // refused: a block inside a tag or a block is not this file's block.
        if self.nesting > 0 {
            self.report(at, "a <beans> block is only legal at the top level of a file, not inside markup — a block written inside a tag or a block would be lifted out of it, so the Beans would run somewhere other than where it is written and the element around it would render empty")
            return none
        }
        match self.beans {
            some(first) => {
                self.report(at, "a second <beans> block — one file holds one, and the first is at {first.span.show()}")
                return none
            }
            none => {}
        }
        let block: BeansNode = BeansNode.of(code, at)
        block.start = start
        self.beans = some(block)
        return none
    }

    /// The body of a `<script>` or `<style>`: raw text, and no interpolation.
    ///
    /// **Interpolation here is refused, and that is a security control rather
    /// than a diagnostic.** The serializer escapes for HTML text; HTML
    /// escaping inside a script is not a defence, because `</script>` closes
    /// the element from inside a JavaScript string and `&lt;` does not help.
    /// The compiler knows the tag and the serializer does not, so the refusal
    /// belongs here.
    ///
    /// The transition rule is the file's own, applied unchanged: a `$` starts
    /// one when the byte **after** it starts an identifier or is `(` or `{`.
    /// So `$5.00`, `US$`, `$ 20` and a trailing `$` are ordinary script bytes
    /// needing no escape, and `$$` writes one dollar, the same escape the rest
    /// of the file has.
    ///
    /// `a$b` **is** a transition: the classifier never looks at the byte
    /// before the `$`, only the one after it. So a JavaScript identifier
    /// holding a dollar is refused here and has to be written `a$$b`.
    /// `tests/markup_refusals.b` has the case.
    fn parse_raw_text(node: ElementNode, at: Span) {
        let closer: string = "</{node.tag}>"
        let start: int = self.lex.off
        let close: int = find_case_insensitive(self.lex.src, closer, start)
        if close < 0 {
            self.report(at, "<{node.tag}> was never closed — add {closer}")
            self.lex.advance_to(self.lex.src.len())
            return
        }
        let body: string = self.lex.src.slice(start, close)
        let pieces: List<string> = []
        var run: int = 0
        var i: int = 0
        for i < body.len() {
            if body.byte_at(i) as int != 36 {
                i = i + 1
                continue
            }
            if byte_of(body, i + 1) == 36 {
                pieces.push(body.slice(run, i))
                pieces.push("$")
                i = i + 2
                run = i
                continue
            }
            if dollar_starts_transition(body, i) {
                let hit: Lexer = Lexer.at(self.lex.src, start + i)
                self.report(hit.span(),
                    "an expression inside <{node.tag}> — latte refuses it: the serializer escapes for HTML text, and HTML escaping inside a {node.tag} is not a defence. Build the value in Beans and pass it through an attribute, or write $$ for a literal dollar")
            }
            i = i + 1
        }
        pieces.push(body.slice(run, body.len()))
        self.lex.advance_to(close + closer.len())
        let text: string = pieces.join("")
        // `<script src="/app.js"></script>` has an empty body, and an empty
        // frame is a frame the differ still walks. Nothing serializes it, so
        // nothing is lost by leaving it out.
        if text.len() == 0 { return }
        node.children.push(RawTextNode.of(text, at))
    }

    // -------------------------------------------------------- attributes

    /// Read every attribute up to the `>` or `/>`, leaving the cursor on it.
    fn parse_attributes(node: ElementNode) {
        for true {
            self.lex.skip_space()
            if self.lex.at_end() { return }
            let b: int = self.peek()
            if b == 62 { return }
            if b == 47 { return }
            if b == 60 {
                self.report(self.span(), "a < inside <{node.tag}> — the tag before it is missing its >")
                return
            }
            if !is_name_start_byte(b) {
                let one: string = self.lex.src.slice(self.lex.off, self.lex.off + 1)
                self.report(self.span(), "'{one}' is not an attribute name inside <{node.tag}>")
                self.lex.bump()
                continue
            }
            let at: Span = self.span()
            let name_start: int = self.lex.off
            for is_name_byte(self.peek()) {
                self.lex.bump()
            }
            let name: string = self.lex.src.slice(name_start, self.lex.off)
            self.parse_attribute_value(node, name, at)
        }
    }

    /// Read the `= value` half, if there is one, and classify the attribute.
    fn parse_attribute_value(node: ElementNode, name: string, at: Span) {
        let saved: Mark = self.mark()
        self.lex.skip_space()
        var has_value: bool = false
        var literal: string = ""
        var code: string = ""
        var is_code: bool = false
        if self.peek() == 61 {
            self.lex.bump()
            self.lex.skip_space()
            has_value = true
            let b: int = self.peek()
            if b == 34 {
                let token: Token = self.lex.next_token()
                literal = token.value
            } else {
                if b == 123 {
                    let token: Token = self.lex.next_token()
                    code = token.value
                    is_code = true
                } else {
                    self.report(self.span(), "{name}= needs a \"string\" or a \{expression\} after it")
                    has_value = false
                }
            }
        } else {
            self.restore(saved)
        }
        match self.classify(node, name, at, has_value, is_code, literal, code) {
            some(attr) => { node.attrs.push(attr) }
            none => {}
        }
    }

    /// Turn one attribute's shape into the node the emitter wants, or refuse it.
    fn classify(node: ElementNode, name: string, at: Span, has_value: bool,
                is_code: bool, literal: string, code: string) -> Option<Attr> {
        let colon: int = name.find_byte(58, 0)
        if colon >= 0 {
            let space: string = name.slice(0, colon)
            let rest: string = name.slice(colon + 1, name.len())
            if space == "on" {
                return self.classify_event(node, rest, at, has_value, is_code, code)
            }
            if space == "bind" {
                return self.classify_bind(node, rest, at, has_value, is_code, code)
            }
            // An XML namespace is not one of latte's; it is part of an ordinary
            // attribute name, and the colon is a byte the safe set allows. It
            // falls through to the paths below — which is what makes
            // `xlink:href` writable and its scheme check reachable.
            if !is_xml_namespace(space) || self.rules.target() == Target.canvas {
                self.report(at, self.rules.namespace_refusal(name))
                return none
            }
        }
        if name == "key" {
            if !is_code {
                self.report(at, "key needs an expression: key=\{row.id\}")
                return none
            }
            return some(KeyAttr.of(code, at))
        }
        if name == "ref" {
            if !is_code {
                self.report(at, "ref needs an expression: ref=\{self.input\}")
                return none
            }
            if !is_place_expression(code) {
                self.report(at, "ref=\{{code}\} is not a field to write the handle into — ref needs a place, such as ref=\{self.input\}")
                return none
            }
            return some(RefAttr.of(code, at))
        }
        if name == "live" {
            // The component test comes first, and it has to: this branch runs
            // BEFORE the `if node.component` fork below, so accepting a
            // LiveAttr here would let one through on a component tag and leave
            // the emitter to refuse it — with its generic "not something a
            // component tag can take", which says nothing about what `live`
            // means or where to put it. The specific refusal further down was
            // written, was never reachable, and its message was never read.
            if node.component {
                self.report(at, "live marks an element's subtree, not a component — a component renders itself, and the signals its own markup reads bind there. Put it on an element inside that component")
                return none
            }
            if has_value {
                self.report(at, "live takes no value — write it on its own")
                return none
            }
            let refusal: string = self.rules.live_refusal()
            if refusal != "" { self.report(at, refusal); return none }
            return some(LiveAttr.of(at))
        }
        if node.component {
            return self.classify_parameter(node, name, at, has_value, is_code, literal, code)
        }
        if name == "attrs" {
            if !is_code {
                self.report(at, "attrs needs an expression: attrs=\{self.extra\}")
                return none
            }
            let refusal: string = self.rules.splat_refusal()
            if refusal != "" { self.report(at, refusal); return none }
            return some(SplatAttr.of(code, at))
        }
        if name == "preserve" {
            if has_value {
                self.report(at, "preserve takes no value — write it on its own")
                return none
            }
            let refusal: string = self.rules.preserve_refusal()
            if refusal != "" { self.report(at, refusal); return none }
            return some(PreserveAttr.of(at))
        }
        let handler_refusal: string = self.rules.inline_handler_refusal(name)
        if handler_refusal != "" {
            self.report(at, handler_refusal)
            return none
        }
        // A name the target does not have. The html target has no such thing —
        // HTML is open, and `data-`, `aria-` and a custom element's own
        // property are all legitimate. The canvas target's controls have a
        // closed set, so a misspelling is a mistake, and one that compiled to
        // a silent no-op is the most common way an interface stops matching
        // the markup that describes it.
        let unknown: string = self.rules.attribute_refusal(node.tag, name)
        if unknown != "" {
            self.report(at, unknown)
            return none
        }
        if is_boolean_attribute(name) {
            if !has_value {
                return some(FlagAttr.of(name, at))
            }
            if !is_code {
                self.report(at, "{name} is a boolean attribute: any string value makes it present, so {name}=\"{literal}\" is on whatever it says. Write {name} on its own, or {name}=\{<condition>\}")
                return none
            }
            return some(ExprAttr.of(name, code, at))
        }
        if !has_value {
            return some(FlagAttr.of(name, at))
        }
        if is_code {
            return some(ExprAttr.of(name, code, at))
        }
        return some(LiteralAttr.of(name, self.rules.resolve_literal(literal), at))
    }

    /// One parameter on a component tag: its Beans field, by its Beans name.
    fn classify_parameter(node: ElementNode, name: string, at: Span, has_value: bool,
                          is_code: bool, literal: string, code: string) -> Option<Attr> {
        if name == "attrs" {
            self.report(at, "attrs is latte's attribute splat and cannot be a component parameter — rename the parameter on {node.tag}")
            return none
        }
        if name == "preserve" {
            self.report(at, "preserve marks an element's subtree, not a component — put it on the element the third-party library owns")
            return none
        }
        if !is_beans_identifier(name) {
            self.report(at, "{name} is not a Beans field name — a component takes its parameters by their Beans names, so {node.tag} has no {name}")
            return none
        }
        if !has_value {
            return some(FlagAttr.of(name, at))
        }
        if is_code {
            return some(ExprAttr.of(name, code, at))
        }
        return some(LiteralAttr.of(name, self.rules.resolve_literal(literal), at))
    }

    /// `on:click={...}`.
    fn classify_event(node: ElementNode, event: string, at: Span, has_value: bool,
                      is_code: bool, code: string) -> Option<Attr> {
        if node.component {
            self.report(at, "on:{event} is a DOM event and {node.tag} is a component — a component reports an event through a Callback parameter, written on_{event}=\{...\} with the name its author gave it")
            return none
        }
        if !has_value || !is_code {
            self.report(at, "on:{event} needs a handler: on:{event}=\{fn(e: {family_or_event(event)}) \{ ... \}\}")
            return none
        }
        if !self.rules.is_event(event) {
            let near: string = self.rules.nearest_event(event)
            if near == "" {
                self.report(at, "on:{event} is not an event latte has — the table is {self.rules.event_list()}")
            } else {
                self.report(at, "on:{event} is not an event latte has — did you mean on:{near}? The table is {self.rules.event_list()}")
            }
            return none
        }
        return some(EventAttr.of(event, code, at))
    }

    /// `bind:value={...}`, `bind:value.int={...}`, `bind:checked={...}`.
    fn classify_bind(node: ElementNode, rest: string, at: Span, has_value: bool,
                     is_code: bool, code: string) -> Option<Attr> {
        var target: string = rest
        var modifier: string = ""
        let dot: int = rest.find_byte(46, 0)
        if dot >= 0 {
            target = rest.slice(0, dot)
            modifier = rest.slice(dot + 1, rest.len())
        }
        if node.component {
            self.report(at, "bind:{target} is a two-way binding on a form control and {node.tag} is a component — pass the value down as a parameter and take the change back through a Callback")
            return none
        }
        if !has_value || !is_code {
            self.report(at, "bind:{rest} needs the field to bind: bind:{rest}=\{self.note\}")
            return none
        }
        if !is_place_expression(code) {
            self.report(at, "bind:{rest}=\{{code}\} is not a field to write back to — a binding needs a place, such as bind:{rest}=\{self.note\}")
            return none
        }
        let tag: string = node.tag
        if target == "checked" {
            let state_refusal: string = self.rules.bind_state_refusal(tag)
            if state_refusal != "" {
                self.report(at, state_refusal)
                return none
            }
            if modifier != "" {
                self.report(at, "bind:checked takes no conversion — it is already a bool")
                return none
            }
            return some(BindAttr.of("checked", "", code, at))
        }
        if target != "value" {
            self.report(at, "bind:{target} is not a binding latte has — the two are bind:value and bind:checked")
            return none
        }
        if modifier != "" && modifier != "int" && modifier != "float" && modifier != "bool" {
            self.report(at, "bind:value.{modifier} is not a conversion latte has — the three are .int, .float and .bool")
            return none
        }
        if self.rules.bind_value_refusal(tag) == "" {
            return some(BindAttr.of("value", modifier, code, at))
        }
        self.report(at, self.rules.bind_value_refusal(tag))
        return none
    }

    // ------------------------------------------------------- transitions

    /// Read one `$...`. The cursor is on the `$`.
    fn parse_transition(component_children: bool) -> Option<Node> {
        let at: Span = self.span()
        let next: int = self.ahead(1)
        if next == 40 {
            self.lex.bump()
            let stop: int = end_of_group(self.lex.src, self.lex.off)
            if stop < 0 {
                self.report(at, "$( was never closed — add the missing )")
                self.lex.advance_to(self.lex.src.len())
                return none
            }
            let code: string = self.lex.src.slice(self.lex.off + 1, stop - 1)
            self.lex.advance_to(stop)
            return some(ExprNode.of(code.trim(), "explicit", at))
        }
        if next == 123 {
            self.lex.bump()
            let stop: int = end_of_group(self.lex.src, self.lex.off)
            if stop < 0 {
                self.report(at, "$\{ was never closed — add the missing \}")
                self.lex.advance_to(self.lex.src.len())
                return none
            }
            let code: string = self.lex.src.slice(self.lex.off + 1, stop - 1)
            self.lex.advance_to(stop)
            return some(CodeNode.of(code.trim(), at))
        }
        self.lex.bump()
        let word_start: Mark = self.mark()
        let word: string = self.take_ident()
        if word == "if" { return self.parse_if(at) }
        if word == "for" { return self.parse_for(at) }
        if word == "match" { return self.parse_match(at) }
        if word == "slot" { return self.parse_slot(at, component_children) }
        if word == "html" { return self.parse_html(at) }
        self.restore(word_start)
        let stop: int = end_of_chain(self.lex.src, self.lex.off)
        let code: string = self.lex.src.slice(self.lex.off, stop)
        self.lex.advance_to(stop)
        return some(ExprNode.of(code, "implicit", at))
    }

    /// `$html(expr)` — the only bypass there is, named so it greps.
    fn parse_html(at: Span) -> Option<Node> {
        self.lex.skip_space()
        if self.peek() != 40 {
            self.report(at, "$html is the raw-HTML form and needs an expression in parentheses: $html(self.rendered)")
            return none
        }
        let stop: int = end_of_group(self.lex.src, self.lex.off)
        if stop < 0 {
            self.report(at, "$html( was never closed — add the missing )")
            self.lex.advance_to(self.lex.src.len())
            return none
        }
        let code: string = self.lex.src.slice(self.lex.off + 1, stop - 1)
        self.lex.advance_to(stop)
        let refusal: string = self.rules.raw_html_refusal()
        if refusal != "" { self.report(at, refusal); return none }
        return some(RawHtmlNode.of(code.trim(), at))
    }

    /// Read a block header and step past its `{`.
    ///
    /// Answers `none` when there is no `{` at the header's own level, which is
    /// either a missing brace or a map literal in the header that ambiguously
    /// looks like the body's opening brace.
    fn take_header(at: Span, keyword: string) -> Option<string> {
        let start: int = self.lex.off
        let brace: int = find_header_brace(self.lex.src, start)
        if brace < 0 {
            self.report(at, "${keyword} has no \{ to open its body — a header runs to the first \{ that is not inside parentheses, brackets or a string, so a brace literal in the header needs parentheses around it")
            return none
        }
        let header: string = self.lex.src.slice(start, brace).trim()
        self.lex.advance_to(brace + 1)
        return some(header)
    }

    /// `$if c { } else if d { } else { }`.
    fn parse_if(at: Span) -> Option<Node> {
        let node: IfNode = IfNode.of(at)
        let head: Option<string> = self.take_header(at, "if")
        match head {
            some(header) => {
                let branch: Branch = Branch.of(header, at)
                branch.body = condense(self.parse_nodes(STOP_BRACE, false), false)
                node.branches.push(branch)
            }
            none => { return none }
        }
        self.close_block(at, "if")
        for true {
            let saved: Mark = self.mark()
            self.lex.skip_space()
            if !self.word_ahead("else") {
                self.restore(saved)
                break
            }
            let else_at: Span = self.span()
            self.lex.advance_to(self.lex.off + 4)
            self.lex.skip_space()
            if self.word_ahead("if") {
                self.lex.advance_to(self.lex.off + 2)
                match self.take_header(else_at, "if") {
                    some(header) => {
                        let branch: Branch = Branch.of(header, else_at)
                        branch.body = condense(self.parse_nodes(STOP_BRACE, false), false)
                        node.branches.push(branch)
                    }
                    none => { return some(node) }
                }
                self.close_block(else_at, "if")
                continue
            }
            if self.peek() != 123 {
                self.report(else_at, "else needs a \{ body \} after it, or another if")
                return some(node)
            }
            self.lex.bump()
            let branch: Branch = Branch.of("", else_at)
            branch.body = condense(self.parse_nodes(STOP_BRACE, false), false)
            node.branches.push(branch)
            self.close_block(else_at, "if")
            break
        }
        return some(node)
    }

    /// `$for row: Row in self.rows { }`.
    fn parse_for(at: Span) -> Option<Node> {
        match self.take_header(at, "for") {
            some(header) => {
                let node: ForNode = ForNode.of(header, at)
                node.body = condense(self.parse_nodes(STOP_BRACE, false), false)
                self.close_block(at, "for")
                return some(node)
            }
            none => { return none }
        }
    }

    /// `$match v { some(x) => { } none => { } }`.
    fn parse_match(at: Span) -> Option<Node> {
        match self.take_header(at, "match") {
            some(header) => {
                let node: MatchNode = MatchNode.of(header, at)
                for true {
                    self.lex.skip_space()
                    if self.lex.at_end() {
                        self.report(at, "$match was never closed — add the missing \}")
                        return some(node)
                    }
                    if self.peek() == 125 {
                        self.lex.bump()
                        break
                    }
                    let arm_at: Span = self.span()
                    let arrow: int = find_arrow(self.lex.src, self.lex.off)
                    if arrow < 0 {
                        self.report(arm_at, "a $match arm needs a => between its pattern and its body")
                        self.lex.advance_to(self.lex.src.len())
                        return some(node)
                    }
                    let pattern: string = self.lex.src.slice(self.lex.off, arrow).trim()
                    self.lex.advance_to(arrow + 2)
                    self.lex.skip_space()
                    if self.peek() != 123 {
                        self.report(arm_at, "a $match arm's body is a \{ block \} — write {pattern} => \{ ... \}")
                        self.lex.advance_to(self.lex.src.len())
                        return some(node)
                    }
                    self.lex.bump()
                    let arm: MatchArm = MatchArm.of(pattern, arm_at)
                    arm.body = condense(self.parse_nodes(STOP_BRACE, false), false)
                    node.arms.push(arm)
                    self.close_block(arm_at, "match")
                }
                if node.arms.is_empty() {
                    self.report(at, "$match with no arms — a match needs at least one pattern => \{ ... \}")
                }
                return some(node)
            }
            none => { return none }
        }
    }

    /// Step over the `}` that closes a block body.
    fn close_block(at: Span, keyword: string) {
        if self.peek() == 125 {
            self.lex.bump()
            return
        }
        self.report(at, "${keyword} was never closed — add the missing \} (a \} in running text closes a block, so write \\\} for a literal one)")
    }

    /// The five `$slot` forms.
    fn parse_slot(at: Span, component_children: bool) -> Option<Node> {
        if self.peek() == 40 {
            let stop: int = end_of_group(self.lex.src, self.lex.off)
            if stop < 0 {
                self.report(at, "$slot( was never closed — add the missing )")
                self.lex.advance_to(self.lex.src.len())
                return none
            }
            let code: string = self.lex.src.slice(self.lex.off + 1, stop - 1)
            self.lex.advance_to(stop)
            let node: SlotNode = SlotNode.of("place_expr", "", at)
            node.code = code.trim()
            return some(node)
        }
        if self.peek() != 58 {
            let saved: Mark = self.mark()
            self.lex.skip_space()
            if self.peek() == 123 {
                self.restore(saved)
                self.report(at, "$slot places the component's child content and cannot take a body — to supply it, write the markup as the component's children")
                return none
            }
            self.restore(saved)
            return some(SlotNode.of("place", "", at))
        }
        self.lex.bump()
        if !is_ident_start_byte(self.peek()) {
            self.report(at, "$slot: needs the name of the fragment field after it, as in $slot:row")
            return none
        }
        let name: string = self.take_ident()
        let saved: Mark = self.mark()
        self.lex.skip_space()
        if self.peek() == 123 {
            self.lex.bump()
            return self.parse_slot_define(at, name, "", "", component_children)
        }
        if self.word_ahead("as") {
            self.lex.advance_to(self.lex.off + 2)
            self.lex.skip_space()
            return self.parse_slot_as(at, name, component_children)
        }
        self.restore(saved)
        return some(SlotNode.of("place", name, at))
    }

    /// Everything after `$slot:name as`.
    ///
    /// A **body** is what tells a definition from a placement: `as o: Order {`
    /// supplies the template, `as order` places it and passes `order`. Nothing
    /// about the punctuation decides it, which is why the untyped `as o {` is
    /// refused rather than guessed at.
    fn parse_slot_as(at: Span, name: string, component_children: bool) -> Option<Node> {
        if self.peek() == 40 {
            let stop: int = end_of_group(self.lex.src, self.lex.off)
            if stop < 0 {
                self.report(at, "$slot:{name} as ( was never closed — add the missing )")
                self.lex.advance_to(self.lex.src.len())
                return none
            }
            let code: string = self.lex.src.slice(self.lex.off, stop)
            self.lex.advance_to(stop)
            let node: SlotNode = SlotNode.of("place_arg", name, at)
            node.code = code.trim()
            return some(node)
        }
        if !is_ident_start_byte(self.peek()) {
            self.report(at, "$slot:{name} as needs a value to pass, or a parameter to bind — write as order, or as o: Order \{ ... \}")
            return none
        }
        let chain_stop: int = end_of_chain(self.lex.src, self.lex.off)
        let chain: string = self.lex.src.slice(self.lex.off, chain_stop)
        let after_chain: Mark = Mark { off: chain_stop, line: 1, col: 1 }
        let saved: Mark = self.mark()
        self.lex.advance_to(chain_stop)
        self.lex.skip_space()
        if self.peek() == 58 {
            self.lex.bump()
            let type_start: int = self.lex.off
            let brace: int = find_header_brace(self.lex.src, type_start)
            if brace < 0 {
                self.report(at, "$slot:{name} as {chain}: needs a type and then a \{ body \}")
                return none
            }
            let param_type: string = self.lex.src.slice(type_start, brace).trim()
            self.lex.advance_to(brace + 1)
            return self.parse_slot_define(at, name, chain, param_type, component_children)
        }
        if self.peek() == 123 {
            self.report(at, "$slot:{name} as {chain} \{ needs the parameter's type — write $slot:{name} as {chain}: <Type> \{ ... \}, because a closure's parameter type is not inferred from the field it is assigned to")
            return none
        }
        self.restore(saved)
        self.lex.advance_to(after_chain.off)
        let node: SlotNode = SlotNode.of("place_arg", name, at)
        node.code = chain
        return some(node)
    }

    /// The body of a `$slot:name ... { ... }` definition.
    fn parse_slot_define(at: Span, name: string, param_name: string,
                         param_type: string, component_children: bool) -> Option<Node> {
        let node: SlotNode = SlotNode.of("define", name, at)
        node.param_name = param_name
        node.param_type = param_type
        node.body = condense(self.parse_nodes(STOP_BRACE, false), false)
        self.close_block(at, "slot")
        if !component_children {
            self.report(at, "$slot:{name} \{ ... \} supplies a template and only reads that way inside a component tag — to place a template the component declares, write $slot:{name} with no body")
            return none
        }
        return some(node)
    }
}

// -------------------------------------------------------------- whitespace

/// Push whatever text has been collected, as one node.
fn flush_text(out: List<Node>, pieces: List<string>, at: Span, has_text: bool,
              rules: TargetRules) {
    if !has_text { return }
    let joined: string = pieces.join("")
    if joined.len() == 0 { return }
    out.push(TextNode.of(rules.resolve_literal(joined), at))
}

/// Whether an HTML element's text keeps its whitespace exactly as written.
pub fn preserves_whitespace(tag: string) -> bool {
    let name: string = tag.to_lower()
    if name == "pre" { return true }
    return name == "textarea"
}

/// Condense the whitespace in one content list.
///
/// The rule, and it is Vue's `condense` because that one is understood and has
/// been argued about by more people than latte will ever have:
///
/// 1. Inside a text run, every run of ASCII whitespace becomes one space.
/// 2. A run that is **entirely** whitespace is dropped when it holds a
///    newline, and becomes one space when it does not. So a tag on its own
///    line contributes nothing, and `<span>a</span> <span>b</span>` keeps the
///    space a reader can see.
/// 3. The first node of the list, if it is text, loses a leading space; the
///    last, if it is text, loses a trailing space. That is what turns
///    `<button>\n    Add one\n</button>` into `b.text(n, "Add one")`.
///
/// Inside `<pre>` and `<textarea>` none of it runs.
pub fn condense(nodes: List<Node>, preserve: bool) -> List<Node> {
    let out: List<Node> = []
    if preserve {
        for node: Node in nodes {
            out.push(node)
        }
        return move out
    }
    for node: Node in nodes {
        match node as? TextNode {
            some(text) => {
                let squeezed: string = squeeze(text.text)
                if squeezed == "" { continue }
                out.push(TextNode.of(squeezed, text.span))
            }
            none => { out.push(node) }
        }
    }
    if out.is_empty() { return move out }
    trim_edge(out, 0, true)
    if out.is_empty() { return move out }
    trim_edge(out, out.len() - 1, false)
    let kept: List<Node> = []
    for node: Node in out {
        match node as? TextNode {
            some(text) => {
                if text.text == "" { continue }
                kept.push(node)
            }
            none => { kept.push(node) }
        }
    }
    return move kept
}

/// Take the leading or trailing space off the text node at `index`.
fn trim_edge(nodes: List<Node>, index: int, leading: bool) {
    match nodes[index] as? TextNode {
        some(text) => {
            if leading {
                if text.text.starts_with(" ") {
                    text.text = text.text.slice(1, text.text.len())
                }
                return
            }
            if text.text.ends_with(" ") {
                text.text = text.text.slice(0, text.text.len() - 1)
            }
        }
        none => {}
    }
}

/// Every run of whitespace in `value` as one space, and a whitespace-only run
/// that holds a newline as nothing at all.
fn squeeze(value: string) -> string {
    var only_space: bool = true
    var has_newline: bool = false
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        if b == 10 { has_newline = true }
        if !is_space_byte(b) { only_space = false }
        i = i + 1
    }
    if only_space {
        if has_newline { return "" }
        return " "
    }
    let parts: List<string> = []
    var run: int = 0
    i = 0
    for i < value.len() {
        if !is_space_byte(value.byte_at(i) as int) {
            i = i + 1
            continue
        }
        parts.push(value.slice(run, i))
        parts.push(" ")
        for i < value.len() {
            if !is_space_byte(value.byte_at(i) as int) { break }
            i = i + 1
        }
        run = i
    }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

// ----------------------------------------------------------------- helpers

/// The offset of `needle` in `source` at or after `from`, or `-1`.
pub fn find_from(source: string, needle: string, from: int) -> int {
    if needle.len() == 0 { return from }
    var i: int = clamp_offset(from, source.len())
    let last: int = source.len() - needle.len()
    for i <= last {
        if source.range_equals(i, i + needle.len(), needle) { return i }
        i = i + 1
    }
    return -1
}

/// The same, ignoring ASCII case — which is how HTML compares a closing tag.
pub fn find_case_insensitive(source: string, needle: string, from: int) -> int {
    let wanted: string = needle.to_lower()
    var i: int = clamp_offset(from, source.len())
    let last: int = source.len() - needle.len()
    for i <= last {
        if source.slice(i, i + needle.len()).to_lower() == wanted { return i }
        i = i + 1
    }
    return -1
}

/// The offset of the `=>` that ends a `$match` arm's pattern, or `-1`.
///
/// Strings, comments and nested groups are skipped, so a pattern holding a
/// closure or a string with an arrow in it does not end early.
pub fn find_arrow(source: string, from: int) -> int {
    var i: int = from
    for i < source.len() {
        let past: int = skip_beans_noise(source, i)
        if past > i {
            i = past
            continue
        }
        let b: int = source.byte_at(i) as int
        if b == 40 || b == 91 || b == 123 {
            let stop: int = end_of_group(source, i)
            if stop < 0 { return -1 }
            i = stop
            continue
        }
        if b == 125 { return -1 }
        if b == 61 && byte_of(source, i + 1) == 62 { return i }
        i = i + 1
    }
    return -1
}

/// Whether `name` is spellable as a Beans identifier.
pub fn is_beans_identifier(name: string) -> bool {
    if name.len() == 0 { return false }
    if !is_ident_start_byte(name.byte_at(0) as int) { return false }
    var i: int = 1
    for i < name.len() {
        if !is_ident_byte(name.byte_at(i) as int) { return false }
        i = i + 1
    }
    return true
}

/// The event class for `event`, or the event's own name when the table does
/// not know it — so a diagnostic about an unknown event still reads.
fn family_or_event(event: string) -> string {
    let family: string = event_family(event)
    if family == "" { return "MouseEvent" }
    return family
}
