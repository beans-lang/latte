// Frames — what a `render(b: Builder)` writes, and the rules for turning one
// into HTML text.
//
// A frame is an ENUM variant, not a struct and not a class. Beans matches an
// enum exhaustively, so adding a frame kind is a compile error in every
// walker — serializer, differ, applier, dump — rather than a kind one of
// them silently ignores. It is also what probes/p8_builder compiled and ran
// on both backends.
//
// Nothing here imports std.io, std.fs or std.net. See beans.pot.
package latte

import std.fmt

// ---------------------------------------------------------------- frames
//
// A frame's `seq` is a SOURCE POSITION, never a counter. Two frames with the
// same seq in two renders of one component describe the same source position,
// which is the whole basis of the diff.
pub enum Frame {
    /// `<tag`. Attributes follow immediately; children follow those; `close`
    /// ends it. A void element still gets its `close` frame — the serializer
    /// is what knows not to write `</input>`.
    open(seq: int, tag: string)

    /// `name="value"`. `value` is the RAW text; escaping is the serializer's
    /// job, so one escaper serves the frame walk and the applier alike.
    attribute(seq: int, name: string, value: string)

    /// A boolean attribute: present or absent, never `="false"`.
    flag(seq: int, name: string, present: bool)

    /// `attrs={map}`. Followed by exactly `count` `attribute` frames carrying
    /// this same seq, sorted by name — Map has no iteration order, so sorting
    /// is what stops one render's HTML differing from the next's.
    splat(seq: int, count: int)

    /// Interpolated text. Escaped for its element's context.
    text(seq: int, body: string)

    /// `$html(expr)` — author-supplied, unescaped. The only bypass there is.
    raw(seq: int, html: string)

    /// A subtree with no expression anywhere inside it, serialized at build
    /// time by the markup compiler. Trusted: it is compiler output, unlike
    /// `raw`. Serializing it is a copy; diffing it does not walk the subtree.
    constant(seq: int, html: string)

    /// An event handler. `id` is the SLOT id — the wire id — not the seq: a
    /// handler inside a keyed region has one seq and N rows.
    handler(seq: int, event: string, id: int)

    /// A mounted child component. A LEAF in this component's frame list: the
    /// child's frames live in the child's own buffer, reachable through
    /// `Builder.nested[id]`. `id` is the child's slot id, which is also its
    /// component id.
    child(seq: int, type_name: string, id: int)

    /// A keyed row. `seq` names the LOOP and is the same for every row; `key`
    /// names the row. Sequence numbers restart at 0 inside. A transparent
    /// container: it serializes to nothing of its own.
    region_open(seq: int, key: string)
    region_close

    /// `$slot` — child content placed by the parent, numbered in the PARENT's
    /// space, which is why it is its own numbering scope. Also transparent.
    fragment_open(seq: int)
    fragment_close

    /// An error boundary. `failed` is rewritten to true when the body panicked
    /// and was replaced by fallback content, so old-failed vs new-ok is a
    /// content replacement to the differ rather than a silent match.
    boundary_open(seq: int, failed: bool)
    boundary_close

    /// `ref={...}` and `preserve`. Neither writes HTML.
    reference(seq: int)
    preserve(seq: int)

    close
}

/// A frame list behind a class, because `List<T>` is move-only and a field
/// holding one can be neither moved out nor returned — so `previous = frames`
/// has no spelling for a bare list. A class field is a reference and assigns.
pub class Frames {
    pub items: List<Frame> = []
    pub fn init() {}

    pub fn len() -> int { return self.items.len() }
    pub fn push(frame: Frame) { self.items.push(frame) }
    pub fn at(index: int) -> Frame { return self.items[index] }
    pub fn clear() { self.items.clear() }

    /// Rewrite one frame in place. The only caller is a live binding replacing
    /// the body of the text frame it owns (`signal.b`): the frame LIST is not
    /// changing — no frame is added, removed or reordered — so nothing the
    /// differ, the serializer or the applier reads about structure moves. A
    /// caller that wanted to change a frame's KIND or seq would be changing the
    /// structure and must render instead.
    pub fn set(index: int, frame: Frame) { self.items[index] = frame }

    /// One frame per line, indented by depth. A one-line dump is unreadable in
    /// a failing diff, and a golden file is read by a person exactly once —
    /// when it breaks.
    pub fn dump() -> string {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        var depth: int = 0
        var index: int = 0
        for index < self.items.len() {
            let frame: Frame = self.items[index]
            match frame {
                close => { depth -= 1 }
                region_close => { depth -= 1 }
                fragment_close => { depth -= 1 }
                boundary_close => { depth -= 1 }
                _ => {}
            }
            if depth < 0 { depth = 0 }
            out.push("  ".repeat(depth))
            out.push(describe_frame(frame))
            out.push("\n")
            match frame {
                open(_, _) => { depth += 1 }
                region_open(_, _) => { depth += 1 }
                fragment_open(_) => { depth += 1 }
                boundary_open(_, _) => { depth += 1 }
                _ => {}
            }
            index += 1
        }
        return out.to_string()
    }
}

pub fn describe_frame(frame: Frame) -> string {
    match frame {
        open(seq, tag) => { return "{seq} open {tag}" }
        attribute(seq, name, value) => { return "{seq} attr {name}={value}" }
        flag(seq, name, present) => { return "{seq} flag {name}={present}" }
        splat(seq, count) => { return "{seq} splat {count}" }
        text(seq, body) => { return "{seq} text {body}" }
        raw(seq, html) => { return "{seq} raw {html}" }
        constant(seq, html) => { return "{seq} const {html}" }
        handler(seq, event, id) => { return "{seq} on:{event} -> {id}" }
        child(seq, type_name, id) => { return "{seq} child {type_name} #{id}" }
        region_open(seq, key) => { return "{seq} region {key}" }
        region_close => { return "/region" }
        fragment_open(seq) => { return "{seq} fragment" }
        fragment_close => { return "/fragment" }
        boundary_open(seq, failed) => { return "{seq} boundary failed={failed}" }
        boundary_close => { return "/boundary" }
        reference(seq) => { return "{seq} ref" }
        preserve(seq) => { return "{seq} preserve" }
        close => { return "/close" }
    }
}

/// The seq a frame carries, or -1 for the frames that close a scope. The
/// differ walks siblings by this number and never by content.
pub fn frame_seq(frame: Frame) -> int {
    match frame {
        open(seq, _) => { return seq }
        attribute(seq, _, _) => { return seq }
        flag(seq, _, _) => { return seq }
        splat(seq, _) => { return seq }
        text(seq, _) => { return seq }
        raw(seq, _) => { return seq }
        constant(seq, _) => { return seq }
        handler(seq, _, _) => { return seq }
        child(seq, _, _) => { return seq }
        region_open(seq, _) => { return seq }
        region_close => { return -1 }
        fragment_open(seq) => { return seq }
        fragment_close => { return -1 }
        boundary_open(seq, _) => { return seq }
        boundary_close => { return -1 }
        reference(seq) => { return seq }
        preserve(seq) => { return seq }
        close => { return -1 }
    }
}

/// True for the frames that belong to an element's attribute run — everything
/// between `open` and the first child. The serializer depends on that order
/// and the Builder reports a violation as a fault.
pub fn frame_is_attribute(frame: Frame) -> bool {
    match frame {
        attribute(_, _, _) => { return true }
        flag(_, _, _) => { return true }
        splat(_, _) => { return true }
        handler(_, _, _) => { return true }
        reference(_) => { return true }
        preserve(_) => { return true }
        _ => { return false }
    }
}

// ---------------------------------------------------------------- escaping
//
// One escaper, used by the serializer walking frames AND by the applier
// serializing its own tree. If they were two, comparing the applier's output
// against the serializer's would risk comparing two escaping bugs for
// equality instead of checking either one.

const AMP: int = 38
const LT: int = 60
const GT: int = 62
const QUOTE: int = 34
const APOS: int = 39
const SLASH: int = 47
const COLON: int = 58
const QUESTION: int = 63
const HASH: int = 35
const NEWLINE: int = 10

fn escape_into(out: fmt.StringBuilder, body: string, in_attribute: bool) {
    var start: int = 0
    var index: int = 0
    let size: int = body.len()
    for index < size {
        let byte: int = body.byte_at(index)
        var replacement: string = ""
        if byte == AMP { replacement = "&amp;" }
        else if byte == LT { replacement = "&lt;" }
        else if byte == GT { replacement = "&gt;" }
        else if in_attribute && byte == QUOTE { replacement = "&quot;" }
        else if in_attribute && byte == APOS { replacement = "&#39;" }
        if replacement.len() > 0 {
            if index > start { out.push(body.slice(start, index)) }
            out.push(replacement)
            start = index + 1
        }
        index += 1
    }
    if start < size { out.push(body.slice(start, size)) }
}

/// Text-node escaping: `&`, `<`, `>`. Also what RCDATA elements
/// (`<textarea>`, `<title>`) get — a character reference is decoded there, so
/// `&` and `<` must not survive raw.
pub fn escape_text(body: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    escape_into(out, body, false)
    return out.to_string()
}

/// Attribute-value escaping. Values are always double-quoted, so `&quot;` is
/// what the HTML serialization algorithm requires; `&#39;` costs nothing and
/// covers a single-quoted value someone writes by hand later.
pub fn escape_attribute(value: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    escape_into(out, value, true)
    return out.to_string()
}

// ---------------------------------------------------------------- elements

/// Void elements write no closing tag. The Builder still sees a matching
/// `close`, so balance checking stays uniform.
pub fn is_void_element(tag: string) -> bool {
    return tag == "area" || tag == "base" || tag == "br" || tag == "col" ||
           tag == "embed" || tag == "hr" || tag == "img" || tag == "input" ||
           tag == "link" || tag == "meta" || tag == "source" ||
           tag == "track" || tag == "wbr"
}

/// Raw-text elements: their content is NOT escaped, because escaping would
/// corrupt the script or the stylesheet. The serializer refuses content that
/// could close the element instead.
pub fn is_raw_text_element(tag: string) -> bool {
    return tag == "script" || tag == "style"
}

/// RCDATA elements decode character references but do not parse tags, so they
/// take ordinary text escaping — which is exactly what makes `&amp;` right
/// inside a `<title>` and wrong inside a `<script>`.
pub fn is_rcdata_element(tag: string) -> bool {
    return tag == "textarea" || tag == "title"
}

/// The HTML parser eats one newline straight after these start tags, so a
/// serializer that means to keep it has to write two.
pub fn eats_leading_newline(tag: string) -> bool {
    return tag == "pre" || tag == "textarea" || tag == "listing"
}

/// `[a-zA-Z][a-zA-Z0-9-]*`. A tag name reaching the serializer unchecked is
/// markup injection with extra steps.
pub fn tag_name_is_safe(tag: string) -> bool {
    if tag.len() == 0 { return false }
    let first: int = tag.byte_at(0)
    if !(first >= 97 && first <= 122) && !(first >= 65 && first <= 90) { return false }
    var index: int = 1
    for index < tag.len() {
        let byte: int = tag.byte_at(index)
        let letter: bool = (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90)
        let digit: bool = byte >= 48 && byte <= 57
        if !letter && !digit && byte != 45 { return false }
        index += 1
    }
    return true
}

/// `[a-zA-Z_:][a-zA-Z0-9_:.-]*`. `attrs={map}` splats a Map whose keys can be
/// author data, so a name that could carry a quote or a `>` out of its slot is
/// dropped with a fault rather than written.
pub fn attribute_name_is_safe(name: string) -> bool {
    if name.len() == 0 { return false }
    var index: int = 0
    for index < name.len() {
        let byte: int = name.byte_at(index)
        let letter: bool = (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90)
        let digit: bool = byte >= 48 && byte <= 57
        let punct: bool = byte == 95 || byte == 58 || byte == 46 || byte == 45
        if index == 0 && digit { return false }
        if !letter && !digit && !punct { return false }
        index += 1
    }
    return true
}

/// A literal `on*` attribute is an inline handler. The markup compiler
/// refuses it at compile time; the Builder refuses it too, because a
/// hand-written or splatted attribute never went through the compiler.
pub fn attribute_is_inline_handler(name: string) -> bool {
    if name.len() < 3 { return false }
    let lowered: string = name.to_lower()
    return lowered.starts_with("on")
}

/// Content that would close a raw-text element out from under us. `</script`
/// in a string literal ends the element in every browser, whatever the
/// JavaScript grammar thinks, and `<!--` starts a comment-like state that
/// changes where the element ends.
pub fn raw_text_is_safe(body: string, tag: string) -> bool {
    let lowered: string = body.to_lower()
    if lowered.contains("</{tag}") { return false }
    if lowered.contains("<!--") { return false }
    return true
}

// ---------------------------------------------------------------- URL rule
//
// The scheme allowlist lives inside `Builder.attr`, applied by attribute name,
// rather than in a separate `url_attr` a generator could forget to call. A
// control that cannot be forgotten is worth more than one that reads better.

/// The standard URL-bearing attributes, plus `xlink:href`: an SVG `<a
/// xlink:href="javascript:…">` runs script in every browser that renders SVG,
/// and the compiler emits whatever an author writes. Adding a name to an
/// allowlist-enforcement set can only refuse more, never accept more.
pub fn is_url_attribute(name: string) -> bool {
    return name == "href" || name == "src" || name == "action" ||
           name == "formaction" || name == "poster" || name == "data" ||
           name == "xlink:href"
}

/// What a browser sees after it strips the bytes it ignores. Browsers drop
/// leading and trailing C0 controls and space, and drop TAB, LF and CR from
/// anywhere inside a URL — so `java&#9;script:` and `java\nscript:` both reach
/// the scheme parser as `javascript:`, and a check on the untouched string
/// would pass them.
fn url_probe(value: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < value.len() {
        let byte: int = value.byte_at(index)
        if byte > 32 && byte != 127 { out.push_byte(byte) }
        index += 1
    }
    return out.to_string().to_lower()
}

pub fn scheme_is_allowed(value: string) -> bool {
    let probe: string = url_probe(value)
    if probe.len() == 0 { return true }
    let colon: int = probe.find_byte(COLON, 0)
    if colon < 0 { return true }
    // A `/`, `?` or `#` before the first colon means the colon is inside a
    // path, a query or a fragment, so there is no scheme at all.
    let slash: int = probe.find_byte(SLASH, 0)
    if slash >= 0 && slash < colon { return true }
    let question: int = probe.find_byte(QUESTION, 0)
    if question >= 0 && question < colon { return true }
    let hash: int = probe.find_byte(HASH, 0)
    if hash >= 0 && hash < colon { return true }
    let scheme: string = probe.slice(0, colon)
    return scheme == "http" || scheme == "https" || scheme == "mailto" ||
           scheme == "tel"
}

/// What a refused URL becomes. Inert everywhere: as an `href` it navigates to
/// a blank page, as a `src` it loads nothing, and it can never be a script.
pub const INERT_URL: string = "about:blank"
