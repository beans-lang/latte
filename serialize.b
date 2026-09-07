// The contextual serializer: frames to HTML text.
//
// "Contextual" is the whole job. The same `$name` is escaped three different
// ways depending on where it landed — a text node, an attribute value, or the
// inside of a `<script>` — and getting that wrong is an XSS hole rather than a
// cosmetic bug. The element's tag is what decides, and the tag is right here
// in the frame list, which is why this is a frame walk and not a string pass.
//
// This file and `latte.apply` MUST agree byte for byte: the applier serializes
// its own tree with the same helpers, and PLAN.md gate 3 is exactly that
// equality. So the escaper and the attribute rules live in `frames.b` and are
// called from both, never written twice.
package latte

import std.fmt

const MODE_NORMAL: int = 0
const MODE_RAW_TEXT: int = 1
const MODE_RCDATA: int = 2

/// One attribute slot on an element, in the order its frame appeared. A slot
/// is `(seq, name)`: two slots may carry one name — an explicit `class="a"`
/// and a `class` inside an `attrs={…}` splat — and the LAST one wins, which is
/// the rule a caller expects when they splat over defaults.
pub class Attr {
    pub seq: int = 0
    pub name: string = ""
    pub value: string = ""
    pub present: bool = true
    pub fn init() {}
}

/// Write an element's attributes, deduplicating by name with the last slot
/// winning. An absent `flag` that shadows an earlier attribute removes it,
/// because it is the last write for that name.
///
/// Every value is double-quoted and escaped for attribute context, so an
/// unquoted value has no spelling and cannot be produced by data.
pub fn emit_attributes(out: fmt.StringBuilder, attrs: List<Attr>) {
    var winner: Map<string, int> = {}
    var index: int = 0
    for index < attrs.len() {
        winner[attrs[index].name] = index
        index += 1
    }
    index = 0
    for index < attrs.len() {
        let slot: Attr = attrs[index]
        match winner.get(slot.name) {
            some(last) => {
                if last == index && slot.present {
                    out.push(" ")
                    out.push(slot.name)
                    out.push("=\"")
                    out.push(escape_attribute(slot.value))
                    out.push("\"")
                }
            }
            none => {}
        }
        index += 1
    }
}

/// The HTML text of a rendered component tree.
///
/// It is a class rather than a function because a serialization can refuse
/// something — content that would close a `<script>` out from under itself,
/// children inside a void element — and a refusal that goes nowhere is a
/// refusal nobody reads.
pub class Serializer {
    pub faults: List<string> = []
    out: fmt.StringBuilder = new fmt.StringBuilder()
    raw_tag: string = ""
    pub fn init() {}

    /// Serialize a whole page: this component's frames, descending into every
    /// mounted child's own buffer.
    pub fn page(root: Builder) -> string {
        self.out = new fmt.StringBuilder()
        self.faults.clear()
        let _: int = self.siblings(root, 0, MODE_NORMAL)
        return self.out.to_string()
    }

    /// Serialize one component's frames without descending into its children —
    /// what a `preserve`d or isolated subtree looks like on its own.
    pub fn component(buffer: Builder) -> string { return self.page(buffer) }

    // Walk siblings until the frame that closes the enclosing scope, and
    // answer that frame's index. A truncated frame list stops at the end
    // rather than reading past it: the builder guarantees balance, and a
    // walker that trusts a guarantee absolutely is a walker that crashes when
    // the guarantee has a bug.
    fn siblings(b: Builder, start: int, mode: int) -> int {
        var index: int = start
        for index < b.frames.len() {
            let frame: Frame = b.frames.at(index)
            var stop: bool = false
            match frame {
                close => { stop = true }
                region_close => { stop = true }
                fragment_close => { stop = true }
                boundary_close => { stop = true }
                _ => {}
            }
            if stop { return index }
            index = self.one(b, index, mode)
        }
        return index
    }

    fn one(b: Builder, index: int, mode: int) -> int {
        let frame: Frame = b.frames.at(index)
        match frame {
            open(_, tag) => { return self.element(b, index, tag, mode) }
            text(_, body) => {
                self.content(body, mode, true, "text")
                return index + 1
            }
            raw(_, html) => {
                self.content(html, mode, false, "raw")
                return index + 1
            }
            constant(_, html) => {
                self.content(html, mode, false, "constant")
                return index + 1
            }
            child(_, type_name, id) => {
                match b.child_buffer(id) {
                    some(buffer) => { let _: int = self.siblings(buffer, 0, mode) }
                    none => {
                        self.faults.push(
                            "no frame buffer for the {type_name} mounted at slot {id}")
                    }
                }
                return index + 1
            }
            region_open(_, _) => { return self.transparent(b, index, mode) }
            fragment_open(_) => { return self.transparent(b, index, mode) }
            boundary_open(_, _) => { return self.transparent(b, index, mode) }
            _ => {
                self.faults.push("{describe_frame(frame)} is not a child position")
                return index + 1
            }
        }
    }

    // A region, a fragment and a boundary are transparent containers: they lay
    // their children out in the enclosing element and write nothing of their
    // own. That is what lets a keyed row hold several roots and still move as
    // one thing.
    fn transparent(b: Builder, index: int, mode: int) -> int {
        let after: int = self.siblings(b, index + 1, mode)
        if after >= b.frames.len() { return after }
        return after + 1
    }

    fn element(b: Builder, index: int, tag: string, mode: int) -> int {
        let lowered: string = tag.to_lower()
        var attrs: List<Attr> = []
        var cursor: int = index + 1
        for cursor < b.frames.len() {
            let frame: Frame = b.frames.at(cursor)
            if !frame_is_attribute(frame) { break }
            match frame {
                attribute(seq, name, value) => {
                    let slot: Attr = new Attr()
                    slot.seq = seq
                    slot.name = name
                    slot.value = value
                    attrs.push(slot)
                }
                flag(seq, name, present) => {
                    let slot: Attr = new Attr()
                    slot.seq = seq
                    slot.name = name
                    slot.value = ""
                    slot.present = present
                    attrs.push(slot)
                }
                _ => {}
            }
            cursor += 1
        }

        self.out.push("<")
        self.out.push(tag)
        emit_attributes(self.out, attrs)
        self.out.push(">")

        if is_void_element(lowered) {
            let after: int = self.skip_children(b, cursor)
            if after > cursor {
                self.faults.push("void element <{tag}> was given children")
            }
            if after < b.frames.len() { return after + 1 }
            return after
        }

        var inner: int = MODE_NORMAL
        if is_raw_text_element(lowered) { inner = MODE_RAW_TEXT }
        else if is_rcdata_element(lowered) { inner = MODE_RCDATA }
        let outer_raw_tag: string = self.raw_tag
        if inner == MODE_RAW_TEXT { self.raw_tag = lowered }

        // The parser eats one newline straight after `<pre>` and `<textarea>`,
        // so a serializer that means to keep it has to write two.
        if eats_leading_newline(lowered) && self.starts_with_newline(b, cursor) {
            self.out.push("\n")
        }

        let after: int = self.siblings(b, cursor, inner)
        self.raw_tag = outer_raw_tag
        self.out.push("</")
        self.out.push(tag)
        self.out.push(">")
        if after < b.frames.len() { return after + 1 }
        return after
    }

    fn starts_with_newline(b: Builder, index: int) -> bool {
        if index >= b.frames.len() { return false }
        match b.frames.at(index) {
            text(_, body) => { return body.len() > 0 && body.byte_at(0) == 10 }
            raw(_, html) => { return html.len() > 0 && html.byte_at(0) == 10 }
            constant(_, html) => { return html.len() > 0 && html.byte_at(0) == 10 }
            _ => { return false }
        }
    }

    fn skip_children(b: Builder, start: int) -> int {
        var index: int = start
        var depth: int = 0
        for index < b.frames.len() {
            let frame: Frame = b.frames.at(index)
            var opens: bool = false
            var closes: bool = false
            match frame {
                open(_, _) => { opens = true }
                region_open(_, _) => { opens = true }
                fragment_open(_) => { opens = true }
                boundary_open(_, _) => { opens = true }
                close => { closes = true }
                region_close => { closes = true }
                fragment_close => { closes = true }
                boundary_close => { closes = true }
                _ => {}
            }
            if closes {
                if depth == 0 { return index }
                depth -= 1
            }
            if opens { depth += 1 }
            index += 1
        }
        return index
    }

    // The three contexts.
    //
    // A text node is escaped. RCDATA — `<textarea>`, `<title>` — decodes
    // character references but does not parse tags, so it takes the same
    // escaping and `&amp;` is right there and wrong inside a `<script>`.
    // Raw text — `<script>`, `<style>` — is written literally, because
    // escaping it would corrupt the program it holds; what it gets instead is
    // a refusal for content that could end the element early.
    fn content(body: string, mode: int, escaped: bool, what: string) {
        if mode == MODE_RAW_TEXT {
            if !raw_text_is_safe(body, self.raw_tag) {
                self.faults.push("{what} inside <{self.raw_tag}> could close it")
                return
            }
            self.out.push(body)
            return
        }
        if escaped { self.out.push(escape_text(body)) }
        else { self.out.push(body) }
    }
}
