// html.b — the HTML rules the markup compiler has to know, and nothing else.
//
// Four groups live here, and each is a table rather than a heuristic:
//
//   * **which tags are which** — void elements have no children and no close
//     tag; raw-text elements (`script`, `style`) hold text that is not markup;
//     a capitalised tag names a component.
//   * **which attributes are boolean** — `disabled` is present or absent, not
//     a string, so it becomes `flag` and never `attr`.
//   * **escaping** — text context and attribute context, spelled once. The
//     constant folder serializes a subtree with these at build time and the
//     runtime serializer must produce the same bytes for the unfolded walk, so
//     the rule is written down here rather than implied twice.
//   * **character references** — resolved at build time, because the frame a
//     reference ends up in is escaped again on the way out. `&amp;` must
//     become `&` here so it can become `&amp;` there; leaving it alone would
//     ship `&amp;amp;`.
//
// An unknown named reference is deliberately *not* an error and is not
// resolved: it stays literal text, is escaped on the way out, and reaches the
// browser as the same characters the author typed — which is exactly what a
// browser does with `&notareference;`. So the table can be incomplete without
// being wrong.

package bx

// ------------------------------------------------------------- tag families

/// Whether `tag` is an HTML void element: no children, no closing tag.
///
/// The HTML5 list. `<div />` is *not* in it, and latte allows the self-closing
/// spelling on any element anyway — this table is what decides whether
/// `<br>` without a slash is an error.
pub fn is_void_element(tag: string) -> bool {
    let name: string = tag.to_lower()
    if name == "area" { return true }
    if name == "base" { return true }
    if name == "br" { return true }
    if name == "col" { return true }
    if name == "embed" { return true }
    if name == "hr" { return true }
    if name == "img" { return true }
    if name == "input" { return true }
    if name == "link" { return true }
    if name == "meta" { return true }
    if name == "source" { return true }
    if name == "track" { return true }
    return name == "wbr"
}

/// Whether `tag` holds raw text rather than markup.
///
/// `script` and `style` only. Their content is not parsed, and interpolation
/// into them is refused: the serializer escapes for *HTML text*, and HTML
/// escaping inside a script is not a defence — `</script>` closes the element
/// from inside a JavaScript string literal, and `&lt;` does not help. The
/// refusal is in parse.b; this table is what tells it which tags to apply to.
///
/// `<beans>` is raw text too, but it is a latte construct rather than an HTML
/// element and the parser handles it on its own.
pub fn is_raw_text_element(tag: string) -> bool {
    let name: string = tag.to_lower()
    if name == "script" { return true }
    return name == "style"
}

/// Whether a tag names a component rather than an HTML element.
///
/// The last dotted segment decides, so `Hint` and `ui.Button` are components
/// and `div` and `my-widget` are not. There is no component registry: the
/// compiler emits the name and beansc resolves it, so a component is imported
/// like anything else.
pub fn names_a_component(tag: string) -> bool {
    let parts: List<string> = tag.split(".")
    let last: string = parts[parts.len() - 1]
    if last.len() == 0 { return false }
    let first: int = last.byte_at(0) as int
    return first >= 65 && first <= 90
}

/// Whether an attribute is boolean: present or absent, never a string.
///
/// The HTML5 list of boolean content attributes. A boolean attribute becomes
/// `b.flag(seq, name, present)` rather than `b.attr`, because `disabled="false"`
/// is a *disabled* control in every browser and writing the string would be a
/// silent bug. `parse.b` refuses the string form for exactly that reason.
pub fn is_boolean_attribute(name: string) -> bool {
    let lower: string = name.to_lower()
    if lower == "allowfullscreen" { return true }
    if lower == "async" { return true }
    if lower == "autofocus" { return true }
    if lower == "autoplay" { return true }
    if lower == "checked" { return true }
    if lower == "controls" { return true }
    if lower == "default" { return true }
    if lower == "defer" { return true }
    if lower == "disabled" { return true }
    if lower == "formnovalidate" { return true }
    if lower == "inert" { return true }
    if lower == "ismap" { return true }
    if lower == "itemscope" { return true }
    if lower == "loop" { return true }
    if lower == "multiple" { return true }
    if lower == "muted" { return true }
    if lower == "nomodule" { return true }
    if lower == "novalidate" { return true }
    if lower == "open" { return true }
    if lower == "playsinline" { return true }
    if lower == "readonly" { return true }
    if lower == "required" { return true }
    if lower == "reversed" { return true }
    return lower == "selected"
}

/// Whether an attribute name is one of latte's own rather than HTML's.
///
/// These never reach the wire as attributes; each becomes a different builder
/// call. Listed in one place so a diagnostic can say "`key` is latte's" rather
/// than emitting it as an HTML attribute nobody asked for.
pub fn is_reserved_attribute(name: string) -> bool {
    if name == "key" { return true }
    if name == "ref" { return true }
    if name == "attrs" { return true }
    if name == "preserve" { return true }
    return name == "live"
}

/// Whether an attribute name is an inline script handler.
///
/// Every HTML event handler content attribute is `on` followed by the event
/// name, so the prefix is the whole test. latte refuses all of them: a handler
/// exists only as an id, and the client never evaluates a string. `on:click`
/// is not caught by this because the parser has already split it on the colon
/// before asking.
pub fn is_inline_handler_attribute(name: string) -> bool {
    let lower: string = name.to_lower()
    if lower.len() < 3 { return false }
    if !lower.starts_with("on") { return false }
    // `on` followed by ASCII letters and nothing else: `onclick`, `onload`.
    // `on-foo` and `on_foo` are not HTML handler attributes.
    var i: int = 2
    for i < lower.len() {
        let b: int = lower.byte_at(i) as int
        if b < 97 || b > 122 { return false }
        i = i + 1
    }
    return true
}

// ------------------------------------------------------------------ escaping
//
// Two contexts, two tables, and both are the contract with the runtime
// serializer: a folded constant subtree is serialized here at build time and
// the unfolded walk is serialized there at run time, and the two must produce
// the same bytes or `fold` changes what a page says.

/// Escape for HTML text content: `&`, `<` and `>`.
///
/// `>` is escaped even though a lone `>` in text is legal, because it costs
/// three bytes and removes a class of question about `]]>` and about text that
/// was pasted out of a CDATA section.
pub fn escape_text(value: string) -> string {
    let parts: List<string> = []
    var run: int = 0
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        var replacement: string = ""
        if b == 38 { replacement = "&amp;" }
        if b == 60 { replacement = "&lt;" }
        if b == 62 { replacement = "&gt;" }
        if replacement != "" {
            parts.push(value.slice(run, i))
            parts.push(replacement)
            run = i + 1
        }
        i = i + 1
    }
    if run == 0 { return value }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

/// Escape for a double-quoted attribute value: text's three, plus `"` and `'`.
///
/// The single quote is escaped as well even though latte always writes double
/// quotes, so a value that is later re-quoted by anything else is still safe.
pub fn escape_attribute(value: string) -> string {
    let parts: List<string> = []
    var run: int = 0
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        var replacement: string = ""
        if b == 38 { replacement = "&amp;" }
        if b == 60 { replacement = "&lt;" }
        if b == 62 { replacement = "&gt;" }
        if b == 34 { replacement = "&quot;" }
        if b == 39 { replacement = "&#39;" }
        if replacement != "" {
            parts.push(value.slice(run, i))
            parts.push(replacement)
            run = i + 1
        }
        i = i + 1
    }
    if run == 0 { return value }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

/// Escape `value` so it can sit inside a Beans double-quoted string literal.
///
/// Every byte that Beans would read as syntax is spelled out: the backslash,
/// the quote, and **both braces** — a `{` in a generated literal would open an
/// interpolation and a `}` would close one, so a piece of author text holding
/// a brace has to arrive as `\{` and `\}`. Control bytes go out as `\xNN`
/// rather than as themselves, so a generated file has no raw newline inside a
/// string literal and stays one statement per line.
///
/// Bytes at or above 0x80 pass through untouched: a Beans string is UTF-8 and
/// re-encoding valid text would only be a chance to get it wrong.
pub fn escape_beans_string(value: string) -> string {
    let parts: List<string> = []
    var run: int = 0
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        var replacement: string = ""
        if b == 92 { replacement = "\\\\" }
        if b == 34 { replacement = "\\\"" }
        if b == 123 { replacement = "\\\{" }
        if b == 125 { replacement = "\\\}" }
        if b == 10 { replacement = "\\n" }
        if b == 9 { replacement = "\\t" }
        if b == 13 { replacement = "\\r" }
        if b == 0 { replacement = "\\0" }
        if replacement == "" && b < 32 {
            replacement = "\\x{hex_byte(b)}"
        }
        if b == 127 { replacement = "\\x7f" }
        if replacement != "" {
            parts.push(value.slice(run, i))
            parts.push(replacement)
            run = i + 1
        }
        i = i + 1
    }
    if run == 0 { return value }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

/// Two lowercase hex digits for a byte.
pub fn hex_byte(value: int) -> string {
    let digits: string = "0123456789abcdef"
    let hi: int = (value / 16) % 16
    let lo: int = value % 16
    return "{digits.slice(hi, hi + 1)}{digits.slice(lo, lo + 1)}"
}

// -------------------------------------------------------- character references

/// Resolve HTML character references in `value` to the characters they name.
///
/// Called on every literal text run and every literal attribute value, once,
/// on the way *in*. The result is characters, not HTML, and it is escaped
/// again on the way out — so `&amp;` becomes `&` becomes `&amp;`, and `&lt;`
/// becomes `<` becomes `&lt;`, both of which is what the author meant.
///
/// An unknown reference is left exactly as written and therefore survives the
/// round trip as literal text: `&notareference;` escapes to
/// `&amp;notareference;` and a browser renders `&notareference;`, which is
/// what a browser does with the same input. That is why the named table below
/// may be incomplete without being wrong, and why a name it does not know is
/// not a diagnostic.
pub fn resolve_references(value: string) -> string {
    if value.find_byte(38, 0) < 0 { return value }
    let parts: List<string> = []
    var run: int = 0
    var i: int = 0
    for i < value.len() {
        if value.byte_at(i) as int != 38 {
            i = i + 1
            continue
        }
        let end: int = value.find_byte(59, i + 1)
        if end < 0 { break }
        // A reference is short. Anything longer than the longest name in the
        // table is a stray ampersand followed by a semicolon much later in the
        // line, and scanning it as a name would swallow real text.
        if end - i > 34 {
            i = i + 1
            continue
        }
        let body: string = value.slice(i + 1, end)
        let resolved: string = reference_value(body)
        if resolved == "" {
            i = i + 1
            continue
        }
        parts.push(value.slice(run, i))
        parts.push(resolved)
        run = end + 1
        i = end + 1
    }
    if run == 0 { return value }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

/// What the body of one reference stands for, or `""` when it is not one.
///
/// `body` is what sits between the `&` and the `;`.
fn reference_value(body: string) -> string {
    if body.len() == 0 { return "" }
    if body.byte_at(0) as int == 35 {
        return numeric_reference(body)
    }
    let point: int = named_reference(body)
    if point < 0 { return "" }
    return encode_utf8(point)
}

/// `#38` and `#x26`, the two numeric forms.
///
/// A value outside Unicode, or in the surrogate range, is not a character and
/// is left as literal text rather than encoded as something else — the same
/// answer the table gives for a name it does not know, so there is one rule
/// for "this is not a reference" and not two.
fn numeric_reference(body: string) -> string {
    var digits: string = body.slice(1, body.len())
    var base: int = 10
    if digits.len() > 1 {
        let marker: int = digits.byte_at(0) as int
        if marker == 120 || marker == 88 {
            base = 16
            digits = digits.slice(1, digits.len())
        }
    }
    if digits.len() == 0 { return "" }
    if digits.len() > 8 { return "" }
    var point: int = 0
    var i: int = 0
    for i < digits.len() {
        let value: int = hex_digit(digits.byte_at(i) as int)
        if value < 0 || value >= base { return "" }
        point = point * base + value
        i = i + 1
    }
    if point < 0 { return "" }
    if point > 1114111 { return "" }
    if point >= 55296 && point <= 57343 { return "" }
    return encode_utf8(point)
}

/// The value of one hex digit, or `-1`.
fn hex_digit(b: int) -> int {
    if b >= 48 && b <= 57 { return b - 48 }
    if b >= 97 && b <= 102 { return b - 87 }
    if b >= 65 && b <= 70 { return b - 55 }
    return -1
}

/// One Unicode scalar as UTF-8.
pub fn encode_utf8(point: int) -> string {
    if point < 0 { return "" }
    if point < 128 {
        // A reference that names an HTML syntax character comes back as that
        // character and nothing else: `&amp;` means the author wanted an
        // ampersand *as text*, and a bare `&` is right here only because the
        // caller escapes it again on the way out. `&#60;` is the same case,
        // which is why it needs no special arm.
        return one_byte(point)
    }
    if point < 2048 {
        let b0: int = 192 + (point / 64)
        let b1: int = 128 + (point % 64)
        return "{one_byte(b0)}{one_byte(b1)}"
    }
    if point < 65536 {
        let b0: int = 224 + (point / 4096)
        let b1: int = 128 + ((point / 64) % 64)
        let b2: int = 128 + (point % 64)
        return "{one_byte(b0)}{one_byte(b1)}{one_byte(b2)}"
    }
    let b0: int = 240 + (point / 262144)
    let b1: int = 128 + ((point / 4096) % 64)
    let b2: int = 128 + ((point / 64) % 64)
    let b3: int = 128 + (point % 64)
    return "{one_byte(b0)}{one_byte(b1)}{one_byte(b2)}{one_byte(b3)}"
}

/// One raw byte as a one-byte string.
///
/// Built through a table rather than through `\x{...}` because Beans resolves
/// an escape at compile time and this value is not known then.
fn one_byte(value: int) -> string {
    let table: string = ascii_table()
    if value >= 0 && value < 128 {
        return table.slice(value, value + 1)
    }
    return high_byte(value)
}

/// The 128 ASCII bytes, in order, as one string to slice out of.
fn ascii_table() -> string {
    return "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz\{|\}~\x7f"
}

/// One byte at or above 0x80, as a one-byte string.
fn high_byte(value: int) -> string {
    let table: string = high_table()
    let index: int = value - 128
    if index < 0 || index >= 128 { return "" }
    return table.slice(index, index + 1)
}

/// The 128 bytes from 0x80 to 0xff, in order. Not valid UTF-8 on its own,
/// which is fine: a string in Beans is binary-safe, and these bytes are only
/// ever sliced out one at a time to be joined back into a valid sequence.
fn high_table() -> string {
    return "\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff"
}

/// The Unicode scalar a named reference stands for, or `-1` when the table
/// does not have it.
///
/// The table is the HTML names that appear in running text, not all 2,231 of
/// them. A name it does not know is left as literal text and round-trips, so
/// the cost of an omission is that `&hearts;` reaches the browser as the
/// characters `&hearts;` rather than as a heart — visible, not silent, and
/// fixable by writing `&#9829;`, which this does know.
fn named_reference(name: string) -> int {
    // The five that HTML syntax itself needs.
    if name == "amp" { return 38 }
    if name == "lt" { return 60 }
    if name == "gt" { return 62 }
    if name == "quot" { return 34 }
    if name == "apos" { return 39 }
    // Spaces.
    if name == "nbsp" { return 160 }
    if name == "ensp" { return 8194 }
    if name == "emsp" { return 8195 }
    if name == "thinsp" { return 8201 }
    if name == "shy" { return 173 }
    // Punctuation and typography.
    if name == "ndash" { return 8211 }
    if name == "mdash" { return 8212 }
    if name == "lsquo" { return 8216 }
    if name == "rsquo" { return 8217 }
    if name == "sbquo" { return 8218 }
    if name == "ldquo" { return 8220 }
    if name == "rdquo" { return 8221 }
    if name == "bdquo" { return 8222 }
    if name == "dagger" { return 8224 }
    if name == "Dagger" { return 8225 }
    if name == "bull" { return 8226 }
    if name == "hellip" { return 8230 }
    if name == "permil" { return 8240 }
    if name == "prime" { return 8242 }
    if name == "Prime" { return 8243 }
    if name == "lsaquo" { return 8249 }
    if name == "rsaquo" { return 8250 }
    if name == "laquo" { return 171 }
    if name == "raquo" { return 187 }
    if name == "middot" { return 183 }
    if name == "iexcl" { return 161 }
    if name == "iquest" { return 191 }
    if name == "brvbar" { return 166 }
    if name == "sect" { return 167 }
    if name == "uml" { return 168 }
    if name == "ordf" { return 170 }
    if name == "not" { return 172 }
    if name == "macr" { return 175 }
    if name == "acute" { return 180 }
    if name == "para" { return 182 }
    if name == "cedil" { return 184 }
    if name == "ordm" { return 186 }
    // Currency.
    if name == "cent" { return 162 }
    if name == "pound" { return 163 }
    if name == "curren" { return 164 }
    if name == "yen" { return 165 }
    if name == "euro" { return 8364 }
    // Legal and units.
    if name == "copy" { return 169 }
    if name == "reg" { return 174 }
    if name == "trade" { return 8482 }
    if name == "deg" { return 176 }
    if name == "micro" { return 181 }
    if name == "plusmn" { return 177 }
    if name == "sup1" { return 185 }
    if name == "sup2" { return 178 }
    if name == "sup3" { return 179 }
    if name == "frac14" { return 188 }
    if name == "frac12" { return 189 }
    if name == "frac34" { return 190 }
    if name == "szlig" { return 223 }
    // Maths.
    if name == "times" { return 215 }
    if name == "divide" { return 247 }
    if name == "minus" { return 8722 }
    if name == "lowast" { return 8727 }
    if name == "ne" { return 8800 }
    if name == "le" { return 8804 }
    if name == "ge" { return 8805 }
    if name == "asymp" { return 8776 }
    if name == "equiv" { return 8801 }
    if name == "infin" { return 8734 }
    if name == "sum" { return 8721 }
    if name == "prod" { return 8719 }
    if name == "radic" { return 8730 }
    if name == "part" { return 8706 }
    if name == "int" { return 8747 }
    if name == "there4" { return 8756 }
    // Arrows.
    if name == "larr" { return 8592 }
    if name == "uarr" { return 8593 }
    if name == "rarr" { return 8594 }
    if name == "darr" { return 8595 }
    if name == "harr" { return 8596 }
    if name == "crarr" { return 8629 }
    // Greek, the letters that appear in running text.
    if name == "alpha" { return 945 }
    if name == "beta" { return 946 }
    if name == "gamma" { return 947 }
    if name == "delta" { return 948 }
    if name == "epsilon" { return 949 }
    if name == "theta" { return 952 }
    if name == "lambda" { return 955 }
    if name == "mu" { return 956 }
    if name == "pi" { return 960 }
    if name == "rho" { return 961 }
    if name == "sigma" { return 963 }
    if name == "tau" { return 964 }
    if name == "phi" { return 966 }
    if name == "omega" { return 969 }
    if name == "Gamma" { return 915 }
    if name == "Delta" { return 916 }
    if name == "Theta" { return 920 }
    if name == "Lambda" { return 923 }
    if name == "Pi" { return 928 }
    if name == "Sigma" { return 931 }
    if name == "Phi" { return 934 }
    if name == "Omega" { return 937 }
    return -1
}
