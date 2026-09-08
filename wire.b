// Wire v1 — JSON text, both directions, and the JSON reader that makes the
// client half safe to parse.
//
// PLAN.md picks JSON first because it is "readable in a browser console, which
// is worth a great deal while the differ is young", and it says v1 "stays
// supported forever as the debugging encoding". So this file is not a
// placeholder: it is the reference encoding, and a v2 has to produce the same
// DOM from the same batch.
//
// Why a JSON reader lives here rather than `std.encoding.json`: the module
// root must build for `wasm32-unknown-unknown --runtime freestanding`
// (PLAN.md, D4, and `test.sh --wasm` is the check). std's JSON is the vendored
// yyjson bridge and is refused there —
//
//     std.encoding: error: std.encoding.json needs --runtime full or minimal;
//     the freestanding profile has no C library for the encoding bridges
//
// — so the root cannot use it. That is a constraint and not a preference; the
// reader below is the price of keeping a WebAssembly render mode possible.
//
// Everything a client sends arrives here first, so this is where the size,
// depth and element limits live. Crossing one is a REFUSAL, never a panic and
// never a partial parse: `decode_client` answers a message whose `fault` is
// set, and the circuit turns that into a `bye`.
package latte

import std.fmt

/// The protocol number in every `hello`. A client that does not know it must
/// refuse to attach rather than guess.
pub const WIRE_VERSION: int = 1

// ---------------------------------------------------------------- JSON values
//
// A class tree rather than an enum with payloads, because a variant carrying a
// `List<Json>` is move-only and a recursive walk over it fights the checker at
// every turn. A class field is a reference and assigns.

pub const JSON_NULL: int = 0
pub const JSON_BOOL: int = 1
pub const JSON_INT: int = 2
pub const JSON_TEXT: int = 3
pub const JSON_ARRAY: int = 4
pub const JSON_OBJECT: int = 5

pub class Json {
    pub kind: int = 0
    pub truth: bool = false
    pub number: int = 0
    pub text: string = ""
    /// Array elements, or an object's values in `keys` order.
    pub items: List<Json> = []
    pub keys: List<string> = []
    pub fn init() {}

    pub fn is_null() -> bool { return self.kind == JSON_NULL }
    pub fn is_int() -> bool { return self.kind == JSON_INT }
    pub fn is_text() -> bool { return self.kind == JSON_TEXT }
    pub fn is_array() -> bool { return self.kind == JSON_ARRAY }
    pub fn is_object() -> bool { return self.kind == JSON_OBJECT }

    pub fn len() -> int { return self.items.len() }

    pub fn at(index: int) -> Option<Json> {
        if index < 0 || index >= self.items.len() { return none }
        return some(self.items[index])
    }

    /// An object's member, by name.
    ///
    /// A linear scan and not a `Map`: an object on this wire has at most a
    /// handful of members, and a scan cannot be surprised by a key that
    /// collides with something a map treats specially. Nothing off the wire is
    /// ever used to index anything.
    pub fn field(name: string) -> Option<Json> {
        var index: int = 0
        for index < self.keys.len() {
            if self.keys[index] == name && index < self.items.len() {
                return some(self.items[index])
            }
            index += 1
        }
        return none
    }

    /// An object member read as an int, with a default. A member of the wrong
    /// kind reads as the default rather than as a fault, because every caller
    /// here has already decided what a missing member means.
    pub fn int_field(name: string, fallback: int) -> int {
        match self.field(name) {
            some(value) => {
                if value.kind == JSON_INT { return value.number }
                return fallback
            }
            none => { return fallback }
        }
    }

    pub fn text_field(name: string, fallback: string) -> string {
        match self.field(name) {
            some(value) => {
                if value.kind == JSON_TEXT { return value.text }
                return fallback
            }
            none => { return fallback }
        }
    }

    pub fn bool_field(name: string, fallback: bool) -> bool {
        match self.field(name) {
            some(value) => {
                if value.kind == JSON_BOOL { return value.truth }
                return fallback
            }
            none => { return fallback }
        }
    }
}

pub fn json_null() -> Json { return new Json() }

pub fn json_bool(value: bool) -> Json {
    let out: Json = new Json()
    out.kind = JSON_BOOL
    out.truth = value
    return out
}

pub fn json_int(value: int) -> Json {
    let out: Json = new Json()
    out.kind = JSON_INT
    out.number = value
    return out
}

pub fn json_text(value: string) -> Json {
    let out: Json = new Json()
    out.kind = JSON_TEXT
    out.text = value
    return out
}

// ---------------------------------------------------------------- writing
//
// The escaper. Required by RFC 8259: `"`, `\`, and every byte below 0x20.
// Three more are escaped on purpose:
//
//   `<`      so a batch can never carry `</script` out of a JSON string. The
//            wire never lands in HTML today, but the cost is five bytes that
//            deflate eats and the failure it prevents is script injection.
//            `JSON.parse` hands `<` straight back, so nothing a reader sees in
//            a browser console changes.
//   U+2028   LINE SEPARATOR and PARAGRAPH SEPARATOR terminate a JavaScript
//   U+2029   string literal even though they are legal in JSON. Same reason.
//
// `>` and `&` are deliberately NOT escaped: `<` alone is enough to stop a tag
// from opening, and leaving them raw keeps a golden file readable.
pub fn write_json_string(out: fmt.StringBuilder, value: string) {
    out.push("\"")
    var start: int = 0
    var index: int = 0
    let size: int = value.len()
    for index < size {
        let byte: int = value.byte_at(index)
        var replacement: string = ""
        var width: int = 1
        if byte == 34 { replacement = "\\\"" }
        else if byte == 92 { replacement = "\\\\" }
        else if byte == 8 { replacement = "\\b" }
        else if byte == 9 { replacement = "\\t" }
        else if byte == 10 { replacement = "\\n" }
        else if byte == 12 { replacement = "\\f" }
        else if byte == 13 { replacement = "\\r" }
        else if byte < 32 { replacement = "\\u00{hex_pair(byte)}" }
        else if byte == 60 { replacement = "\\u003c" }
        else if byte == 226 && index + 2 < size &&
                value.byte_at(index + 1) == 128 &&
                (value.byte_at(index + 2) == 168 || value.byte_at(index + 2) == 169) {
            // U+2028 is E2 80 A8, U+2029 is E2 80 A9.
            if value.byte_at(index + 2) == 168 { replacement = "\\u2028" }
            else { replacement = "\\u2029" }
            width = 3
        }
        if replacement.len() > 0 {
            if index > start { out.push(value.slice(start, index)) }
            out.push(replacement)
            start = index + width
            index += width
        } else {
            index += 1
        }
    }
    if start < size { out.push(value.slice(start, size)) }
    out.push("\"")
}

const HEX: string = "0123456789abcdef"

/// i64's floor. Spelled as arithmetic rather than as the literal
/// `-9223372036854775808`, because a source literal is lexed as a positive
/// 9223372036854775808 and then negated, and that positive does not exist.
const INT_MIN: int = (0 - 9223372036854775807) - 1

fn hex_pair(byte: int) -> string {
    let high: int = (byte / 16) % 16
    let low: int = byte % 16
    return "{HEX.slice(high, high + 1)}{HEX.slice(low, low + 1)}"
}

fn write_bool(out: fmt.StringBuilder, value: bool) {
    if value { out.push("true") } else { out.push("false") }
}

// ---------------------------------------------------------------- limits
//
// Every one is an option with a default, and crossing one ends the circuit
// with a `bye` rather than a panic (PLAN.md, "Wire protocol").

pub class WireLimits {
    /// The largest client message this end will look at, in bytes. A message
    /// over it is refused BEFORE it is parsed, which is what makes the
    /// decompression bound meaningful: `std.websocket` already caps the
    /// inflated size, and this caps what latte will read of it.
    pub max_message: int = 65536
    /// How deep an object or array may nest. A hostile client's cheapest
    /// attack on a recursive-descent reader is depth.
    pub max_depth: int = 24
    /// How many elements one array or object may hold, and how many members a
    /// submit payload may carry.
    pub max_items: int = 512
    /// The longest string the reader will accept, so a 64 KB message cannot
    /// become one 64 KB field name.
    pub max_text: int = 32768
    pub fn init() {}
}

// ---------------------------------------------------------------- reading

class Reader {
    text: string = ""
    at: int = 0
    depth: int = 0
    limits: WireLimits = new WireLimits()
    pub fault: string = ""
    pub fn init(text: string, limits: WireLimits) {
        self.text = text
        self.limits = limits
    }

    fn fail(why: string) { if self.fault == "" { self.fault = why } }

    fn done() -> bool { return self.at >= self.text.len() }

    fn peek() -> int {
        if self.done() { return -1 }
        return self.text.byte_at(self.at)
    }

    fn skip_space() {
        for !self.done() {
            let byte: int = self.text.byte_at(self.at)
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                self.at += 1
            } else {
                return
            }
        }
    }

    fn value() -> Json {
        if self.fault != "" { return json_null() }
        if self.depth >= self.limits.max_depth {
            self.fail("nesting deeper than {self.limits.max_depth}")
            return json_null()
        }
        self.skip_space()
        let byte: int = self.peek()
        if byte < 0 { self.fail("the message ended early"); return json_null() }
        if byte == 123 { return self.object() }
        if byte == 91 { return self.array() }
        if byte == 34 { return json_text(self.string_body()) }
        if byte == 116 { return self.keyword("true", json_bool(true)) }
        if byte == 102 { return self.keyword("false", json_bool(false)) }
        if byte == 110 { return self.keyword("null", json_null()) }
        if byte == 45 || (byte >= 48 && byte <= 57) { return self.number() }
        self.fail("a value cannot start with byte {byte}")
        return json_null()
    }

    fn keyword(word: string, answer: Json) -> Json {
        let stop: int = self.at + word.len()
        if stop > self.text.len() || self.text.slice(self.at, stop) != word {
            self.fail("expected {word}")
            return json_null()
        }
        self.at = stop
        return answer
    }

    // Integers only. The wire carries indexes, sequence numbers, slot ids and
    // batch numbers, and nothing else; a float would be a shape this protocol
    // has no reader for. A number with a fraction or an exponent is REFUSED
    // rather than truncated, because truncating one silently would make
    // `{"b":1e999}` an ack for batch 1.
    fn number() -> Json {
        let start: int = self.at
        var negative: bool = false
        if self.peek() == 45 { negative = true; self.at += 1 }
        var digits: int = 0
        var overflow: bool = false

        // Accumulated as a NEGATIVE magnitude, and that is not a stylistic
        // choice. i64's negative side reaches one further than its positive
        // side, so `-9223372036854775808` is a number a client may legally
        // send — and building it positively to negate at the end cannot
        // represent it at all: the intermediate overflows by exactly one and
        // the reader refuses a value that fits. Held negative, every i64 is
        // reachable and the two sides get the bound each actually has.
        //
        // `to_int` saturates rather than reporting, so both guards are written
        // out here: the multiply is checked before it happens and the subtract
        // before it happens, because a check afterwards is reading a value the
        // overflow already destroyed.
        let limit: int = if negative { INT_MIN } else { INT_MIN + 1 }
        var value: int = 0
        for !self.done() {
            let byte: int = self.text.byte_at(self.at)
            if byte < 48 || byte > 57 { break }
            digits += 1
            self.at += 1
            if overflow { continue }
            let digit: int = byte - 48
            if value < limit / 10 { overflow = true; continue }
            value = value * 10
            if value < limit + digit { overflow = true; continue }
            value = value - digit
        }
        if digits == 0 { self.fail("a number with no digits"); return json_null() }
        if digits > 1 && self.text.byte_at(start + (if negative { 1 } else { 0 })) == 48 {
            self.fail("a number with a leading zero")
            return json_null()
        }
        let next: int = self.peek()
        if next == 46 || next == 101 || next == 69 {
            self.fail("this protocol carries integers only")
            return json_null()
        }
        if overflow {
            self.fail("a number too large for this protocol")
            return json_null()
        }
        // Safe in both directions: the positive branch's `limit` stopped one
        // short of the minimum, so `value` is never i64 min here.
        if !negative { value = 0 - value }
        return json_int(value)
    }

    fn string_body() -> string {
        // The opening quote.
        self.at += 1
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        var size: int = 0
        for !self.done() {
            let byte: int = self.text.byte_at(self.at)
            if byte == 34 {
                self.at += 1
                return out.to_string()
            }
            if byte < 32 {
                self.fail("a raw control byte inside a string")
                return ""
            }
            if size >= self.limits.max_text {
                self.fail("a string longer than {self.limits.max_text} bytes")
                return ""
            }
            if byte == 92 {
                self.at += 1
                if self.done() { self.fail("a string ended inside an escape"); return "" }
                let escape: int = self.text.byte_at(self.at)
                self.at += 1
                if escape == 34 { out.push_byte(34); size += 1 }
                else if escape == 92 { out.push_byte(92); size += 1 }
                else if escape == 47 { out.push_byte(47); size += 1 }
                else if escape == 98 { out.push_byte(8); size += 1 }
                else if escape == 102 { out.push_byte(12); size += 1 }
                else if escape == 110 { out.push_byte(10); size += 1 }
                else if escape == 114 { out.push_byte(13); size += 1 }
                else if escape == 116 { out.push_byte(9); size += 1 }
                else if escape == 117 { size += self.unicode_escape(out) }
                else {
                    self.fail("an unknown string escape")
                    return ""
                }
                if self.fault != "" { return "" }
            } else {
                out.push_byte(byte)
                self.at += 1
                size += 1
            }
        }
        self.fail("a string was never closed")
        return ""
    }

    /// `\uXXXX`, including a surrogate pair. A lone surrogate is refused: it
    /// has no UTF-8 form, and quietly writing U+FFFD would mean the string the
    /// server read is not the string the client sent.
    fn unicode_escape(out: fmt.StringBuilder) -> int {
        let first: int = self.hex4()
        if self.fault != "" { return 0 }
        var code: int = first
        if first >= 0xD800 && first <= 0xDBFF {
            if self.at + 1 >= self.text.len() ||
               self.text.byte_at(self.at) != 92 ||
               self.text.byte_at(self.at + 1) != 117 {
                self.fail("a high surrogate with no low surrogate")
                return 0
            }
            self.at += 2
            let second: int = self.hex4()
            if self.fault != "" { return 0 }
            if second < 0xDC00 || second > 0xDFFF {
                self.fail("a high surrogate followed by a non-surrogate")
                return 0
            }
            code = 0x10000 + ((first - 0xD800) * 1024) + (second - 0xDC00)
        } else if first >= 0xDC00 && first <= 0xDFFF {
            self.fail("a low surrogate with no high surrogate")
            return 0
        }
        return write_utf8(out, code)
    }

    fn hex4() -> int {
        if self.at + 4 > self.text.len() {
            self.fail("a \\u escape ran off the end")
            return 0
        }
        var value: int = 0
        var index: int = 0
        for index < 4 {
            let digit: int = json_hex_value(self.text.byte_at(self.at + index))
            if digit < 0 { self.fail("a \\u escape with a non-hex digit"); return 0 }
            value = value * 16 + digit
            index += 1
        }
        self.at += 4
        return value
    }

    fn array() -> Json {
        self.at += 1
        self.depth += 1
        let out: Json = new Json()
        out.kind = JSON_ARRAY
        self.skip_space()
        if self.peek() == 93 { self.at += 1; self.depth -= 1; return out }
        for true {
            let item: Json = self.value()
            if self.fault != "" { return out }
            if out.items.len() >= self.limits.max_items {
                self.fail("an array longer than {self.limits.max_items}")
                return out
            }
            out.items.push(item)
            self.skip_space()
            let byte: int = self.peek()
            if byte == 44 { self.at += 1; continue }
            if byte == 93 { self.at += 1; self.depth -= 1; return out }
            self.fail("expected , or ] in an array")
            return out
        }
        return out
    }

    fn object() -> Json {
        self.at += 1
        self.depth += 1
        let out: Json = new Json()
        out.kind = JSON_OBJECT
        self.skip_space()
        if self.peek() == 125 { self.at += 1; self.depth -= 1; return out }
        for true {
            self.skip_space()
            if self.peek() != 34 { self.fail("an object key must be a string"); return out }
            let key: string = self.string_body()
            if self.fault != "" { return out }
            self.skip_space()
            if self.peek() != 58 { self.fail("expected : after an object key"); return out }
            self.at += 1
            let item: Json = self.value()
            if self.fault != "" { return out }
            if out.keys.len() >= self.limits.max_items {
                self.fail("an object with more than {self.limits.max_items} members")
                return out
            }
            out.keys.push(key)
            out.items.push(item)
            self.skip_space()
            let byte: int = self.peek()
            if byte == 44 { self.at += 1; continue }
            if byte == 125 { self.at += 1; self.depth -= 1; return out }
            self.fail("expected , or \} in an object")
            return out
        }
        return out
    }
}

fn json_hex_value(byte: int) -> int {
    if byte >= 48 && byte <= 57 { return byte - 48 }
    if byte >= 97 && byte <= 102 { return byte - 87 }
    if byte >= 65 && byte <= 70 { return byte - 55 }
    return -1
}

/// One Unicode scalar as UTF-8. Answers how many bytes it wrote.
fn write_utf8(out: fmt.StringBuilder, code: int) -> int {
    if code < 0x80 { out.push_byte(code); return 1 }
    if code < 0x800 {
        out.push_byte(0xC0 + (code / 64))
        out.push_byte(0x80 + (code % 64))
        return 2
    }
    if code < 0x10000 {
        out.push_byte(0xE0 + (code / 4096))
        out.push_byte(0x80 + ((code / 64) % 64))
        out.push_byte(0x80 + (code % 64))
        return 3
    }
    out.push_byte(0xF0 + (code / 262144))
    out.push_byte(0x80 + ((code / 4096) % 64))
    out.push_byte(0x80 + ((code / 64) % 64))
    out.push_byte(0x80 + (code % 64))
    return 4
}

/// Parse one client message. The error is a sentence about the MESSAGE, never
/// about this reader's internals, and it never panics on any input.
pub fn parse_json(text: string, limits: WireLimits) -> Result<Json, string> {
    if text.len() > limits.max_message {
        return err("the message is {text.len()} bytes, over the {limits.max_message}-byte limit")
    }
    let reader: Reader = new Reader(text, limits)
    let value: Json = reader.value()
    if reader.fault != "" { return err(reader.fault) }
    reader.skip_space()
    if !reader.done() { return err("trailing bytes after the message") }
    return ok(value)
}

// ---------------------------------------------------------------- frames out
//
// Every `Frame` variant has an opcode, so a batch is lossless: the client
// builds a node from frames the same way `apply.b` does, from the same list.
// Adding a frame kind is a non-exhaustive match here and a compile error,
// which is the whole reason `Frame` is an enum (frames.b).

fn write_frame(out: fmt.StringBuilder, frame: Frame) {
    match frame {
        open(seq, tag) => {
            out.push("[\"o\",{seq},")
            write_json_string(out, tag)
            out.push("]")
        }
        attribute(seq, name, value) => {
            out.push("[\"a\",{seq},")
            write_json_string(out, name)
            out.push(",")
            write_json_string(out, value)
            out.push("]")
        }
        flag(seq, name, present) => {
            out.push("[\"f\",{seq},")
            write_json_string(out, name)
            out.push(",")
            write_bool(out, present)
            out.push("]")
        }
        splat(seq, count) => { out.push("[\"s\",{seq},{count}]") }
        text(seq, body) => {
            out.push("[\"t\",{seq},")
            write_json_string(out, body)
            out.push("]")
        }
        raw(seq, html) => {
            out.push("[\"r\",{seq},")
            write_json_string(out, html)
            out.push("]")
        }
        constant(seq, html) => {
            out.push("[\"k\",{seq},")
            write_json_string(out, html)
            out.push("]")
        }
        handler(seq, event, id) => {
            out.push("[\"h\",{seq},")
            write_json_string(out, event)
            out.push(",{id}]")
        }
        child(seq, type_name, id) => {
            out.push("[\"c\",{seq},")
            write_json_string(out, type_name)
            out.push(",{id}]")
        }
        region_open(seq, key) => {
            out.push("[\"g\",{seq},")
            write_json_string(out, key)
            out.push("]")
        }
        region_close => { out.push("[\"G\"]") }
        fragment_open(seq) => { out.push("[\"p\",{seq}]") }
        fragment_close => { out.push("[\"P\"]") }
        boundary_open(seq, failed) => {
            out.push("[\"b\",{seq},")
            write_bool(out, failed)
            out.push("]")
        }
        boundary_close => { out.push("[\"B\"]") }
        reference(seq) => { out.push("[\"e\",{seq}]") }
        preserve(seq) => { out.push("[\"v\",{seq}]") }
        close => { out.push("[\"z\"]") }
    }
}

fn write_edit(out: fmt.StringBuilder, edit: Edit) {
    match edit {
        step_in(index) => { out.push("[\"si\",{index}]") }
        step_out => { out.push("[\"so\"]") }
        insert(index, at) => { out.push("[\"in\",{index},{at}]") }
        remove(index) => { out.push("[\"rm\",{index}]") }
        relocate(from, to) => { out.push("[\"mv\",{from},{to}]") }
        set_text(index, body) => {
            out.push("[\"ut\",{index},")
            write_json_string(out, body)
            out.push("]")
        }
        set_markup(index, html) => {
            out.push("[\"um\",{index},")
            write_json_string(out, html)
            out.push("]")
        }
        set_attr(seq, name, value) => {
            out.push("[\"sa\",{seq},")
            write_json_string(out, name)
            out.push(",")
            write_json_string(out, value)
            out.push("]")
        }
        set_flag(seq, name, present) => {
            out.push("[\"sf\",{seq},")
            write_json_string(out, name)
            out.push(",")
            write_bool(out, present)
            out.push("]")
        }
        remove_attr(seq, name) => {
            out.push("[\"ra\",{seq},")
            write_json_string(out, name)
            out.push("]")
        }
        set_handler(seq, event, id) => {
            out.push("[\"sh\",{seq},")
            write_json_string(out, event)
            out.push(",{id}]")
        }
        remove_handler(seq, event) => {
            out.push("[\"rh\",{seq},")
            write_json_string(out, event)
            out.push("]")
        }
    }
}

/// One edit batch as a wire frame.
///
/// `u` is in the differ's pre-order — parent before child — so the mount node
/// a child's edits are addressed to always exists by the time they arrive.
/// `d` is the disposal list; the applier drops what it holds for those ids and
/// ignores the rest, which is why over-reporting a disposal is free
/// (builder.b, `drop_slot`).
pub fn encode_batch(number: int, batch: Batch) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"batch\",\"b\":{number},\"r\":[")
    var index: int = 0
    for index < batch.reference.len() {
        if index > 0 { out.push(",") }
        write_frame(out, batch.reference.at(index))
        index += 1
    }
    out.push("],\"u\":[")
    var first: bool = true
    for update: ComponentUpdate in batch.updates {
        if !first { out.push(",") }
        first = false
        out.push("\{\"c\":{update.component},\"e\":[")
        var written: int = 0
        for edit: Edit in update.edits {
            if written > 0 { out.push(",") }
            write_edit(out, edit)
            written += 1
        }
        out.push("]\}")
    }
    out.push("],\"d\":[")
    var wrote: int = 0
    for id: int in batch.disposed {
        if wrote > 0 { out.push(",") }
        out.push("{id}")
        wrote += 1
    }
    out.push("]\}")
    return out.to_string()
}

/// The first frame on every circuit: what protocol this end speaks and what it
/// will accept. A client that reads a version it does not know must stop.
pub fn encode_hello(circuit: string, limits: WireLimits) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"hello\",\"v\":{WIRE_VERSION},\"c\":")
    write_json_string(out, circuit)
    out.push(",\"mx\":{limits.max_message}\}")
    return out.to_string()
}

/// A failure the circuit SURVIVED. `msg` is what the page may see, so it is
/// never a server detail: a contained panic sends its trace id, never its
/// message (PLAN.md, "information disclosure").
pub fn encode_err(kind: string, message: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"err\",\"k\":")
    write_json_string(out, kind)
    out.push(",\"m\":")
    write_json_string(out, message)
    out.push("\}")
    return out.to_string()
}

/// The last frame on a circuit. Every limit in `CircuitOptions` ends here.
pub fn encode_bye(kind: string, message: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"bye\",\"k\":")
    write_json_string(out, kind)
    out.push(",\"m\":")
    write_json_string(out, message)
    out.push("\}")
    return out.to_string()
}

/// A JS interop call. `name` selects from the registry the PAGE populated with
/// `latte.register(name, fn)`; the client never evaluates a string and never
/// reads a property named on the wire.
pub fn encode_js(call: int, name: string, args: List<string>) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"js\",\"i\":{call},\"f\":")
    write_json_string(out, name)
    out.push(",\"a\":[")
    var index: int = 0
    for index < args.len() {
        if index > 0 { out.push(",") }
        write_json_string(out, args[index])
        index += 1
    }
    out.push("]\}")
    return out.to_string()
}

/// Server-driven navigation. Same-origin and path-only is enforced before this
/// is written, so what reaches the client is already a path.
pub fn encode_nav(url: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{\"t\":\"nav\",\"u\":")
    write_json_string(out, url)
    out.push("\}")
    return out.to_string()
}

// ---------------------------------------------------------------- events
//
// The families are builder.b's five handler tables, and the names are exactly
// the `on_*` methods it declares. A name not in this table has no handler
// table to look in, so it can never dispatch — which is the point: an event
// name off the wire selects a FAMILY, never a method.

pub const FAMILY_NONE: int = 0
pub const FAMILY_MOUSE: int = 1
pub const FAMILY_INPUT: int = 2
pub const FAMILY_KEYBOARD: int = 3
pub const FAMILY_SUBMIT: int = 4
pub const FAMILY_FOCUS: int = 5

pub fn event_family(name: string) -> int {
    if name == "click" || name == "dblclick" || name == "mousedown" ||
       name == "mouseup" || name == "mouseenter" || name == "mouseleave" ||
       name == "mouseover" || name == "mouseout" || name == "mousemove" ||
       name == "contextmenu" { return FAMILY_MOUSE }
    if name == "input" || name == "change" { return FAMILY_INPUT }
    if name == "keydown" || name == "keyup" || name == "keypress" {
        return FAMILY_KEYBOARD
    }
    if name == "submit" || name == "reset" { return FAMILY_SUBMIT }
    if name == "focus" || name == "blur" || name == "focusin" ||
       name == "focusout" { return FAMILY_FOCUS }
    return FAMILY_NONE
}

/// Every event name latte dispatches, in the order `latte.js` should register
/// them. Public because the browser half is generated from nothing — it is
/// hand-written — and a suite can compare the two lists rather than trusting
/// that someone kept them in step.
pub fn event_names() -> List<string> {
    var out: List<string> = []
    out.push("click"); out.push("dblclick"); out.push("mousedown")
    out.push("mouseup"); out.push("mouseenter"); out.push("mouseleave")
    out.push("mouseover"); out.push("mouseout"); out.push("mousemove")
    out.push("contextmenu")
    out.push("input"); out.push("change")
    out.push("keydown"); out.push("keyup"); out.push("keypress")
    out.push("submit"); out.push("reset")
    out.push("focus"); out.push("blur"); out.push("focusin"); out.push("focusout")
    return move out
}

/// The events that do NOT bubble, so a delegating listener at the page root
/// has to be registered in the capture phase for them. `latte.js` reads the
/// same rule; this is here so a suite can assert the two agree.
pub fn event_captures(name: string) -> bool {
    return name == "mouseenter" || name == "mouseleave" ||
           name == "focus" || name == "blur"
}

// ---------------------------------------------------------------- messages in

pub const CLIENT_NONE: int = 0
pub const CLIENT_ATTACH: int = 1
pub const CLIENT_RESUME: int = 2
pub const CLIENT_EVENT: int = 3
pub const CLIENT_ACK: int = 4
pub const CLIENT_NAV: int = 5
pub const CLIENT_JS: int = 6
pub const CLIENT_RANGE: int = 7

/// One decoded client message. A class with every field rather than an enum,
/// because the circuit reads two or three fields per kind and an enum payload
/// would move on every read.
pub class ClientMessage {
    pub kind: int = 0
    /// Non-empty means REFUSE. It is a sentence about the message and it is
    /// what the `bye` carries, so it may never quote server state.
    pub fault: string = ""

    pub circuit: string = ""
    pub url: string = ""

    pub handler: int = 0
    pub event: string = ""
    pub family: int = 0

    pub batch: int = 0
    pub call: int = 0
    pub ok: bool = false
    pub value: string = ""

    pub start: int = 0
    pub count: int = 0

    // The event payloads, filled for the family `event` names.
    pub button: int = 0
    pub x: int = 0
    pub y: int = 0
    pub text: string = ""
    pub checked: bool = false
    pub key: string = ""
    pub repeated: bool = false
    pub fields: Map<string, string> = {}

    pub fn init() {}
}

fn refuse(why: string) -> ClientMessage {
    let out: ClientMessage = new ClientMessage()
    out.fault = why
    return out
}

/// Decode one client message.
///
/// Nothing here can panic and nothing here interprets a wire string as a name:
/// `t` selects a fixed kind, `k` selects a fixed FAMILY, and the only strings
/// that survive are values. That is what removes mass assignment and
/// reflective invocation from the threat table by construction rather than by
/// defence (PLAN.md, "Security").
pub fn decode_client(text: string, limits: WireLimits) -> ClientMessage {
    match parse_json(text, limits) {
        ok(root) => {
            if !root.is_object() { return refuse("a message must be a JSON object") }
            let kind: string = root.text_field("t", "")
            if kind == "attach" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_ATTACH
                out.circuit = root.text_field("c", "")
                out.url = root.text_field("u", "")
                if out.circuit == "" { return refuse("attach carries no circuit id") }
                return out
            }
            if kind == "resume" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_RESUME
                out.circuit = root.text_field("c", "")
                out.batch = root.int_field("a", -1)
                if out.circuit == "" { return refuse("resume carries no circuit id") }
                if out.batch < 0 { return refuse("resume carries no acknowledged batch") }
                return out
            }
            if kind == "ev" { return decode_event(root) }
            if kind == "ack" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_ACK
                out.batch = root.int_field("b", -1)
                if out.batch < 0 { return refuse("ack carries no batch number") }
                return out
            }
            if kind == "nav" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_NAV
                out.url = root.text_field("u", "")
                if out.url == "" { return refuse("nav carries no url") }
                return out
            }
            if kind == "js" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_JS
                out.call = root.int_field("i", -1)
                out.ok = root.bool_field("ok", false)
                out.value = root.text_field("v", "")
                if out.call < 0 { return refuse("a js result carries no call id") }
                return out
            }
            if kind == "range" {
                let out: ClientMessage = new ClientMessage()
                out.kind = CLIENT_RANGE
                out.handler = root.int_field("h", -1)
                out.start = root.int_field("s", -1)
                out.count = root.int_field("n", -1)
                if out.handler < 0 { return refuse("a range carries no region id") }
                if out.start < 0 || out.count < 0 {
                    return refuse("a range must be two non-negative numbers")
                }
                return out
            }
            if kind == "" { return refuse("a message with no \"t\"") }
            return refuse("unknown message kind")
        }
        err(problem) => { return refuse(problem) }
    }
}

/// Takes no `WireLimits`: everything a limit bounds — the message size, the
/// nesting, the member count, the string length — has already been enforced by
/// the reader that produced `root`. A second bound here would be a refusal no
/// input can reach.
fn decode_event(root: Json) -> ClientMessage {
    let out: ClientMessage = new ClientMessage()
    out.kind = CLIENT_EVENT
    out.handler = root.int_field("h", -1)
    out.event = root.text_field("k", "")
    if out.handler <= 0 { return refuse("an event carries no handler id") }
    out.family = event_family(out.event)
    if out.family == FAMILY_NONE { return refuse("unknown event name") }

    var payload: Json = new Json()
    payload.kind = JSON_OBJECT
    match root.field("p") {
        some(value) => {
            if !value.is_object() { return refuse("an event payload must be an object") }
            payload = value
        }
        none => {}
    }

    if out.family == FAMILY_MOUSE {
        out.button = payload.int_field("b", 0)
        out.x = payload.int_field("x", 0)
        out.y = payload.int_field("y", 0)
    } else if out.family == FAMILY_INPUT {
        out.text = payload.text_field("v", "")
        out.checked = payload.bool_field("c", false)
    } else if out.family == FAMILY_KEYBOARD {
        out.key = payload.text_field("k", "")
        out.repeated = payload.bool_field("r", false)
    } else if out.family == FAMILY_SUBMIT {
        match payload.field("f") {
            some(fields) => {
                if !fields.is_object() {
                    return refuse("a submit payload's fields must be an object")
                }
                // How many fields a form may post is `limits.max_items`, and
                // the READER is where that is enforced: it refuses any object
                // with more than max_items members, and this function is
                // handed the same limits `parse_json` just used. A second cap
                // here would be a refusal no input can reach — RULES.md, "the
                // refusal that never runs" — so there is one cap and one
                // message. tests/wire.b § 2.19-2.21 pin it at both sides.
                var index: int = 0
                for index < fields.keys.len() {
                    let name: string = fields.keys[index]
                    match fields.at(index) {
                        some(value) => {
                            if value.is_text() { out.fields[name] = value.text }
                            else if value.is_int() { out.fields[name] = "{value.number}" }
                            else if value.kind == JSON_BOOL {
                                out.fields[name] = if value.truth { "true" } else { "false" }
                            }
                        }
                        none => {}
                    }
                    index += 1
                }
            }
            none => {}
        }
    }
    return out
}

/// Turn a decoded event into the builder's event object for its family. Five
/// separate makers rather than one, because the five are five types and the
/// Registry keeps five tables.
pub fn mouse_event(message: ClientMessage) -> MouseEvent {
    let out: MouseEvent = new MouseEvent()
    out.button = message.button
    out.x = message.x
    out.y = message.y
    return out
}

pub fn input_event(message: ClientMessage) -> InputEvent {
    let out: InputEvent = new InputEvent()
    out.value = message.text
    out.checked = message.checked
    return out
}

pub fn keyboard_event(message: ClientMessage) -> KeyboardEvent {
    let out: KeyboardEvent = new KeyboardEvent()
    out.key = message.key
    out.repeated = message.repeated
    return out
}

pub fn submit_event(message: ClientMessage) -> SubmitEvent {
    let out: SubmitEvent = new SubmitEvent()
    var names: List<string> = message.fields.keys()
    names.sort()
    for name: string in names {
        match message.fields.get(name) {
            some(value) => { out.fields[name] = value }
            none => {}
        }
    }
    return out
}

pub fn focus_event(message: ClientMessage) -> FocusEvent {
    return new FocusEvent()
}
