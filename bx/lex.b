// lex.b — the bytes of a `.bx` file.
//
// Two halves live here and they do different jobs.
//
// **The tag cursor** (`Lexer`) reads the inside of a tag: names, `=`, string
// literals, `{...}` values, `>` and `/>`. It came from crema and is unchanged
// in shape — a cursor rather than a token stream, because a `.bx` file has no
// global token grammar and the parser must be able to say "stop here, the rest
// is text".
//
// **The Beans-source scanners** (the free functions at the bottom) are new and
// are the part every silent bug would come from. latte copies Beans through
// verbatim — a header, an attribute expression, a `${}` block, the `<beans>`
// element — and to copy it it has to know where it ends. That means knowing
// what a brace means, and a brace means four different things:
//
//   * ordinary code, where `{` opens a block and `}` closes it;
//   * inside a string, where a brace is a byte — unless it is `{`, which the
//     spec says opens an interpolation (`{{` is not an escape, SYNTAX.md);
//   * inside a **raw** string, where nothing is an escape and nothing opens an
//     interpolation, so `r"/users/{id}"` is four unremarkable bytes;
//   * inside a comment, where nothing is anything.
//
// crema's driver walked strings with a simpler rule and mis-scanned a raw
// literal. That walker is deleted; this one has raw strings, nested block
// comments and interpolation in the same stack, and `tests/markup.b` puts each
// one through a header.
//
// **What is deliberately not here: a Beans parser.** These scanners find the
// *end* of a construct and nothing else. They never decide what the code
// means, because beansc decides that and gives a better error than a guess
// from here would.

package bx

// ------------------------------------------------------------- diagnostics

/// One thing that is wrong with the source, and where.
///
/// The message is the *body* of a beansc-shaped diagnostic — `show()` puts the
/// position and the `error:` label on the front, so every producer writes one
/// half and the format lives in one place.
///
/// The house style for the body is `<what is wrong> — <what to do about it>`.
/// A diagnostic that only says what is wrong makes the reader guess, and the
/// entire reason a markup language beats hand-written builder calls is that it
/// can point at the line and say what to type instead.
pub class Diag {
    /// Where the fault is, one-based.
    pub span: Span = Span.at(1, 1)
    /// `<what is wrong> — <what to do about it>`.
    pub message: string = ""

    pub fn init(span: Span, message: string) {
        self.span = span
        self.message = message
    }

    pub static fn of(span: Span, message: string) -> Diag {
        return new Diag(span, message)
    }

    /// `line:col: error: <message>`, the form every beansc diagnostic uses.
    pub fn show() -> string {
        return "{self.span.show()}: error: {self.message}"
    }
}

// ------------------------------------------------------------------ tokens

/// What a token is, inside a tag.
///
/// There is no `_` arm anywhere that matches one, so adding a kind is a
/// compile error at every decision point — which is what we want from a
/// lexer's own vocabulary.
pub enum(u8) TokenKind {
    /// `<` — a tag opens.
    open_start
    /// `</` — a tag closes.
    close_start
    /// `>` — an open tag ends.
    tag_end
    /// `/>` — a tag opens and closes at once.
    self_close
    /// `=` — an attribute takes a value.
    equals
    /// A tag or attribute name.
    name
    /// A `"..."` literal. `value` has the escapes resolved, `raw` does not.
    text
    /// A `{...}` region. `value` is the code, brace-balanced, braces stripped.
    code
    /// There is no more input.
    eof
    /// A byte with no place in the tag grammar. Always one byte wide, so a
    /// parser that skips it still makes progress.
    unknown

    /// How to name this in a diagnostic — a phrase that reads inside
    /// "expected a tag name, found ...".
    pub fn show() -> string {
        return match self {
            open_start => "<",
            close_start => "</",
            tag_end => ">",
            self_close => "/>",
            equals => "=",
            name => "a name",
            text => "a string literal",
            code => "a \{...\} value",
            eof => "the end of the file",
            unknown => "an unexpected character",
        }
    }
}

/// One token, with everything a diagnostic or an AST node needs from it.
pub class Token {
    pub kind: TokenKind = TokenKind.eof
    /// For `name`, the name; for `text`, the contents with escapes resolved;
    /// for `code`, the code between the braces. Empty for the rest.
    pub value: string = ""
    /// For `text`, the contents exactly as written, escapes unresolved.
    pub raw: string = ""
    /// Where it starts.
    pub span: Span = Span.at(1, 1)
    /// The byte offset just past it.
    pub end: int = 0

    pub fn init(kind: TokenKind, value: string, raw: string, span: Span, end: int) {
        self.kind = kind
        self.value = value
        self.raw = raw
        self.span = span
        self.end = end
    }

    pub static fn of(kind: TokenKind, value: string, raw: string, span: Span, end: int) -> Token {
        return new Token(kind, value, raw, span, end)
    }

    /// How to name this token inside a diagnostic, as in "found ...".
    pub fn describe() -> string {
        return match self.kind {
            name => "the name {self.value}",
            text => "a string literal",
            code => "a \{...\} value",
            unknown => "an unexpected '{self.value}'",
            open_start => "a <",
            close_start => "a </",
            tag_end => "a >",
            self_close => "a />",
            equals => "an =",
            eof => "the end of the file",
        }
    }

    /// A one-line form for a golden file.
    pub fn show() -> string {
        return match self.kind {
            name => "name {self.value} @{self.span.show()}",
            text => "text \"{self.raw}\" @{self.span.show()}",
            code => "code \{{self.value}\} @{self.span.show()}",
            unknown => "unexpected '{self.value}' @{self.span.show()}",
            open_start => "< @{self.span.show()}",
            close_start => "</ @{self.span.show()}",
            tag_end => "> @{self.span.show()}",
            self_close => "/> @{self.span.show()}",
            equals => "= @{self.span.show()}",
            eof => "eof @{self.span.show()}",
        }
    }
}

// ------------------------------------------------------------------- lexer

/// A cursor over one `.bx` source.
///
/// It owns the diagnostic list for a whole compile, because the lexer, the
/// parser and the emitter all raise them and a caller wants one list in source
/// order. Nothing here ever panics or returns `Result`: a lexer that stopped
/// at the first fault would report one error per run, and the diagnostics a
/// markup layer exists to give are worth more in bulk.
pub class Lexer {
    /// The whole file.
    pub src: string = ""
    /// The next byte to read.
    pub off: int = 0
    /// One-based line of `off`.
    pub line: int = 1
    /// One-based column of `off`, in bytes.
    pub col: int = 1
    /// Everything found wrong so far, in source order.
    pub diags: List<Diag> = []

    pub fn init(src: string) {
        self.src = src
    }

    /// A lexer positioned at byte `from`, with `line` and `col` counted from
    /// the top of the file so its diagnostics agree with beansc's.
    pub static fn at(src: string, from: int) -> Lexer {
        let lex: Lexer = new Lexer(src)
        lex.seek(from)
        return lex
    }

    /// Move to byte `from`, recounting the line and column from the top.
    pub fn seek(from: int) {
        var i: int = 0
        var line: int = 1
        var col: int = 1
        let stop: int = clamp_offset(from, self.src.len())
        for i < stop {
            if self.src.byte_at(i) as int == 10 {
                line = line + 1
                col = 1
            } else {
                col = col + 1
            }
            i = i + 1
        }
        self.off = stop
        self.line = line
        self.col = col
    }

    /// Note a fault. Always returns; nothing here stops on the first one.
    pub fn report(span: Span, message: string) {
        self.diags.push(Diag.of(span, message))
    }

    /// Whether anything was found wrong.
    pub fn clean() -> bool {
        return self.diags.len() == 0
    }

    /// Whether the cursor is past the last byte.
    pub fn at_end() -> bool {
        return self.off >= self.src.len()
    }

    /// Where the cursor is.
    pub fn span() -> Span {
        return Span.at(self.line, self.col)
    }

    /// The byte under the cursor, or `-1` at the end.
    pub fn peek() -> int {
        return self.byte_ahead(0)
    }

    /// The byte `ahead` positions on, or `-1` past the end.
    pub fn byte_ahead(ahead: int) -> int {
        let i: int = self.off + ahead
        if i >= self.src.len() { return -1 }
        if i < 0 { return -1 }
        return self.src.byte_at(i) as int
    }

    /// Step over one byte, keeping the line and column true.
    pub fn bump() {
        if self.at_end() { return }
        if self.src.byte_at(self.off) as int == 10 {
            self.line = self.line + 1
            self.col = 1
        } else {
            self.col = self.col + 1
        }
        self.off = self.off + 1
    }

    /// Step forward to byte `target`, keeping the line and column true.
    ///
    /// The scanners below work in raw offsets because that is the only way to
    /// balance a brace without allocating; this is how the cursor catches up
    /// with one of their answers without recounting the file from the top.
    pub fn advance_to(target: int) {
        let stop: int = clamp_offset(target, self.src.len())
        for self.off < stop {
            self.bump()
        }
    }

    /// Step over spaces, tabs, carriage returns and newlines.
    ///
    /// Comments are deliberately not skipped. `//` inside a tag would have to
    /// mean something, and until someone asks for it, a tag that contains one
    /// gets an "unexpected character" pointing straight at it rather than a
    /// silently dropped attribute.
    pub fn skip_space() {
        for !self.at_end() {
            if !is_space_byte(self.peek()) { return }
            self.bump()
        }
    }

    /// The next token inside a tag, whatever the cursor is looking at.
    ///
    /// Every branch consumes at least one byte except `eof`, so a parser loop
    /// driven by this cannot spin.
    pub fn next_token() -> Token {
        self.skip_space()
        let at: Span = self.span()
        if self.at_end() {
            return Token.of(TokenKind.eof, "", "", at, self.off)
        }
        let b: int = self.peek()
        if b == 60 {
            self.bump()
            if self.peek() == 47 {
                self.bump()
                return Token.of(TokenKind.close_start, "", "", at, self.off)
            }
            return Token.of(TokenKind.open_start, "", "", at, self.off)
        }
        if b == 62 {
            self.bump()
            return Token.of(TokenKind.tag_end, "", "", at, self.off)
        }
        if b == 47 {
            if self.byte_ahead(1) == 62 {
                self.bump()
                self.bump()
                return Token.of(TokenKind.self_close, "", "", at, self.off)
            }
            self.bump()
            return Token.of(TokenKind.unknown, "/", "", at, self.off)
        }
        if b == 61 {
            self.bump()
            return Token.of(TokenKind.equals, "", "", at, self.off)
        }
        if b == 34 {
            return self.scan_text(at)
        }
        if b == 123 {
            return self.scan_code(at)
        }
        if is_name_start_byte(b) {
            return self.scan_name(at)
        }
        let one: string = self.src.slice(self.off, self.off + 1)
        self.bump()
        return Token.of(TokenKind.unknown, one, "", at, self.off)
    }

    /// Scan a tag or attribute name.
    fn scan_name(at: Span) -> Token {
        let start: int = self.off
        for !self.at_end() {
            if is_name_byte(self.peek()) {
                self.bump()
                continue
            }
            break
        }
        let text: string = self.src.slice(start, self.off)
        return Token.of(TokenKind.name, text, "", at, self.off)
    }

    /// Scan a `"..."` attribute literal, producing the raw contents and the
    /// contents with backslash escapes resolved, in one pass.
    ///
    /// A raw newline ends the literal, exactly as it does in Beans: it turns a
    /// missing quote into an error on the line that has it rather than a
    /// cascade fifty lines further down.
    ///
    /// **This is markup, not Beans**, so a `{` in here is a brace and not an
    /// interpolation. An attribute that wants an expression is written
    /// `href={self.url}`, which is a different token entirely — `{}` delimits
    /// an expression and a quoted string never holds one.
    fn scan_text(at: Span) -> Token {
        self.bump()
        let start: int = self.off
        var pieces: List<string> = []
        var run: int = self.off
        var closed: bool = false
        for !self.at_end() {
            let b: int = self.peek()
            if b == 34 {
                closed = true
                break
            }
            if b == 10 { break }
            if b != 92 {
                self.bump()
                continue
            }
            pieces.push(self.src.slice(run, self.off))
            let esc: Span = self.span()
            self.bump()
            if self.at_end() { break }
            if self.peek() == 10 { break }
            let e: int = self.peek()
            self.bump()
            pieces.push(self.escape_value(e, esc))
            run = self.off
        }
        let stop: int = self.off
        pieces.push(self.src.slice(run, stop))
        let raw: string = self.src.slice(start, stop)
        let value: string = pieces.join("")
        if closed {
            self.bump()
        } else {
            self.report(at, "a string literal was never closed — add the missing \" before the end of the line")
        }
        return Token.of(TokenKind.text, value, raw, at, self.off)
    }

    /// What one escape stands for, inside an attribute literal.
    fn escape_value(e: int, at: Span) -> string {
        if e == 110 { return "\n" }
        if e == 116 { return "\t" }
        if e == 114 { return "\r" }
        if e == 48 { return "\0" }
        if e == 92 { return "\\" }
        if e == 34 { return "\"" }
        if e == 123 { return "\{" }
        if e == 125 { return "\}" }
        let written: string = self.src.slice(self.off - 1, self.off)
        self.report(at, "\\{written} is not an escape — write \\n \\t \\r \\0 \\\\ \\\" \\\{ or \\\}")
        return self.src.slice(self.off - 2, self.off)
    }

    /// Scan a `{...}` attribute value and answer the code between the braces.
    ///
    /// The balancing is `end_of_group`'s, which is the one routine in this
    /// package that knows what a brace means. Two implementations of that rule
    /// is how one of them ends up wrong.
    fn scan_code(at: Span) -> Token {
        let stop: int = end_of_group(self.src, self.off)
        if stop < 0 {
            self.report(at, "a \{...\} value was never closed — add the missing \} (a \} inside a string or a comment does not close it)")
            let rest: string = self.src.slice(self.off + 1, self.src.len())
            self.advance_to(self.src.len())
            return Token.of(TokenKind.code, rest, "", at, self.off)
        }
        let code: string = self.src.slice(self.off + 1, stop - 1)
        self.advance_to(stop)
        return Token.of(TokenKind.code, code, "", at, self.off)
    }
}

// ----------------------------------------------------------- byte questions

/// `from`, held inside `0..len`.
pub fn clamp_offset(from: int, len: int) -> int {
    if from < 0 { return 0 }
    if from > len { return len }
    return from
}

/// The byte at `at`, or `-1` when `at` is outside `source`.
pub fn byte_of(source: string, at: int) -> int {
    if at < 0 { return -1 }
    if at >= source.len() { return -1 }
    return source.byte_at(at) as int
}

/// Whether a byte is whitespace between tokens.
pub fn is_space_byte(v: int) -> bool {
    if v == 32 { return true }
    if v == 9 { return true }
    if v == 10 { return true }
    return v == 13
}

/// Whether a byte may start a tag or attribute name: an ASCII letter or `_`.
pub fn is_name_start_byte(v: int) -> bool {
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    return v == 95
}

/// Whether a byte may continue a tag or attribute name.
///
/// Letters, digits, `_`, `-`, `.` and `:`. The hyphen is what makes
/// `data-count` and `my-widget` one token; the colon is what makes `on:click`
/// and `bind:value` one token, so an attribute namespace is a *parse* decision
/// rather than three tokens the parser has to reassemble. The dot is here for
/// a package-qualified component tag, `<ui.Button>`, and for a binding
/// modifier, `bind:value.int`.
pub fn is_name_byte(v: int) -> bool {
    if v >= 48 && v <= 57 { return true }
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    if v == 95 { return true }
    if v == 45 { return true }
    if v == 46 { return true }
    return v == 58
}

/// Whether a byte may start a Beans identifier: an ASCII letter or `_`.
///
/// Separate from `is_name_start_byte` even though they agree today, because
/// they answer different questions and one of them will move first. This one
/// is also what decides whether a `$` is a transition.
pub fn is_ident_start_byte(v: int) -> bool {
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    return v == 95
}

/// Whether a byte may continue a Beans identifier.
///
/// No `-`, no `.`, no `:` — an identifier in Beans is letters, digits and
/// underscore, and famously never a `$`, which is what leaves `$` free to be
/// the transition character.
pub fn is_ident_byte(v: int) -> bool {
    if v >= 48 && v <= 57 { return true }
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    return v == 95
}

// ------------------------------------------------------ the `$` classifier

/// Whether the `$` at `at` opens a transition.
///
/// **Only when the next character starts an identifier, or is `(` or `{`.**
/// Everything else is a dollar sign in running text and needs no escape:
///
/// | written | what it is |
/// |---|---|
/// | `$5.00` | text — a digit does not start an identifier |
/// | `US$` | text — nothing follows it |
/// | `$ 20` | text — a space does not start an identifier |
/// | `$$` | the escape for a literal `$` in front of a word |
/// | `$self.count` | a transition |
/// | `$(a + b)` | a transition |
/// | `${ ... }` | a transition |
///
/// Prices are the case people actually write, which is why the rule is this
/// one and not "a `$` is always special unless escaped".
pub fn dollar_starts_transition(source: string, at: int) -> bool {
    if byte_of(source, at) != 36 { return false }
    let next: int = byte_of(source, at + 1)
    if next == 40 { return true }
    if next == 123 { return true }
    return is_ident_start_byte(next)
}

// -------------------------------------------------- scanning Beans verbatim

/// Just past the line or block comment that starts at `at`, or `at` itself
/// when nothing starts there.
///
/// Block comments nest, which the spec allows and which a scanner that counts
/// to the first `*/` gets wrong.
pub fn end_of_comment(source: string, at: int) -> int {
    if byte_of(source, at) != 47 { return at }
    let second: int = byte_of(source, at + 1)
    if second == 47 {
        let newline: int = source.find_byte(10, at + 2)
        if newline < 0 { return source.len() }
        return newline
    }
    if second != 42 { return at }
    var depth: int = 1
    var i: int = at + 2
    for i < source.len() {
        let b: int = source.byte_at(i) as int
        if b == 47 && byte_of(source, i + 1) == 42 {
            depth = depth + 1
            i = i + 2
            continue
        }
        if b == 42 && byte_of(source, i + 1) == 47 {
            depth = depth - 1
            i = i + 2
            if depth == 0 { return i }
            continue
        }
        i = i + 1
    }
    return source.len()
}

/// Just past the raw string literal that starts at `at`, or `at` itself.
///
/// `r"..."`, `r#"..."#`, `r##"…"##`. Nothing inside is an escape and nothing
/// inside opens an interpolation, so `r"/users/{id}"` contributes no brace to
/// any depth count — the thing crema's driver got wrong.
///
/// The caller is responsible for `r` actually being a prefix rather than the
/// tail of an identifier; `is_raw_string_start` answers that.
pub fn end_of_raw_string(source: string, at: int) -> int {
    if !is_raw_string_start(source, at) { return at }
    var hashes: int = 0
    var i: int = at + 1
    for byte_of(source, i) == 35 {
        hashes = hashes + 1
        i = i + 1
    }
    // `is_raw_string_start` already proved the quote is here.
    i = i + 1
    for i < source.len() {
        if source.byte_at(i) as int != 34 {
            i = i + 1
            continue
        }
        var seen: int = 0
        for seen < hashes {
            if byte_of(source, i + 1 + seen) != 35 { break }
            seen = seen + 1
        }
        if seen == hashes {
            return i + 1 + hashes
        }
        i = i + 1
    }
    return source.len()
}

/// Whether a raw string literal starts at `at`.
///
/// `r` is only a prefix when the quote follows it with nothing but `#` in
/// between **and** the byte before it cannot continue an identifier — so the
/// `r` in `var r"x"` opens one and the `r` in `器r` or `ptr"x"` does not.
pub fn is_raw_string_start(source: string, at: int) -> bool {
    if byte_of(source, at) != 114 { return false }
    if is_ident_byte(byte_of(source, at - 1)) { return false }
    var i: int = at + 1
    for byte_of(source, i) == 35 {
        i = i + 1
    }
    return byte_of(source, i) == 34
}

/// Just past the ordinary `"..."` string literal that starts at `at`, or `at`.
///
/// Interpolation is followed into: a `{` inside a string opens one, the code
/// inside it can hold another string, that string can hold another
/// interpolation, and a `}` closes the innermost. The spec is explicit that
/// `{{` is not an escape, so there is no second reading of a brace to guess
/// at — a brace inside a string is either `\{` or the start of an
/// interpolation.
pub fn end_of_string(source: string, at: int) -> int {
    if byte_of(source, at) != 34 { return at }
    // 1 = inside a string, 2 = inside interpolation or a nested brace group.
    var stack: List<int> = [1]
    var i: int = at + 1
    for i < source.len() {
        if stack.is_empty() { return i }
        let mode: int = stack[stack.len() - 1]
        let b: int = source.byte_at(i) as int
        if mode == 1 {
            if b == 92 {
                i = i + 2
                continue
            }
            if b == 34 {
                i = i + 1
                stack.pop()
                continue
            }
            if b == 123 {
                i = i + 1
                stack.push(2)
                continue
            }
            i = i + 1
            continue
        }
        let past_comment: int = end_of_comment(source, i)
        if past_comment > i {
            i = past_comment
            continue
        }
        let past_raw: int = end_of_raw_string(source, i)
        if past_raw > i {
            i = past_raw
            continue
        }
        if b == 34 {
            i = i + 1
            stack.push(1)
            continue
        }
        if b == 123 {
            i = i + 1
            stack.push(2)
            continue
        }
        if b == 125 {
            i = i + 1
            stack.pop()
            continue
        }
        i = i + 1
    }
    if stack.is_empty() { return i }
    return source.len()
}

/// Just past whatever non-code thing starts at `at` — a comment, a raw string
/// or a string literal — or `at` itself when code starts there.
///
/// Every walk below is the same loop: skip the noise, then look at one byte.
/// Putting the noise in one function is what keeps the four brace readings in
/// one place instead of four.
pub fn skip_beans_noise(source: string, at: int) -> int {
    let past_comment: int = end_of_comment(source, at)
    if past_comment > at { return past_comment }
    let past_raw: int = end_of_raw_string(source, at)
    if past_raw > at { return past_raw }
    return end_of_string(source, at)
}

/// Just past the balanced group whose opening bracket is at `from`.
///
/// `from` must be a `(`, `[` or `{`. Answers `-1` when the group is never
/// closed, which every caller reports rather than guessing at.
pub fn end_of_group(source: string, from: int) -> int {
    let opener: int = byte_of(source, from)
    if opener != 40 && opener != 91 && opener != 123 { return -1 }
    var depth: int = 0
    var i: int = from
    for i < source.len() {
        let past: int = skip_beans_noise(source, i)
        if past > i {
            i = past
            continue
        }
        let b: int = source.byte_at(i) as int
        if b == 40 || b == 91 || b == 123 {
            depth = depth + 1
            i = i + 1
            continue
        }
        if b == 41 || b == 93 || b == 125 {
            depth = depth - 1
            i = i + 1
            if depth == 0 { return i }
            if depth < 0 { return -1 }
            continue
        }
        i = i + 1
    }
    return -1
}

/// The offset of the `{` that ends a block header started at `from`, or `-1`.
///
/// **A header runs to the first `{` that is not inside parentheses, brackets
/// or a string.** So the opening brace may sit on its own line, and
/// `$if (a + b) > c {` is just an expression that starts with a parenthesis.
/// A closure in a header is safe for the same reason: its braces sit inside
/// the call's parentheses.
///
/// The one shape this ends early is a brace literal at the header's own level
/// — `$if self.m == {1: 2} {` stops at the map. That is a documented
/// ambiguity with a documented escape: wrap the comparison in parentheses.
pub fn find_header_brace(source: string, from: int) -> int {
    var depth: int = 0
    var i: int = from
    for i < source.len() {
        let past: int = skip_beans_noise(source, i)
        if past > i {
            i = past
            continue
        }
        let b: int = source.byte_at(i) as int
        if b == 40 || b == 91 {
            depth = depth + 1
            i = i + 1
            continue
        }
        if b == 41 || b == 93 {
            depth = depth - 1
            if depth < 0 { return -1 }
            i = i + 1
            continue
        }
        if b == 123 && depth == 0 { return i }
        i = i + 1
    }
    return -1
}

/// Just past the implicit expression chain that starts at `at`.
///
/// `at` must be the first byte of an identifier. **The chain continues through
/// `.name`, `(args)` and `[i]` with no space between, and stops at the first
/// character that cannot continue it** — so `$user.name (active)` ends before
/// the space and `$self.clock.now().` keeps the sentence's full stop out of
/// the expression.
pub fn end_of_chain(source: string, at: int) -> int {
    var i: int = at
    for is_ident_byte(byte_of(source, i)) {
        i = i + 1
    }
    if i == at { return at }
    for i < source.len() {
        let b: int = source.byte_at(i) as int
        if b == 46 {
            if !is_ident_start_byte(byte_of(source, i + 1)) { return i }
            i = i + 1
            for is_ident_byte(byte_of(source, i)) {
                i = i + 1
            }
            continue
        }
        if b == 40 || b == 91 {
            let stop: int = end_of_group(source, i)
            if stop < 0 { return i }
            i = stop
            continue
        }
        return i
    }
    return i
}

// -------------------------------------------------- questions about Beans code

/// Whether `code` uses `name` as an identifier of its own.
///
/// Used for one job: refusing markup that spells a generic component's type
/// parameter, which the generated half may never write
/// (`probes/ANSWERS.md` §4). Strings and comments are skipped, and a name that
/// sits straight after a `.` is a *member* rather than a type — so `self.T` is
/// not a use of `T` and `let x: T` is.
pub fn uses_identifier(code: string, name: string) -> bool {
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
        if code.slice(start, i) != name { continue }
        // A member name, not a type name.
        var before: int = start - 1
        for is_space_byte(byte_of(code, before)) {
            before = before - 1
        }
        if byte_of(code, before) == 46 { continue }
        return true
    }
    return false
}

/// Whether `code` reads as a place a value can be written back to.
///
/// An identifier, then any number of `.name` and `[index]` steps, and nothing
/// else — `self.note`, `self.rows[0].title`, `total`. A call is refused,
/// because `bind:value={self.get()}` and `ref={self.find()}` both generate an
/// assignment to a call, and beansc would report that against a file the
/// author never wrote.
pub fn is_place_expression(code: string) -> bool {
    let trimmed: string = code.trim()
    if trimmed.len() == 0 { return false }
    if !is_ident_start_byte(trimmed.byte_at(0) as int) { return false }
    var i: int = 0
    for is_ident_byte(byte_of(trimmed, i)) {
        i = i + 1
    }
    for i < trimmed.len() {
        let b: int = trimmed.byte_at(i) as int
        if b == 46 {
            if !is_ident_start_byte(byte_of(trimmed, i + 1)) { return false }
            i = i + 1
            for is_ident_byte(byte_of(trimmed, i)) {
                i = i + 1
            }
            continue
        }
        if b == 91 {
            let stop: int = end_of_group(trimmed, i)
            if stop < 0 { return false }
            i = stop
            continue
        }
        return false
    }
    return true
}
