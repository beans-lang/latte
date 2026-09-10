// tests/wire.b — wire v1, both directions, and the bounded JSON reader.
//
// v1 stays supported forever as the debugging encoding, so this file is not a
// placeholder suite for something better later: it is the specification of
// what latte puts on a socket, written down as bytes. Two claims run through
// every section.
//
//   * **The encoding is lossless.** § 6 builds a batch that carries EVERY
//     frame opcode and EVERY edit opcode — all 19 frame variants and all 12
//     edit variants — and pins the exact string. A frame kind added to
//     `frames.b` without an opcode in `wire.b` is a non-exhaustive match and
//     will not compile; one whose opcode changes shape is a diff here.
//   * **Every refusal has a positive control beside it.** Without an input
//     that must be ACCEPTED you cannot tell "refused for the right reason"
//     from "refused earlier, for a different one". Each limit is exercised at
//     its exact boundary — the largest input that is taken, and the smallest
//     that is not.
//
// § 2 records a refusal that could not fire and is now gone: `decode_event`
// carried its own "a submit payload with more than N fields" check, and the
// reader had already refused any object with more than N members using the
// same limits object, so no input could reach it. The live cap is asserted
// here at both sides of its boundary.
package main

import std.fmt
import std.io
import {Batch, ClientMessage, ComponentUpdate, Edit, FocusEvent, Frame, Frames,
        InputEvent, Json, KeyboardEvent, MouseEvent, SubmitEvent, WireLimits,
        CLIENT_ACK, CLIENT_ATTACH, CLIENT_EVENT, CLIENT_JS, CLIENT_NAV,
        CLIENT_RANGE, CLIENT_RESUME,
        FAMILY_FOCUS, FAMILY_INPUT, FAMILY_KEYBOARD, FAMILY_MOUSE, FAMILY_NONE,
        FAMILY_SUBMIT, JSON_ARRAY, JSON_BOOL, JSON_INT, JSON_NULL, JSON_TEXT,
        WIRE_VERSION,
        decode_client, encode_batch, encode_bye, encode_err, encode_hello,
        encode_js, encode_nav, encode_seen, event_captures, event_family, event_names,
        focus_event, input_event, json_bool, json_int, json_null, json_text,
        keyboard_event, mouse_event, parse_json, submit_event,
        write_json_string} from latte

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok {name}")
        } else {
            self.bad += 1
            io.println("FAIL {name}:")
            io.println("   got  {got}")
            io.println("   want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

// ============================================================== helpers

/// A parsed value rendered canonically, so a positive control proves the
/// reader read the RIGHT thing rather than merely failing to refuse.
fn show(value: Json) -> string {
    if value.kind == JSON_NULL { return "null" }
    if value.kind == JSON_BOOL { return if value.truth { "true" } else { "false" } }
    if value.kind == JSON_INT { return "{value.number}" }
    if value.kind == JSON_TEXT { return "\"{value.text}\"" }
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    if value.kind == JSON_ARRAY {
        out.push("[")
        for index < value.items.len() {
            if index > 0 { out.push(",") }
            out.push(show(value.items[index]))
            index += 1
        }
        out.push("]")
        return out.to_string()
    }
    out.push("\{")
    for index < value.keys.len() {
        if index > 0 { out.push(",") }
        out.push("{value.keys[index]}=")
        out.push(show(value.items[index]))
        index += 1
    }
    out.push("\}")
    return out.to_string()
}

/// What the reader made of `text`: the value it read, or the sentence it
/// refused with. One helper for both, so a control and its refusal print in
/// one shape and a reader of the golden can see which is which.
fn read(text: string, limits: WireLimits) -> string {
    match parse_json(text, limits) {
        ok(value) => { return show(value) }
        err(problem) => { return "REFUSED {problem}" }
    }
}

/// Taken or refused, with no value printed. Twenty-four nested brackets in a
/// golden are noise; whether the reader took them is the fact.
fn taken(text: string, limits: WireLimits) -> string {
    match parse_json(text, limits) {
        ok(value) => { return "ACCEPTED" }
        err(problem) => { return "REFUSED {problem}" }
    }
}

fn small(message: int, depth: int, items: int, text: int) -> WireLimits {
    var out: WireLimits = new WireLimits()
    out.max_message = message
    out.max_depth = depth
    out.max_items = items
    out.max_text = text
    return out
}

fn family_word(family: int) -> string {
    if family == FAMILY_MOUSE { return "mouse" }
    if family == FAMILY_INPUT { return "input" }
    if family == FAMILY_KEYBOARD { return "key" }
    if family == FAMILY_SUBMIT { return "submit" }
    if family == FAMILY_FOCUS { return "focus" }
    return "none"
}

/// A decoded client message rendered so that only the fields its kind fills
/// appear. A dump of every field would bury the one that matters in noise.
fn told(text: string, limits: WireLimits) -> string {
    let m: ClientMessage = decode_client(text, limits)
    if m.fault != "" { return "REFUSED {m.fault}" }
    // The sequence is printed only when the client asked for a fence, so every
    // row written before `n` existed still reads the same. That is deliberate:
    // a golden that shifted on every line would have hidden which rows this
    // change actually touched.
    if m.sequence > 0 { return "{told_body(m)} seq={m.sequence}" }
    return told_body(m)
}

fn told_body(m: ClientMessage) -> string {
    if m.kind == CLIENT_ATTACH { return "attach c={m.circuit} u={m.url}" }
    if m.kind == CLIENT_RESUME { return "resume c={m.circuit} a={m.batch}" }
    if m.kind == CLIENT_ACK { return "ack b={m.batch}" }
    if m.kind == CLIENT_NAV { return "nav u={m.url}" }
    if m.kind == CLIENT_JS { return "js i={m.call} ok={m.ok} v={m.value}" }
    if m.kind == CLIENT_RANGE {
        return "range h={m.handler} s={m.start} c={m.count}"
    }
    if m.kind == CLIENT_EVENT {
        let head: string = "ev h={m.handler} k={m.event} fam={family_word(m.family)}"
        if m.family == FAMILY_MOUSE { return "{head} b={m.button} x={m.x} y={m.y}" }
        if m.family == FAMILY_INPUT { return "{head} v=[{m.text}] c={m.checked}" }
        if m.family == FAMILY_KEYBOARD { return "{head} k=[{m.key}] r={m.repeated}" }
        if m.family == FAMILY_SUBMIT {
            var names: List<string> = m.fields.keys()
            names.sort()
            var parts: List<string> = []
            for name: string in names {
                match m.fields.get(name) {
                    some(value) => { parts.push("{name}=[{value}]") }
                    none => {}
                }
            }
            return "{head} f\{{parts.join(",")}\}"
        }
        return head
    }
    return "none"
}

/// `{"t":"ev","h":1,"k":"submit","p":{"f":{…}}}` with `count` fields. Built
/// rather than written out, so the boundary case can be asked for by number.
fn submit_message(count: int) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push(r#"{"t":"ev","h":1,"k":"submit","p":{"f":{"#)
    var index: int = 0
    for index < count {
        if index > 0 { out.push(",") }
        out.push("\"f{index}\":\"v\"")
        index += 1
    }
    out.push("\}\}\}")
    return out.to_string()
}

fn nested(depth: int, inner: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < depth { out.push("["); index += 1 }
    out.push(inner)
    index = 0
    for index < depth { out.push("]"); index += 1 }
    return out.to_string()
}

fn array_of(count: int) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("[")
    var index: int = 0
    for index < count {
        if index > 0 { out.push(",") }
        out.push("1")
        index += 1
    }
    out.push("]")
    return out.to_string()
}

fn object_of(count: int) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{")
    var index: int = 0
    for index < count {
        if index > 0 { out.push(",") }
        out.push("\"k{index}\":1")
        index += 1
    }
    out.push("\}")
    return out.to_string()
}

fn quoted(body: string) -> string { return "\"{body}\"" }

fn escaped(value: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    write_json_string(out, value)
    return out.to_string()
}

/// `"a" + "b"` is not concatenation in Beans, and the two long expectations in
/// § 6 and § 10 are longer than a line. A list joined with nothing is.
fn cat(parts: List<string>) -> string { return parts.join("") }

fn main() {
    let r: Report = new Report()
    let wide: WireLimits = new WireLimits()

    // ========================================================== § 1
    io.println("-- 1. the reader, on values it must take")

    r.eq("1.1 object", read(r#"{"a":1,"b":"x"}"#, wide), r#"{a=1,b="x"}"#)
    r.eq("1.2 array", read("[1,2,3]", wide), "[1,2,3]")
    r.eq("1.3 nesting", read(r#"{"a":[{"b":[]}]}"#, wide), "\{a=[\{b=[]\}]\}")
    r.eq("1.4 keywords", read("[true,false,null]", wide), "[true,false,null]")
    r.eq("1.5 empty containers", read("[[],\{\}]", wide), "[[],\{\}]")
    r.eq("1.6 whitespace everywhere",
         read("  \{ \"a\" :\t[ 1 ,\n2 ]\r \}  ", wide), "\{a=[1,2]\}")
    r.eq("1.7 negative and zero", read("[0,-0,-7]", wide), "[0,0,-7]")
    r.eq("1.8 i64 edges",
         read("[9223372036854775807,-9223372036854775808]", wide),
         "[9223372036854775807,-9223372036854775808]")
    r.eq("1.9 duplicate keys keep both", read(r#"{"a":1,"a":2}"#, wide),
         "\{a=1,a=2\}")
    r.eq("1.10 a bare string is a value", read(quoted("hi"), wide), r#""hi""#)

    // ========================================================== § 2
    io.println("")
    io.println("-- 2. the four limits, each at its exact boundary")
    //
    // Each pair is the largest input the reader takes and the smallest it does
    // not. A limit tested only from the far side proves the refusal exists; it
    // does not prove the accepted side still works, which is the half that
    // breaks when someone "tightens" a bound.

    // max_message counts BYTES, before anything is parsed.
    let ack17: string = r#"{"t":"ack","b":1}"#
    r.eqi("2.1 the message under test is 17 bytes", ack17.len(), 17)
    r.eq("2.2 message exactly at the cap", read(ack17, small(17, 24, 512, 1024)),
         r#"{t="ack",b=1}"#)
    r.eq("2.3 message one byte over", read(ack17, small(16, 24, 512, 1024)),
         "REFUSED the message is 17 bytes, over the 16-byte limit")

    // max_depth. The reader charges a level on ENTERING a container, so a
    // container whose contents are empty sits one level shallower than one
    // that holds a value. Both sides of that are pinned, because an off-by-one
    // here is invisible until a page nests one level deeper than a test did.
    let d3: WireLimits = small(65536, 3, 512, 1024)
    r.eq("2.4 two levels holding a value", read(nested(2, "1"), d3), "[[1]]")
    r.eq("2.5 three levels holding nothing", read(nested(3, ""), d3), "[[[]]]")
    r.eq("2.6 three levels holding a value", read(nested(3, "1"), d3),
         "REFUSED nesting deeper than 3")
    // The same boundary at the shipped default, so a change to the default
    // shows up here and not in a page that nests one level deeper than a test.
    r.eq("2.7 twenty-three levels of the default holding a value",
         taken(nested(23, "1"), wide), "ACCEPTED")
    r.eq("2.8 twenty-four holding a value", taken(nested(24, "1"), wide),
         "REFUSED nesting deeper than 24")
    r.eq("2.9 twenty-four holding nothing", taken(nested(24, ""), wide),
         "ACCEPTED")
    r.eq("2.10 twenty-five holding nothing", taken(nested(25, ""), wide),
         "REFUSED nesting deeper than 24")

    // max_items, arrays and objects alike.
    let i4: WireLimits = small(65536, 24, 4, 1024)
    r.eq("2.11 array exactly at the cap", read(array_of(4), i4), "[1,1,1,1]")
    r.eq("2.12 array one over", read(array_of(5), i4),
         "REFUSED an array longer than 4")
    r.eq("2.13 object exactly at the cap", read(object_of(4), i4),
         "\{k0=1,k1=1,k2=1,k3=1\}")
    r.eq("2.14 object one over", read(object_of(5), i4),
         "REFUSED an object with more than 4 members")

    // max_text.
    let t8: WireLimits = small(65536, 24, 512, 8)
    r.eq("2.15 string exactly at the cap", read(quoted("abcdefgh"), t8),
         r#""abcdefgh""#)
    r.eq("2.16 string one over", read(quoted("abcdefghi"), t8),
         "REFUSED a string longer than 8 bytes")
    r.eq("2.17 an escape counts what it PRODUCES, not what it spells",
         read(quoted("\\u0041\\u0041"), t8), r#""AA""#)
    r.eq("2.18 a key is a string too", read(r#"{"abcdefghi":1}"#, t8),
         "REFUSED a string longer than 8 bytes")

    // The cap on a submit payload's fields is this same object cap, and there
    // is only one of it. `decode_event` used to carry a second "more than N
    // fields" refusal of its own; because `decode_client` hands it the SAME
    // limits, the reader always refused first and no input could reach it.
    // These three lines are the evidence: under the cap and at the cap it is
    // taken, one over it is refused, and the sentence is the READER's.
    let f5: WireLimits = small(65536, 24, 5, 1024)
    r.eq("2.19 submit under the field cap", told(submit_message(4), f5),
         "ev h=1 k=submit fam=submit f\{f0=[v],f1=[v],f2=[v],f3=[v]\}")
    r.eq("2.20 submit exactly at the field cap", told(submit_message(5), f5),
         "ev h=1 k=submit fam=submit f\{f0=[v],f1=[v],f2=[v],f3=[v],f4=[v]\}")
    r.eq("2.21 submit one field over", told(submit_message(6), f5),
         "REFUSED an object with more than 5 members")

    // ========================================================== § 3
    io.println("")
    io.println("-- 3. numbers: integers only, and every way that is said")

    r.eq("3.1 a fraction is refused, not truncated", read("1.5", wide),
         "REFUSED this protocol carries integers only")
    r.eq("3.2 an exponent is refused, not evaluated", read("1e999", wide),
         "REFUSED this protocol carries integers only")
    r.eq("3.3 a capital exponent too", read("1E3", wide),
         "REFUSED this protocol carries integers only")
    r.eq("3.4 the control: the same digits with no exponent", read("1", wide), "1")
    r.eq("3.5 a leading zero", read("01", wide),
         "REFUSED a number with a leading zero")
    r.eq("3.6 a negative leading zero", read("-01", wide),
         "REFUSED a number with a leading zero")
    r.eq("3.7 the control: zero itself", read("0", wide), "0")
    r.eq("3.8 one over i64", read("9223372036854775808", wide),
         "REFUSED a number too large for this protocol")
    r.eq("3.9 far over i64", read("99999999999999999999999", wide),
         "REFUSED a number too large for this protocol")
    r.eq("3.10 the control: i64 max itself", read("9223372036854775807", wide),
         "9223372036854775807")
    r.eq("3.11 a minus with no digits", read("-", wide),
         "REFUSED a number with no digits")
    r.eq("3.12 a plus sign is not a value", read("+1", wide),
         "REFUSED a value cannot start with byte 43")

    // ========================================================== § 4
    io.println("")
    io.println("-- 4. strings: escapes, and what may not appear raw")

    r.eq("4.1 the eight short escapes",
         read(quoted("a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti"), wide),
         "\"a\"b\\c/d\u{8}e\u{c}f\ng\rh\ti\"")
    r.eq("4.2 \\u below the BMP", read(quoted("\\u0041\\u00e9\\u20ac"), wide),
         "\"A\u{e9}\u{20ac}\"")
    r.eq("4.3 a surrogate pair", read(quoted("\\ud83d\\ude00"), wide),
         "\"\u{1f600}\"")
    r.eq("4.4 a lone high surrogate", read(quoted("\\ud83d"), wide),
         "REFUSED a high surrogate with no low surrogate")
    r.eq("4.5 a lone low surrogate", read(quoted("\\ude00"), wide),
         "REFUSED a low surrogate with no high surrogate")
    r.eq("4.6 a high surrogate then something else",
         read(quoted("\\ud83d\\u0041"), wide),
         "REFUSED a high surrogate followed by a non-surrogate")
    r.eq("4.7 an unknown escape", read(quoted("\\x41"), wide),
         "REFUSED an unknown string escape")
    r.eq("4.8 a \\u with a non-hex digit", read(quoted("\\u00g0"), wide),
         "REFUSED a \\u escape with a non-hex digit")
    r.eq("4.9 a \\u that runs off the end", read("\"\\u00", wide),
         "REFUSED a \\u escape ran off the end")
    r.eq("4.10 a raw control byte", read("\"a\u{1}b\"", wide),
         "REFUSED a raw control byte inside a string")
    r.eq("4.11 the control: the same byte, escaped",
         read(quoted("a\\u0001b"), wide), "\"a\u{1}b\"")
    r.eq("4.12 a string that never closes", read("\"abc", wide),
         "REFUSED a string was never closed")
    r.eq("4.13 a string that ends inside an escape", read("\"abc\\", wide),
         "REFUSED a string ended inside an escape")
    r.eq("4.14 raw UTF-8 passes through", read(quoted("h\u{e9}llo \u{1f600}"), wide),
         "\"h\u{e9}llo \u{1f600}\"")

    // ========================================================== § 5
    io.println("")
    io.println("-- 5. structure: what is not a message, and what is")

    r.eq("5.1 an array root is not a message",
         told("[1,2,3]", wide), "REFUSED a message must be a JSON object")
    r.eq("5.2 a number root is not a message",
         told("7", wide), "REFUSED a message must be a JSON object")
    r.eq("5.3 trailing bytes", read("\{\} x", wide),
         "REFUSED trailing bytes after the message")
    r.eq("5.4 the control: trailing WHITESPACE is fine", read("\{\}  \n", wide),
         "\{\}")
    r.eq("5.5 a bare key", read("\{a:1\}", wide),
         "REFUSED an object key must be a string")
    r.eq("5.6 a missing colon", read(r#"{"a" 1}"#, wide),
         "REFUSED expected : after an object key")
    r.eq("5.7 a missing comma in an object", read(r#"{"a":1 "b":2}"#, wide),
         "REFUSED expected , or \} in an object")
    r.eq("5.8 a missing comma in an array", read("[1 2]", wide),
         "REFUSED expected , or ] in an array")
    r.eq("5.9 an empty message", read("", wide),
         "REFUSED the message ended early")
    r.eq("5.10 a truncated keyword", read("tru", wide), "REFUSED expected true")
    r.eq("5.11 the control: the whole keyword", read("true", wide), "true")
    r.eq("5.12 a stray closer", read("]", wide),
         "REFUSED a value cannot start with byte 93")

    // ========================================================== § 6
    io.println("")
    io.println("-- 6. the batch encoder: every frame opcode, every edit opcode")
    //
    // The claim is that wire v1 is LOSSLESS — one opcode per `Frame` variant
    // and one per `Edit` variant, so a client can rebuild what the differ saw.
    // Adding a variant without adding a case is a non-exhaustive match in
    // `wire.b` and does not compile; changing a case's shape shows up here.

    var reference: Frames = new Frames()
    reference.push(Frame.open(0, "div"))
    reference.push(Frame.attribute(1, "class", "row"))
    reference.push(Frame.flag(2, "hidden", true))
    reference.push(Frame.splat(3, 1))
    reference.push(Frame.attribute(3, "data-x", "1"))
    reference.push(Frame.handler(4, "click", 11))
    reference.push(Frame.reference(5))
    reference.push(Frame.preserve(6))
    reference.push(Frame.text(7, "hi <b>"))
    reference.push(Frame.raw(8, "<i>raw</i>"))
    reference.push(Frame.constant(9, "<hr>"))
    reference.push(Frame.child(10, "Counter", 3))
    reference.push(Frame.region_open(11, "k1"))
    reference.push(Frame.text(0, "row"))
    reference.push(Frame.region_close)
    reference.push(Frame.fragment_open(12))
    reference.push(Frame.boundary_open(0, true))
    reference.push(Frame.boundary_close)
    reference.push(Frame.fragment_close)
    reference.push(Frame.close)

    r.eqi("6.1 all nineteen frame kinds staged", reference.len(), 20)

    var batch: Batch = new Batch()
    batch.reference = reference
    var top: ComponentUpdate = new ComponentUpdate(0)
    top.edits.push(Edit.insert(0, 0))
    top.edits.push(Edit.step_in(0))
    top.edits.push(Edit.set_attr(1, "class", "row hot"))
    top.edits.push(Edit.set_flag(2, "hidden", false))
    top.edits.push(Edit.remove_attr(3, "data-x"))
    top.edits.push(Edit.set_handler(4, "click", 12))
    top.edits.push(Edit.remove_handler(4, "dblclick"))
    top.edits.push(Edit.set_text(0, "Count: 1"))
    top.edits.push(Edit.set_markup(1, "<i>x</i>"))
    top.edits.push(Edit.relocate(2, 0))
    top.edits.push(Edit.remove(3))
    top.edits.push(Edit.step_out)
    batch.updates.push(top)
    var child: ComponentUpdate = new ComponentUpdate(3)
    child.edits.push(Edit.set_text(0, "child"))
    batch.updates.push(child)
    batch.disposed.push(7)
    batch.disposed.push(9)

    r.eqi("6.2 twelve edit opcodes on the parent", top.edits.len(), 12)

    var want: List<string> = []
    want.push(r#"{"t":"batch","b":43,"r":["#)
    want.push(r#"["o",0,"div"],"#)
    want.push(r#"["a",1,"class","row"],"#)
    want.push(r#"["f",2,"hidden",true],"#)
    want.push(r#"["s",3,1],"#)
    want.push(r#"["a",3,"data-x","1"],"#)
    want.push(r#"["h",4,"click",11],"#)
    want.push(r#"["e",5],"#)
    want.push(r#"["v",6],"#)
    want.push(r#"["t",7,"hi \u003cb>"],"#)
    want.push(r#"["r",8,"\u003ci>raw\u003c/i>"],"#)
    want.push(r#"["k",9,"\u003chr>"],"#)
    want.push(r#"["c",10,"Counter",3],"#)
    want.push(r#"["g",11,"k1"],"#)
    want.push(r#"["t",0,"row"],"#)
    want.push(r#"["G"],"#)
    want.push(r#"["p",12],"#)
    want.push(r#"["b",0,true],"#)
    want.push(r#"["B"],"#)
    want.push(r#"["P"],"#)
    want.push(r#"["z"]"#)
    want.push(r#"],"u":[{"c":0,"e":["#)
    want.push(r#"["in",0,0],"#)
    want.push(r#"["si",0],"#)
    want.push(r#"["sa",1,"class","row hot"],"#)
    want.push(r#"["sf",2,"hidden",false],"#)
    want.push(r#"["ra",3,"data-x"],"#)
    want.push(r#"["sh",4,"click",12],"#)
    want.push(r#"["rh",4,"dblclick"],"#)
    want.push(r#"["ut",0,"Count: 1"],"#)
    want.push(r#"["um",1,"\u003ci>x\u003c/i>"],"#)
    want.push(r#"["mv",2,0],"#)
    want.push(r#"["rm",3],"#)
    want.push(r#"["so"]"#)
    want.push(r#"]},{"c":3,"e":[["ut",0,"child"]]}],"d":[7,9]}"#)
    r.eq("6.3 the batch on the wire", encode_batch(43, batch), cat(want))

    // A batch that carries nothing still encodes: `publish` is what decides an
    // empty batch never goes out, and that decision belongs to the circuit.
    r.eq("6.4 an empty batch", encode_batch(1, new Batch()),
         r#"{"t":"batch","b":1,"r":[],"u":[],"d":[]}"#)

    // ========================================================== § 7
    io.println("")
    io.println("-- 7. the other server frames")

    r.eqi("7.1 the protocol number", WIRE_VERSION, 1)
    r.eq("7.2 hello", encode_hello("0123456789abcdef0123", wide),
         r#"{"t":"hello","v":1,"c":"0123456789abcdef0123","mx":65536}"#)
    r.eq("7.3 hello carries the cap that is actually in force",
         encode_hello("id0123456789abcdef", small(4096, 24, 512, 1024)),
         r#"{"t":"hello","v":1,"c":"id0123456789abcdef","mx":4096}"#)
    r.eq("7.4 err", encode_err("panic", "t7"),
         r#"{"t":"err","k":"panic","m":"t7"}"#)
    r.eq("7.5 bye", encode_bye("limit", "the inbox is full"),
         r#"{"t":"bye","k":"limit","m":"the inbox is full"}"#)
    var args: List<string> = []
    args.push("#app")
    args.push("a\"b")
    r.eq("7.6 js", encode_js(5, "focus", args),
         r##"{"t":"js","i":5,"f":"focus","a":["#app","a\"b"]}"##)
    var noargs: List<string> = []
    r.eq("7.7 js with no arguments", encode_js(1, "ping", noargs),
         r#"{"t":"js","i":1,"f":"ping","a":[]}"#)
    r.eq("7.8 nav", encode_nav("/counter/3"),
         r#"{"t":"nav","u":"/counter/3"}"#)

    // ========================================================== § 8
    io.println("")
    io.println("-- 8. the escaper")
    //
    // RFC 8259 requires the quote, the backslash and every byte below 0x20.
    // Three more are escaped on purpose and each is a separate assertion,
    // because "it still parses" is true whether or not they are there.

    r.eq("8.1 quote and backslash", escaped("a\"b\\c"), "\"a\\\"b\\\\c\"")
    r.eq("8.2 the named control escapes",
         escaped("\u{8}\t\n\u{c}\r"), r#""\b\t\n\f\r""#)
    r.eq("8.3 an unnamed control byte", escaped("\u{1}\u{1f}"),
         r#""\u0001\u001f""#)
    r.eq("8.4 a less-than can never leave a JSON string",
         escaped("</script>"), r#""\u003c/script>""#)
    r.eq("8.5 U+2028 and U+2029, legal in JSON and fatal in JavaScript",
         escaped("a\u{2028}b\u{2029}c"), r#""a\u2028b\u2029c""#)
    r.eq("8.6 greater-than and ampersand stay raw, so a golden reads",
         escaped("a>b&c"), r#""a>b&c""#)
    r.eq("8.7 U+2028 at the very end", escaped("x\u{2028}"), r#""x\u2028""#)
    r.eq("8.8 other three-byte UTF-8 starting E2 80 is untouched",
         escaped("\u{2026}"), "\"\u{2026}\"")
    r.eq("8.9 astral characters pass through", escaped("\u{1f600}"),
         "\"\u{1f600}\"")
    r.eq("8.10 the empty string", escaped(""), "\"\"")

    // Round trip: everything the escaper writes, the reader reads back.
    let awkward: string = "a\"b\\c<d>e&f\n\t\u{1}\u{2028}\u{2029}\u{1f600}\u{e9}"
    r.eq("8.11 escaper and reader agree", read(escaped(awkward), wide),
         "\"{awkward}\"")

    // ========================================================== § 9
    io.println("")
    io.println("-- 9. client messages: every kind, and every refusal")

    r.eq("9.1 attach", told(r#"{"t":"attach","c":"abc","u":"/counter/3"}"#, wide),
         "attach c=abc u=/counter/3")
    r.eq("9.2 attach with no url is still an attach",
         told(r#"{"t":"attach","c":"abc"}"#, wide), "attach c=abc u=")
    r.eq("9.3 attach with no circuit id",
         told(r#"{"t":"attach","u":"/"}"#, wide),
         "REFUSED attach carries no circuit id")
    r.eq("9.4 attach whose circuit id is not a string",
         told(r#"{"t":"attach","c":7}"#, wide),
         "REFUSED attach carries no circuit id")

    r.eq("9.5 resume", told(r#"{"t":"resume","c":"abc","a":3}"#, wide),
         "resume c=abc a=3")
    r.eq("9.6 resume from batch zero",
         told(r#"{"t":"resume","c":"abc","a":0}"#, wide), "resume c=abc a=0")
    r.eq("9.7 resume with no ack", told(r#"{"t":"resume","c":"abc"}"#, wide),
         "REFUSED resume carries no acknowledged batch")
    r.eq("9.8 resume with a negative ack",
         told(r#"{"t":"resume","c":"abc","a":-1}"#, wide),
         "REFUSED resume carries no acknowledged batch")
    r.eq("9.9 resume with no circuit id", told(r#"{"t":"resume","a":1}"#, wide),
         "REFUSED resume carries no circuit id")

    r.eq("9.10 ack", told(r#"{"t":"ack","b":42}"#, wide), "ack b=42")
    r.eq("9.11 ack for batch zero", told(r#"{"t":"ack","b":0}"#, wide), "ack b=0")
    r.eq("9.12 ack with no batch", told(r#"{"t":"ack"}"#, wide),
         "REFUSED ack carries no batch number")
    r.eq("9.13 ack with a negative batch", told(r#"{"t":"ack","b":-3}"#, wide),
         "REFUSED ack carries no batch number")

    r.eq("9.14 nav", told(r#"{"t":"nav","u":"/x"}"#, wide), "nav u=/x")
    r.eq("9.15 nav with no url", told(r#"{"t":"nav"}"#, wide),
         "REFUSED nav carries no url")

    r.eq("9.16 js result", told(r#"{"t":"js","i":2,"ok":true,"v":"done"}"#, wide),
         "js i=2 ok=true v=done")
    r.eq("9.17 js failure", told(r#"{"t":"js","i":2,"ok":false,"v":"nope"}"#, wide),
         "js i=2 ok=false v=nope")
    r.eq("9.18 js with no call id", told(r#"{"t":"js","ok":true}"#, wide),
         "REFUSED a js result carries no call id")

    // `c` is the count and `n` is NEVER the count: `n` is the message sequence
    // on every client message. 9.23a is the positive control for that split —
    // a range that carries BOTH, where the count and the sequence are
    // different numbers and each has to land in its own field.
    r.eq("9.19 range", told(r#"{"t":"range","h":4,"s":10,"c":20}"#, wide),
         "range h=4 s=10 c=20")
    r.eq("9.20 range from zero", told(r#"{"t":"range","h":0,"s":0,"c":0}"#, wide),
         "range h=0 s=0 c=0")
    r.eq("9.21 range with no region", told(r#"{"t":"range","s":0,"c":1}"#, wide),
         "REFUSED a range carries no region id")
    r.eq("9.22 range with a negative start",
         told(r#"{"t":"range","h":1,"s":-1,"c":1}"#, wide),
         "REFUSED a range must be two non-negative numbers")
    r.eq("9.23 range with a negative count",
         told(r#"{"t":"range","h":1,"s":0,"c":-1}"#, wide),
         "REFUSED a range must be two non-negative numbers")
    r.eq("9.23a range carrying a count AND a sequence",
         told(r#"{"t":"range","h":1,"s":0,"c":7,"n":3}"#, wide),
         "range h=1 s=0 c=7 seq=3")
    r.eq("9.23b range with no count at all",
         told(r#"{"t":"range","h":1,"s":0}"#, wide),
         "REFUSED a range must be two non-negative numbers")

    r.eq("9.24 a message with no t", told("\{\}", wide),
         "REFUSED a message with no \"t\"")
    r.eq("9.25 a message whose t is not a string", told(r#"{"t":5}"#, wide),
         "REFUSED a message with no \"t\"")
    r.eq("9.26 an unknown kind", told(r#"{"t":"whatever"}"#, wide),
         "REFUSED unknown message kind")

    // ========================================================== § 10
    io.println("")
    io.println("-- 10. events: a name selects a FAMILY, never a method")

    r.eq("10.1 mouse",
         told(r#"{"t":"ev","h":9,"k":"click","p":{"b":2,"x":12,"y":34}}"#, wide),
         "ev h=9 k=click fam=mouse b=2 x=12 y=34")
    r.eq("10.2 mouse with no payload",
         told(r#"{"t":"ev","h":9,"k":"click"}"#, wide),
         "ev h=9 k=click fam=mouse b=0 x=0 y=0")
    r.eq("10.3 input",
         told(r#"{"t":"ev","h":9,"k":"input","p":{"v":"hi","c":true}}"#, wide),
         "ev h=9 k=input fam=input v=[hi] c=true")
    r.eq("10.4 keyboard",
         told(r#"{"t":"ev","h":9,"k":"keydown","p":{"k":"Enter","r":true}}"#, wide),
         "ev h=9 k=keydown fam=key k=[Enter] r=true")
    r.eq("10.5 focus takes no payload",
         told(r#"{"t":"ev","h":9,"k":"blur","p":{}}"#, wide),
         "ev h=9 k=blur fam=focus")
    r.eq("10.6 submit coerces numbers and booleans to text",
         told(r#"{"t":"ev","h":9,"k":"submit","p":{"f":{"name":"bo","n":3,"ok":true}}}"#, wide),
         "ev h=9 k=submit fam=submit f\{n=[3],name=[bo],ok=[true]\}")
    r.eq("10.7 submit drops a member that is neither text, number nor bool",
         told(r#"{"t":"ev","h":9,"k":"submit","p":{"f":{"a":"1","b":null,"c":[1]}}}"#, wide),
         "ev h=9 k=submit fam=submit f\{a=[1]\}")
    r.eq("10.8 an unknown event name", told(r#"{"t":"ev","h":9,"k":"wat"}"#, wide),
         "REFUSED unknown event name")
    r.eq("10.9 the control: a name one letter away that IS known",
         told(r#"{"t":"ev","h":9,"k":"change"}"#, wide),
         "ev h=9 k=change fam=input v=[] c=false")
    r.eq("10.10 no handler id", told(r#"{"t":"ev","k":"click"}"#, wide),
         "REFUSED an event carries no handler id")
    r.eq("10.11 handler id zero is not a slot",
         told(r#"{"t":"ev","h":0,"k":"click"}"#, wide),
         "REFUSED an event carries no handler id")
    r.eq("10.12 a negative handler id",
         told(r#"{"t":"ev","h":-1,"k":"click"}"#, wide),
         "REFUSED an event carries no handler id")
    r.eq("10.13 a payload that is not an object",
         told(r#"{"t":"ev","h":1,"k":"click","p":[1]}"#, wide),
         "REFUSED an event payload must be an object")
    r.eq("10.14 submit fields that are not an object",
         told(r#"{"t":"ev","h":1,"k":"submit","p":{"f":[1]}}"#, wide),
         "REFUSED a submit payload's fields must be an object")
    r.eq("10.15 submit with no fields at all",
         told(r#"{"t":"ev","h":1,"k":"submit","p":{}}"#, wide),
         "ev h=1 k=submit fam=submit f\{\}")

    // The table itself, and the one property `latte.js` has to share with it.
    var names: List<string> = event_names()
    r.eqi("10.16 the table has twenty-one names", names.len(), 21)
    var unknown: int = 0
    for name: string in names {
        if event_family(name) == FAMILY_NONE { unknown += 1 }
    }
    r.eqi("10.17 every name in the table has a family", unknown, 0)
    var captured: List<string> = []
    for name: string in names {
        if event_captures(name) { captured.push(name) }
    }
    r.eq("10.18 exactly the four that do not bubble", captured.join(","),
         "mouseenter,mouseleave,focus,blur")
    r.eqi("10.19 a name outside the table has no family",
          event_family("scroll"), FAMILY_NONE)
    r.eqi("10.20 the empty name has no family", event_family(""), FAMILY_NONE)
    r.no("10.21 focusin bubbles, so it is not captured", event_captures("focusin"))
    var table: List<string> = []
    table.push("click dblclick mousedown mouseup mouseenter mouseleave mouseover ")
    table.push("mouseout mousemove contextmenu input change keydown keyup keypress ")
    table.push("submit reset focus blur focusin focusout")
    r.eq("10.22 the whole table, in the order latte.js registers it",
         names.join(" "), cat(table))

    // ========================================================== § 11
    io.println("")
    io.println("-- 11. the event objects a handler is given")

    let clicked: ClientMessage = decode_client(
        r#"{"t":"ev","h":9,"k":"click","p":{"b":2,"x":12,"y":34}}"#, wide)
    let mouse: MouseEvent = mouse_event(clicked)
    r.eq("11.1 MouseEvent", "{mouse.button}/{mouse.x}/{mouse.y}", "2/12/34")

    let typed: ClientMessage = decode_client(
        r#"{"t":"ev","h":9,"k":"input","p":{"v":"hi","c":true}}"#, wide)
    let input: InputEvent = input_event(typed)
    r.eq("11.2 InputEvent", "{input.value}/{input.checked}", "hi/true")

    let pressed: ClientMessage = decode_client(
        r#"{"t":"ev","h":9,"k":"keyup","p":{"k":"Escape","r":false}}"#, wide)
    let key: KeyboardEvent = keyboard_event(pressed)
    r.eq("11.3 KeyboardEvent", "{key.key}/{key.repeated}", "Escape/false")

    let posted: ClientMessage = decode_client(
        r#"{"t":"ev","h":9,"k":"submit","p":{"f":{"b":"2","a":"1"}}}"#, wide)
    let form: SubmitEvent = submit_event(posted)
    var form_names: List<string> = form.fields.keys()
    form_names.sort()
    r.eq("11.4 SubmitEvent carries the fields", form_names.join(","), "a,b")
    r.eq("11.5 and their values",
         "{form.fields["a"]}/{form.fields["b"]}", "1/2")
    // `FocusEvent` has no fields, so the honest assertion is the one about
    // what the DECODER did: a focus payload carrying another family's keys
    // fills nothing, because the family selects what is read and a wire string
    // never names a field.
    let sneaky: ClientMessage = decode_client(
        r#"{"t":"ev","h":9,"k":"focus","p":{"v":"x","b":3,"k":"Enter","c":true}}"#,
        wide)
    let focus: FocusEvent = focus_event(sneaky)
    r.eq("11.6 a focus payload fills nothing",
         "[{sneaky.text}]/{sneaky.button}/[{sneaky.key}]/{sneaky.checked}",
         "[]/0/[]/false")

    // ========================================================== § 12
    io.println("")
    io.println("-- 12. Json accessors: a missing or wrong-kind member")

    match parse_json(r#"{"n":5,"s":"x","b":true,"a":[1,2],"o":{"k":1}}"#, wide) {
        ok(root) => {
            r.eqi("12.1 int_field", root.int_field("n", -1), 5)
            r.eqi("12.2 int_field on a string", root.int_field("s", -1), -1)
            r.eqi("12.3 int_field on a missing member", root.int_field("z", -1), -1)
            r.eq("12.4 text_field", root.text_field("s", "?"), "x")
            r.eq("12.5 text_field on a number", root.text_field("n", "?"), "?")
            r.yes("12.6 bool_field", root.bool_field("b", false))
            r.no("12.7 bool_field on a number", root.bool_field("n", false))
            r.eqi("12.8 len of the root object", root.len(), 5)
            match root.field("a") {
                some(list) => {
                    r.yes("12.9 field finds an array", list.is_array())
                    r.eqi("12.10 its length", list.len(), 2)
                    match list.at(1) {
                        some(second) => { r.eqi("12.11 at(1)", second.number, 2) }
                        none => { r.eq("12.11 at(1)", "missing", "2") }
                    }
                    r.no("12.12 at past the end", list.at(2).is_some())
                    r.no("12.13 at below zero", list.at(-1).is_some())
                }
                none => { r.eq("12.9 field finds an array", "missing", "true") }
            }
            r.no("12.14 a member that is not there", root.field("nope").is_some())
        }
        err(problem) => { r.eq("12.x the fixture parses", problem, "ok") }
    }

    r.yes("12.15 json_null", json_null().is_null())
    r.yes("12.16 json_bool", json_bool(true).truth)
    r.eqi("12.17 json_int", json_int(-4).number, -4)
    r.eq("12.18 json_text", json_text("z").text, "z")

    // ========================================================== § 13
    //
    // The message sequence and the `seen` fence.
    //
    // Wire v1.0 had no server frame meaning "I processed your message and it
    // changed nothing", so a client that sent one sat in `onmessage` until its
    // read deadline. `n` on a client message asks for a fence; `seen` is it.
    //
    // The refusals here need their positive control beside them: a bad `n` is
    // refused BEFORE the kind is looked at, so without 13.10-13.13 there would
    // be no evidence that a good `n` still reaches every kind rather than
    // being swallowed on the way.
    io.println("")
    io.println("-- 13. the message sequence, and the seen fence")

    r.eq("13.1 seen", encode_seen(1), r#"{"t":"seen","n":1}"#)
    r.eq("13.2 seen for a large sequence", encode_seen(9223372036854775807),
         r#"{"t":"seen","n":9223372036854775807}"#)

    r.eq("13.3 a message with no n asks for no fence",
         told(r#"{"t":"ack","b":4}"#, wide), "ack b=4")
    r.eq("13.4 n zero asks for no fence — it is the same statement as absent",
         told(r#"{"t":"ack","b":4,"n":0}"#, wide), "ack b=4")

    r.eq("13.5 a negative sequence", told(r#"{"t":"ack","b":4,"n":-1}"#, wide),
         "REFUSED a message sequence must not be negative")
    r.eq("13.6 a sequence that is a string",
         told(r#"{"t":"ack","b":4,"n":"7"}"#, wide),
         "REFUSED a message sequence must be a whole number")
    r.eq("13.7 a sequence that is a bool",
         told(r#"{"t":"ack","b":4,"n":true}"#, wide),
         "REFUSED a message sequence must be a whole number")
    r.eq("13.8 a sequence that is null",
         told(r#"{"t":"ack","b":4,"n":null}"#, wide),
         "REFUSED a message sequence must be a whole number")
    r.eq("13.9 a sequence that is an object",
         told(r#"{"t":"ack","b":4,"n":{}}"#, wide),
         "REFUSED a message sequence must be a whole number")

    // Every kind carries it. The fence rule is about MESSAGES, so a kind that
    // could not carry a sequence would be a hole in exactly the shape the
    // fence is supposed to close.
    r.eq("13.10 attach", told(r#"{"t":"attach","c":"abc","u":"/","n":1}"#, wide),
         "attach c=abc u=/ seq=1")
    r.eq("13.11 resume", told(r#"{"t":"resume","c":"abc","a":2,"n":2}"#, wide),
         "resume c=abc a=2 seq=2")
    r.eq("13.12 nav", told(r#"{"t":"nav","u":"/x","n":3}"#, wide),
         "nav u=/x seq=3")
    r.eq("13.13 js", told(r#"{"t":"js","i":1,"ok":true,"v":"","n":4}"#, wide),
         "js i=1 ok=true v= seq=4")
    r.eq("13.14 ev", told(r#"{"t":"ev","h":9,"k":"click","p":{"b":0,"x":1,"y":2},"n":5}"#, wide),
         "ev h=9 k=click fam=mouse b=0 x=1 y=2 seq=5")

    // The sequence is read from the ROOT and never from `p`. A form may post a
    // field literally called "n" and it must not be mistaken for one — this is
    // the same collision that made `range`'s count move off `n` to `c`.
    r.eq("13.15 a form field called n is a form field, not a sequence",
         told(r#"{"t":"ev","h":2,"k":"submit","p":{"f":{"n":"-3","q":"x"}},"n":6}"#, wide),
         "ev h=2 k=submit fam=submit f\{n=[-3],q=[x]\} seq=6")
    r.eq("13.16 the same form with no root sequence",
         told(r#"{"t":"ev","h":2,"k":"submit","p":{"f":{"n":"-3"}}}"#, wide),
         "ev h=2 k=submit fam=submit f\{n=[-3]\}")

    // The order between the two refusals, pinned on purpose. The sequence is a
    // property of every message, including one whose kind this end does not
    // know, so it is checked first — and 9.26 is the control that proves
    // "unknown message kind" still fires when `n` is fine.
    r.eq("13.17 a bad sequence on an unknown kind refuses on the sequence",
         told(r#"{"t":"whatever","n":-1}"#, wide),
         "REFUSED a message sequence must not be negative")
    r.eq("13.18 a good sequence on an unknown kind refuses on the kind",
         told(r#"{"t":"whatever","n":1}"#, wide),
         "REFUSED unknown message kind")

    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}
