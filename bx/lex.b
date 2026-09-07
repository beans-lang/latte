// lex.b — the bytes of a `.bx` tag, and nothing else.
//
// Not a translation of anything: gpui has no markup layer. This is the front
// half of `bx`, and its whole job is to turn the byte range that a tag
// occupies into tokens `parse.b` can read, while never once looking at the
// Beans around it. A `.bx` file is a Beans file with tags in it; everything
// outside a tag is opaque text the driver passes through untouched, so this
// lexer is handed a starting offset and stops the moment the tag it was asked
// for ends. It is deliberately not a Beans lexer — beansc is, and beansc will
// give a better error about Beans than we would.
//
// **Why a cursor and not a token stream over the whole file.** A `.bx` file
// has no global token grammar: the same `<` that opens a tag is a less-than
// four lines earlier. Position, therefore, is an input — `Lexer.at(src, from)`
// — and the lexer stops at the byte after the tag's last `>` rather than
// running to EOF. `parse.b` reads one token ahead *lazily* for exactly this
// reason: an eager lookahead would scan the opaque Beans that follows a tag
// and could invent a diagnostic in code this package has no business reading.
//
// **Why the scanning is done in byte ranges.** `slice` allocates. A lexer that
// slices to test a byte allocates once per byte for nothing, so every scan
// here walks `byte_at` and slices exactly once, at the end, to produce the
// token's text. `find_byte` is used where a scan really is "run to the next
// occurrence of one byte".
//
// **The hard part is `{...}`.** The code between braces is arbitrary Beans;
// Beans strings can contain braces; Beans string *interpolation* contains
// braces and can contain further strings; and `\{` is an escape. Counting
// braces without tracking any of that ends `on:click={fn(e: int) {
// io.println("clicked {e}") }}` in the middle of the handler. `scan_code`
// therefore runs a three-mode stack — see the comment on it. That one routine
// is the reason the lexer is its own file.

package bx

// ------------------------------------------------------------- diagnostics

/// One thing that is wrong with the source, and where.
///
/// A class rather than a struct because it is stored in a `List` and handed
/// around by reference; nothing copies one. The message is the *body* of a
/// beansc-shaped diagnostic — `show()` puts the position and the `error:`
/// label on the front, so every producer writes one half and the format lives
/// in one place.
///
/// The house style for the body is `<what is wrong> — <what to do about it>`.
/// A diagnostic that only says what is wrong makes the reader guess, and the
/// entire reason a markup layer beats a fluent chain is that it can point at
/// the line and say what to type instead.
pub class Diag {
    /// Where the fault is, one-based.
    pub span: Span = Span.at(1, 1)
    /// `<what is wrong> — <what to do about it>`.
    pub message: string = ""

    pub fn init(span: Span, message: string) {
        self.span = span
        self.message = message
    }

    /// A diagnostic at `span`.
    pub static fn of(span: Span, message: string) -> Diag {
        return new Diag(span, message)
    }

    /// `line:col: error: <message>`, the form every beansc diagnostic uses.
    pub fn show() -> string {
        return "{self.span.show()}: error: {self.message}"
    }
}

// ------------------------------------------------------------------ tokens

/// What a token is.
///
/// `enum(u8)` because a `Token` is built once per name, quote and brace in a
/// file and the tag is the only field that is not already a reference; there
/// is no reason to give it a heap box. There is no `_` arm anywhere that
/// matches one, so adding a kind is a compile error at every decision point,
/// which is what we want from a lexer's own vocabulary.
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
    /// A tag or attribute name. See `is_name_byte` for what one may contain.
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
///
/// `end` is carried because the parser must be able to say where the tag
/// stopped without asking the lexer, which by then may have read ahead.
pub class Token {
    /// What it is.
    pub kind: TokenKind = TokenKind.eof
    /// For `name`, the name; for `text`, the contents with escapes resolved;
    /// for `code`, the code between the braces. Empty for the rest.
    pub value: string = ""
    /// For `text`, the contents exactly as written, escapes unresolved.
    /// Empty for every other kind. Both forms are kept because `bx` needs
    /// both: a `TextAttr` value is read by the attribute table at compile
    /// time and wants the resolved form, while a `TextNode` is re-emitted as
    /// a Beans literal and wants the raw one (see the comment on `TextNode`
    /// in ast.b).
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

    /// A token. The factory form, to match the one every node in ast.b has.
    pub static fn of(kind: TokenKind, value: string, raw: string, span: Span, end: int) -> Token {
        return new Token(kind, value, raw, span, end)
    }

    /// How to name this token inside a diagnostic, as in "found ..." or
    /// "... is not a child of <div>".
    ///
    /// Separate from `TokenKind.show()` because the *token* knows things the
    /// kind does not: which name it is, and which character was unexpected. A
    /// diagnostic that says "an unexpected character" and then does not say
    /// which one makes the reader count columns, which is exactly the work a
    /// diagnostic exists to save.
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
    ///
    /// Every variant is listed because a `match` over an enum takes no `_`
    /// arm, which is the rule that makes a new `TokenKind` a compile error
    /// here rather than a token that quietly prints as something else.
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

/// A cursor over one `.bx` source, producing tag tokens on demand.
///
/// It owns the diagnostic list for a whole parse, because the parser and the
/// lexer both raise them and a caller wants one list in source order. Nothing
/// here ever panics or returns `Result`: a lexer that stopped at the first
/// fault would report one error per run, and the diagnostics a markup layer
/// exists to give are worth more in bulk.
pub class Lexer {
    /// The whole file. The lexer never reads outside the tag it is in, but it
    /// needs the whole string to slice out of.
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
    ///
    /// The count is one pass over the bytes before `from`, done once per tag.
    /// A driver that already knows the position should use `seek_at` instead
    /// and skip it.
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

    /// Move to byte `from`, trusting the caller's line and column. For a
    /// driver that scanned the file itself and already knows where it is.
    pub fn seek_at(from: int, line: int, col: int) {
        self.off = clamp_offset(from, self.src.len())
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

    /// The byte under the cursor, or `-1` at the end. `-1` rather than an
    /// `Option` because every caller is a comparison in a loop and an
    /// `Option` match per byte buys nothing.
    pub fn peek() -> int {
        return self.byte_ahead(0)
    }

    /// The byte `ahead` positions on, or `-1` past the end.
    pub fn byte_ahead(ahead: int) -> int {
        let i: int = self.off + ahead
        if i >= self.src.len() {
            return -1
        }
        return self.src.byte_at(i) as int
    }

    /// Step over one byte, keeping the line and column true.
    pub fn bump() {
        if self.at_end() {
            return
        }
        if self.src.byte_at(self.off) as int == 10 {
            self.line = self.line + 1
            self.col = 1
        } else {
            self.col = self.col + 1
        }
        self.off = self.off + 1
    }

    /// Step over spaces, tabs, carriage returns and newlines.
    ///
    /// Comments are deliberately not skipped. `//` inside a tag would have to
    /// mean something, and until someone asks for it, a tag that contains one
    /// gets an "unexpected character" pointing straight at it rather than a
    /// silently dropped attribute.
    pub fn skip_space() {
        for !self.at_end() {
            let b: int = self.peek()
            if !is_space_byte(b) {
                return
            }
            self.bump()
        }
    }

    /// The next token, whatever the cursor is looking at.
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
            // `<` or `</`
            self.bump()
            if self.peek() == 47 {
                self.bump()
                return Token.of(TokenKind.close_start, "", "", at, self.off)
            }
            return Token.of(TokenKind.open_start, "", "", at, self.off)
        }
        if b == 62 {
            // `>`
            self.bump()
            return Token.of(TokenKind.tag_end, "", "", at, self.off)
        }
        if b == 47 {
            // `/>` — a lone `/` here is not part of a name, because a name's
            // `/` (as in the step `1/2`) is only a name byte when a name byte
            // follows it, and `>` is not one.
            if self.byte_ahead(1) == 62 {
                self.bump()
                self.bump()
                return Token.of(TokenKind.self_close, "", "", at, self.off)
            }
            self.bump()
            return Token.of(TokenKind.unknown, "/", "", at, self.off)
        }
        if b == 61 {
            // `=`
            self.bump()
            return Token.of(TokenKind.equals, "", "", at, self.off)
        }
        if b == 34 {
            // `"`
            return self.scan_text(at)
        }
        if b == 123 {
            // `{`
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
    ///
    /// The `/` rule is the only interesting part: `w-1/2` is one name and
    /// `<br/>` is a name followed by `/>`, so a `/` joins the name only when
    /// a name byte follows it. That is unambiguous in both directions and
    /// needs no lookahead past one byte.
    fn scan_name(at: Span) -> Token {
        let start: int = self.off
        for !self.at_end() {
            let b: int = self.peek()
            if is_name_byte(b) {
                self.bump()
                continue
            }
            if b == 47 && is_name_byte(self.byte_ahead(1)) {
                self.bump()
                continue
            }
            break
        }
        let text: string = self.src.slice(start, self.off)
        return Token.of(TokenKind.name, text, "", at, self.off)
    }

    /// Scan a `"..."` literal, producing the raw contents and the resolved
    /// contents in one pass.
    ///
    /// A raw newline ends the literal, exactly as it does in Beans: it turns
    /// a missing quote into an error on the line that has it rather than a
    /// cascade fifty lines further down, and it gives the recovery a natural
    /// place to resume.
    ///
    /// One documented limit: the literal ends at the first unescaped `"`, so
    /// a Beans interpolation inside it may not itself contain a string —
    /// `"{f("x")}"` is not understood here. Write the value as a `{...}` hole
    /// instead. Recognising it would mean parsing Beans, which this package
    /// deliberately does not do.
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
            if b == 10 {
                break
            }
            if b != 92 {
                self.bump()
                continue
            }
            // A backslash escape. Flush the plain run, then the replacement.
            pieces.push(self.src.slice(run, self.off))
            let esc: Span = self.span()
            self.bump()
            if self.at_end() {
                break
            }
            if self.peek() == 10 {
                break
            }
            let e: int = self.peek()
            self.bump()
            pieces.push(self.escape_value(e, esc))
            run = self.off
        }
        let stop: int = self.off
        pieces.push(self.src.slice(run, stop))
        let raw: string = self.src.slice(start, stop)
        let joined: string = ""
        let value: string = pieces.join(joined)
        if closed {
            self.bump()
        } else {
            self.report(at, "a string literal was never closed — add the missing \" before the end of the line")
        }
        return Token.of(TokenKind.text, value, raw, at, self.off)
    }

    /// What one escape stands for. An escape Beans does not have is reported
    /// and passed through as written, so nothing is lost silently.
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
        self.report(at, "\\{written} is not an escape — Beans has \\n \\t \\r \\0 \\\\ \\\" \\\{ and \\\}")
        return self.src.slice(self.off - 2, self.off)
    }

    /// Scan a `{...}` region and answer the code between the braces.
    ///
    /// This is the routine the whole file is shaped around. Counting braces
    /// naively ends the region in the middle of a handler, because the code
    /// can be any Beans at all:
    ///
    ///     on:click=\{fn(e: int) \{ io.println("clicked \{e\}") \}\}
    ///
    /// Four constructs nest here and each changes what a brace means, so the
    /// scan carries a stack of what is currently open:
    ///
    ///   * **code** — ordinary Beans. `\{` opens another code level, `\}`
    ///     closes one, and closing the last one ends the region. `"` opens a
    ///     string.
    ///   * **string** — inside `"..."`. A `\` escapes the next byte, so `"\}"`
    ///     and `"\\"` count for nothing. A `"` closes it. An unescaped `\{`
    ///     opens an interpolation, because the spec says it must (SYNTAX.md,
    ///     "Strings": `\{\{` is not an escape, a brace inside a string is
    ///     either `\\\{` or the start of an interpolation).
    ///   * **interpolation** — the code inside a string's `\{...\}`. `\}`
    ///     closes it, `"` opens a nested string, `\{` opens a map literal,
    ///     which is code again.
    ///
    /// Because the three refer to each other, the stack is what makes it
    /// finite. `"\}"` inside a handler, a `\{` escape, and an interpolation
    /// that itself contains a string all fall out of it rather than each
    /// needing a special case.
    ///
    /// The code is handed on verbatim. `bx` does not parse Beans, and beansc
    /// will say something better about a malformed expression than a guess
    /// from here would.
    fn scan_code(at: Span) -> Token {
        self.bump()
        let start: int = self.off
        // 0 = code, 1 = string, 2 = an interpolation inside a string.
        var mode: int = 0
        var stack: List<int> = []
        var closed: bool = false
        for !self.at_end() {
            let b: int = self.peek()
            if mode == 1 {
                if b == 92 {
                    self.bump()
                    self.bump()
                    continue
                }
                if b == 34 {
                    self.bump()
                    mode = pop_mode(stack)
                    continue
                }
                if b == 123 {
                    self.bump()
                    stack.push(mode)
                    mode = 2
                    continue
                }
                self.bump()
                continue
            }
            // Code, or the code inside an interpolation: the two agree on
            // every byte that matters, and differ only in what an unmatched
            // `}` means, which the stack already answers.
            if b == 34 {
                self.bump()
                stack.push(mode)
                mode = 1
                continue
            }
            if b == 123 {
                self.bump()
                stack.push(mode)
                mode = 0
                continue
            }
            if b == 125 {
                self.bump()
                if stack.is_empty() {
                    closed = true
                    break
                }
                mode = pop_mode(stack)
                continue
            }
            self.bump()
        }
        var stop: int = self.off
        if closed {
            stop = self.off - 1
        } else {
            self.report(at, "a \{...\} value was never closed — add the missing \} (a \} inside a string does not close it)")
        }
        let code: string = self.src.slice(start, stop)
        return Token.of(TokenKind.code, code, "", at, self.off)
    }
}

// ----------------------------------------------------------------- helpers

/// The mode under the top of the stack, or code when the stack ran dry.
///
/// It cannot run dry in practice — a string or an interpolation is only ever
/// pushed on top of something — but `pop` answers an `Option` and a lexer
/// that panics in library code is not an option at all.
fn pop_mode(stack: List<int>) -> int {
    return match stack.pop() {
        some(v) => v,
        none => 0,
    }
}

/// `from`, held inside `0..len`.
fn clamp_offset(from: int, len: int) -> int {
    if from < 0 {
        return 0
    }
    if from > len {
        return len
    }
    return from
}

/// The byte at `at`, or `-1` when `at` is outside `source`.
///
/// A free function because a driver scanning a `.bx` file for the `<` that
/// opens a tag needs exactly this and has no lexer yet.
pub fn byte_of(source: string, at: int) -> int {
    if at < 0 {
        return -1
    }
    if at >= source.len() {
        return -1
    }
    return source.byte_at(at) as int
}

/// Whether a byte is whitespace between tokens.
pub fn is_space_byte(v: int) -> bool {
    if v == 32 { return true }
    if v == 9 { return true }
    if v == 10 { return true }
    return v == 13
}

/// Whether a byte may start a name: an ASCII letter or `_`.
///
/// A digit deliberately may not, so a stray number in a tag is an
/// "unexpected character" rather than a nameless attribute, and so a leading
/// hyphen (Tailwind's own negative form, `-mt-4`) is refused with a position
/// instead of silently becoming a family called `_mt`. crema writes a
/// negative step as `m-neg-4`; see `split_ramp` in parse.b.
pub fn is_name_start_byte(v: int) -> bool {
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    return v == 95
}

/// Whether a byte may continue a name.
///
/// Letters, digits, `_`, `-`, `.` and `:`. The hyphen is what makes `gap-2`
/// one token; the colon is what makes `on:click` one token, so an attribute
/// namespace is a *parse* decision rather than three tokens the parser has to
/// reassemble. The dot is here so a tag may one day be package-qualified
/// (`<ui.Button>`) without a lexer change. `/` is handled by `scan_name`
/// because it depends on what follows it.
pub fn is_name_byte(v: int) -> bool {
    if v >= 48 && v <= 57 { return true }
    if v >= 65 && v <= 90 { return true }
    if v >= 97 && v <= 122 { return true }
    if v == 95 { return true }
    if v == 45 { return true }
    if v == 46 { return true }
    return v == 58
}
