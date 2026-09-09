// tests/w8_hostile.b — hostile frames that must never panic and never leak.
//
// `tests/w8_threats.b` is the index: one section per threat-table row, each
// asserting a refusal with a control beside it. This file is the volume test.
// It builds thousands of frames nobody would ever send — truncated, byte-
// substituted, over every cap, nested past the depth bound, wrong-typed in
// every field, keyed with the names a JavaScript prototype attack uses — and
// pushes each of them through the two things that read bytes off a socket:
// `decode_client`, and a whole `Circuit` state machine.
//
// **How "never panics" is proved.** A panic in Beans ends the process, so a
// run that reaches its last line panicked on none of its shapes. That is why
// the totals are printed at the END and why every family reports the number of
// shapes it actually fed: a suite that died on shape 4,000 of 9,000 produces a
// truncated golden diff, not a green run. `hostile.<family>.every-shape-was-fed`
// compares the number fed against the number generated, so a generator that
// quietly produced nothing cannot look like a family that survived everything.
//
// **How "never leaks" is proved.** Not here — by `w8b_leaks.sh`, which
// builds this file natively and runs it under macOS `leaks --atExit`. It says
// SKIP, loudly, on a machine without `leaks`. Every shape allocates a fresh
// `Circuit` with its two channels, so the corpus is also the leak corpus.
//
// **Why the golden is vocabularies and counts and not a transcript.** A
// hostile shape contains NUL bytes, lone `\xff`s and 32 KB strings; printing
// one would put them in the golden file. So what is printed is:
//
//   * per family, how many shapes were generated, refused and accepted — a
//     function of the generators, so a refusal that stopped refusing moves a
//     number;
//   * the DISTINCT set of fault sentences the whole corpus produced, digits
//     normalised to `#`, sorted. This is the strongest thing in the file: a
//     fault that echoed hostile bytes back at the client would appear here as
//     a new line full of them, and a fault text nobody decided cannot hide in
//     a count. It is also why no shape is ever printed — the vocabulary is the
//     evidence that nothing is echoed;
//   * the distinct `bye` kinds, and the distinct frame kinds that reached the
//     outbox — crossing a limit ends the circuit with a `bye`, never a
//     panic.
package main

import std.fmt
import std.io
import {Builder, Circuit, CircuitOptions, ClientMessage, Component, Json,
        WireLimits, decode_client, parse_json} from latte

// ============================================================== the report

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

/// A sorted set of strings, printed without counts.
///
/// Without counts on purpose: a count changes every time a generator grows a
/// shape, and a golden that has to be re-recorded for that reason stops being
/// read. The MEMBERSHIP is what matters — a fault sentence nobody decided, or
/// one carrying bytes off the wire, is a new line here.
pub class Vocabulary {
    seen: Map<string, bool> = {}
    pub fn init() {}
    pub fn add(text: string) { self.seen[text] = true }
    pub fn print(title: string) {
        io.println("")
        io.println("== {title} ==")
        var names: List<string> = self.seen.keys()
        names.sort()
        for name: string in names { io.println("   {name}") }
        io.println("   ({names.len()} distinct)")
    }
    pub fn size() -> int { return self.seen.len() }
    pub fn names() -> List<string> {
        var out: List<string> = self.seen.keys()
        out.sort()
        return move out
    }
    pub fn holds(name: string) -> bool { return self.seen.contains_key(name) }
}

/// Digits collapsed to `#`, so `"nesting deeper than 24"` and
/// `"nesting deeper than 4"` are one entry and a limit that moves does not
/// rewrite the golden.
fn normalise(text: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    var in_run: bool = false
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte >= 48 && byte <= 57 {
            if !in_run { out.push_byte(35) }
            in_run = true
        } else {
            in_run = false
            out.push_byte(byte)
        }
        index += 1
    }
    return out.to_string()
}

fn is_ascii_printable(text: string) -> bool {
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte < 32 || byte > 126 { return false }
        index += 1
    }
    return true
}

// ============================================================== the corpus

/// What one family did. Every number is a function of the generator, so a
/// refusal that stopped refusing moves one.
pub class Family {
    pub name: string = ""
    pub generated: int = 0
    pub fed: int = 0
    pub refused: int = 0
    pub accepted: int = 0
    /// Shapes that decoded with no fault AND no kind — the state that means
    /// "nobody decided". It must always be zero.
    pub limbo: int = 0
    /// Faults that carried a byte outside printable ASCII, or ran past the
    /// length bound. Must always be zero.
    pub loud: int = 0
    /// Circuits that ended, and circuits that survived the shape.
    pub ended: int = 0
    pub survived: int = 0
    /// The same two, for a circuit that had already ATTACHED.
    ///
    /// The first draft of this file fed only fresh circuits, and `dispatch`
    /// answers every non-attach message on one of those with
    /// `"a {kind} arrived before attach"`. So `on_event`, `on_ack`, `on_nav`,
    /// `on_js` and `on_range` — five of the seven message handlers, and every
    /// one of them the place a hostile field would actually land — were never
    /// reached by a single one of nine thousand shapes. The corpus was large
    /// and it was testing the decoder twice.
    pub attached_fed: int = 0
    pub attached_ended: int = 0
    pub attached_survived: int = 0
    /// A live circuit that was still attached after the shape, and one that
    /// was not. A shape that silently un-attached a live circuit without
    /// ending it would leave a page nobody can drive and no `bye` to say so.
    pub attached_still: int = 0
    pub attached_lost: int = 0
    pub fn init(name: string) { self.name = name }
}

/// Everything the corpus learned, across every family.
pub class Corpus {
    pub faults: Vocabulary = new Vocabulary()
    pub byes: Vocabulary = new Vocabulary()
    pub frames: Vocabulary = new Vocabulary()
    pub families: List<Family> = []
    pub fn init() {}
}

/// The longest a fault sentence may be. It is a sentence about the message and
/// it goes out on the wire in a `bye`, so a fault that grew to hold the input
/// would be both an information leak and an amplifier.
pub const FAULT_MAX: int = 160

/// Feed one hostile shape through both readers and charge what happened.
///
/// It takes `text` by value and never prints it. Nothing in this file prints a
/// shape: the golden would then hold NUL bytes and lone `\xff`s, and would stop
/// being a text file.
fn feed(c: Corpus, family: Family, text: string, limits: WireLimits) {
    family.fed += 1

    // ---- the decoder ----
    let message: ClientMessage = decode_client(text, limits)
    if message.fault != "" {
        family.refused += 1
        c.faults.add(normalise(message.fault))
        if !is_ascii_printable(message.fault) || message.fault.len() > FAULT_MAX {
            family.loud += 1
        }
    } else {
        family.accepted += 1
        if message.kind == 0 { family.limbo += 1 }
    }

    // ---- the whole state machine, in both of its states ----
    //
    // A fresh circuit per shape, because a circuit that ended stays ended and
    // the next shape would then be answered by `if self.ended { return }`
    // instead of by the code under test. This is also what makes the corpus a
    // leak corpus: two `Circuit`s, four `Channel`s and two `AtomicInt`s per
    // shape.
    //
    // BOTH states, because they run different code. A circuit that has not
    // attached answers every non-attach message with "arrived before attach"
    // and never reaches `on_event`, `on_ack`, `on_nav`, `on_js` or `on_range`
    // — which is where a hostile handler id, batch number, url, call id or
    // range actually lands.
    let fresh: Circuit = blank_circuit(limits)
    fresh.open(0)
    let _: List<string> = fresh.take_outbox()
    fresh.accept(text, 1)
    if fresh.ending() {
        family.ended += 1
        c.byes.add(fresh.end_reason())
    } else {
        family.survived += 1
    }
    for frame: string in fresh.take_outbox() { c.frames.add(frame_kind(frame)) }

    // The attached leg runs only on a shape the DECODER let through, and that
    // is a statement about `Circuit.accept` rather than a saving:
    //
    //     if message.fault != "" { self.stop("protocol", message.fault); return }
    //
    // comes before `dispatch`, so a shape the decoder refused reaches no
    // handler and the two states cannot tell it apart. Feeding all nine
    // thousand to a second circuit mounts nine thousand pages to re-prove
    // that. `section_refusal_comes_first` in `main` asserts the property it
    // rests on, with named cases and a control, instead.
    if message.fault != "" { return }
    let live: Circuit = blank_circuit(limits)
    live.open(0)
    live.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _2: List<string> = live.take_outbox()
    family.attached_fed += 1
    live.accept(text, 2)
    if live.ending() {
        family.attached_ended += 1
        c.byes.add(live.end_reason())
    } else {
        family.attached_survived += 1
        if live.is_attached() { family.attached_still += 1 }
        else { family.attached_lost += 1 }
    }
    for frame: string in live.take_outbox() { c.frames.add(frame_kind(frame)) }
}

fn blank_circuit(limits: WireLimits) -> Circuit {
    var options: CircuitOptions = new CircuitOptions()
    options.wire = limits
    return new Circuit("aaaaaaaaaaaaaaaaaaaa", options,
        fn(url: string) -> Option<Component> { return some(new Blank()) })
}

/// A page with nothing in it. The corpus is about the reader and the state
/// machine, not about what renders.
pub class Blank extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "blank") }
}

/// The `"t"` of an outgoing frame, read out of the frame rather than assumed.
/// An outgoing frame is latte's own JSON and always well formed, so a shape
/// that made one that is NOT is a finding, and `unparseable` is how it shows.
fn frame_kind(frame: string) -> string {
    let limits: WireLimits = new WireLimits()
    match parse_json(frame, limits) {
        err(problem) => { return "unparseable" }
        ok(root) => {
            let kind: string = root.text_field("t", "")
            if kind == "" { return "no-t" }
            return kind
        }
    }
}

// ============================================================== generators

/// The seven kinds, each spelled correctly. Everything below is these, broken.
fn seeds() -> List<string> {
    var out: List<string> = []
    out.push("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}")
    out.push("\{\"t\":\"resume\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"a\":1\}")
    out.push("\{\"t\":\"ev\",\"h\":2,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\}\}")
    out.push("\{\"t\":\"ack\",\"b\":1\}")
    out.push("\{\"t\":\"nav\",\"u\":\"/other\"\}")
    out.push("\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"x\"\}")
    out.push("\{\"t\":\"range\",\"h\":3,\"s\":0,\"c\":10\}")
    return move out
}

/// A string of `count` copies of `unit`.
fn repeat(unit: string, count: int) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < count { out.push(unit); index += 1 }
    return out.to_string()
}

/// `text` with the byte at `at` replaced by `byte`.
fn substitute(text: string, at: int, byte: int) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < text.len() {
        if index == at { out.push_byte(byte) } else { out.push_byte(text.byte_at(index)) }
        index += 1
    }
    return out.to_string()
}

/// The bytes worth substituting. Structural JSON punctuation, the two quote
/// characters, a backslash, a raw control byte, a lone continuation byte and a
/// byte no UTF-8 sequence may contain. A random alphabet would be a different
/// corpus on every run and its golden would be a photograph.
fn nasty_bytes() -> List<int> {
    var out: List<int> = []
    out.push(0)      // NUL
    out.push(9)      // TAB, a raw control byte inside a string
    out.push(34)     // "
    out.push(39)     // '
    out.push(44)     // ,
    out.push(45)     // -
    out.push(48)     // 0, for the leading-zero rule
    out.push(58)     // :
    out.push(91)     // [
    out.push(92)     // backslash
    out.push(93)     // ]
    out.push(123)    // {
    out.push(125)    // }
    out.push(128)    // a continuation byte with no lead
    out.push(255)    // never legal in UTF-8
    return move out
}

// ============================================================== the families

/// 1. Truncation: every prefix of every seed, including the empty one.
fn family_truncated(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("truncated")
    for seed: string in seeds() {
        var cut: int = 0
        for cut <= seed.len() {
            family.generated += 1
            feed(c, family, seed.slice(0, cut), limits)
            cut += 1
        }
    }
    return family
}

/// 2. One byte replaced, at every offset, by every nasty byte.
fn family_substituted(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("one byte substituted")
    let alphabet: List<int> = nasty_bytes()
    for seed: string in seeds() {
        var at: int = 0
        for at < seed.len() {
            for byte: int in alphabet {
                family.generated += 1
                feed(c, family, substitute(seed, at, byte), limits)
            }
            at += 1
        }
    }
    return family
}

/// 3. One byte INSERTED, at every offset, from the same alphabet. Substitution
///    keeps the length; insertion moves every offset after it, which is a
///    different failure for a reader that carries an index.
fn family_inserted(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("one byte inserted")
    let alphabet: List<int> = nasty_bytes()
    for seed: string in seeds() {
        var at: int = 0
        for at <= seed.len() {
            for byte: int in alphabet {
                family.generated += 1
                var out: fmt.StringBuilder = new fmt.StringBuilder()
                out.push(seed.slice(0, at))
                out.push_byte(byte)
                out.push(seed.slice(at, seed.len()))
                feed(c, family, out.to_string(), limits)
            }
            at += 1
        }
    }
    return family
}

/// 4. The depth ladder, walked from 1 to well past the cap, in arrays, in
///    objects, and alternating. Both sides of the bound are here: a reader
///    that refused one too early would move `accepted`.
fn family_depth(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("nesting depth")
    var depth: int = 1
    for depth <= limits.max_depth + 6 {
        family.generated += 3
        feed(c, family, "\{\"t\":\"nav\",\"u\":{repeat("[", depth)}{repeat("]", depth)}\}", limits)
        feed(c, family, "\{\"t\":\"nav\",\"u\":{repeat("\{\"k\":", depth)}1{repeat("\}", depth)}\}", limits)
        feed(c, family, "\{\"t\":\"nav\",\"u\":{repeat("[\{\"k\":", depth)}1{repeat("\}]", depth)}\}", limits)
        depth += 1
    }
    return family
}

/// 5. Every cap, at the value below it, at it, and above it.
///
/// The three-point ladder is the point. A single "over the cap" case passes
/// against a reader whose bound is off by one in either direction, and an
/// off-by-one on a size cap is a refusal that fires on a legal message.
fn family_sizes(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("size caps")

    // The message-length cap. `parse_json` measures the whole text before it
    // reads a byte, so the shape only has to be the right LENGTH.
    let head: string = "\{\"t\":\"nav\",\"u\":\""
    let tail: string = "\"\}"
    var over: int = -2
    for over <= 2 {
        family.generated += 1
        let body: int = limits.max_message - head.len() - tail.len() + over
        feed(c, family, "{head}{repeat("a", body)}{tail}", limits)
        over += 1
    }

    // The string-length cap, well inside the message cap.
    var span: int = -2
    for span <= 2 {
        family.generated += 1
        feed(c, family, "{head}{repeat("a", limits.max_text + span)}{tail}", limits)
        span += 1
    }

    // The array and object element caps.
    var items: int = -2
    for items <= 2 {
        family.generated += 2
        let n: int = limits.max_items + items
        feed(c, family, "\{\"t\":\"nav\",\"u\":[{repeat("1,", n - 1)}1]\}", limits)
        feed(c, family, "\{\"t\":\"nav\",\"u\":\{{repeat("\"k\":1,", n - 1)}\"k\":1\}\}", limits)
        items += 1
    }

    // Numbers at and past what this protocol carries.
    family.generated += 6
    feed(c, family, "\{\"t\":\"ack\",\"b\":9223372036854775807\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"b\":9223372036854775808\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"b\":99999999999999999999999999\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"b\":-9223372036854775808\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"b\":1.5\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"b\":1e400\}", limits)
    return family
}

/// 6. The keys a prototype-pollution attack uses, plus the degenerate ones.
///
/// Nothing off the wire is ever a name in latte, so every one of these must be
/// ordinary data. The check that matters is not that they are refused — it is
/// that they are handled the SAME way an unknown key is.
fn family_keys(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("hostile keys")
    var names: List<string> = []
    names.push("__proto__")
    names.push("constructor")
    names.push("prototype")
    names.push("toString")
    names.push("valueOf")
    names.push("hasOwnProperty")
    names.push("__defineGetter__")
    names.push("__lookupGetter__")
    names.push("")
    names.push(" ")
    names.push("t")
    names.push("\\u0000")
    names.push("\\ud800")
    names.push("\\udfff")
    names.push("\\ud800\\udc00")
    for name: string in names {
        family.generated += 3
        // As a key beside a legal message.
        feed(c, family, "\{\"t\":\"ack\",\"b\":1,\"{name}\":\{\"polluted\":1\}\}", limits)
        // As the ONLY key, so nothing legal carries it.
        feed(c, family, "\{\"{name}\":1\}", limits)
        // As a VALUE, which is where a name off the wire would have to be read
        // for any of this to matter.
        feed(c, family, "\{\"t\":\"{name}\"\}", limits)
    }
    // Duplicate keys: two spellings of one member, which every JSON reader
    // resolves differently and none of them documents.
    family.generated += 3
    feed(c, family, "\{\"t\":\"ack\",\"b\":1,\"b\":2\}", limits)
    feed(c, family, "\{\"t\":\"ack\",\"t\":\"nav\",\"b\":1,\"u\":\"/x\"\}", limits)
    feed(c, family, "\{\"t\":\"nav\",\"u\":\"/a\",\"u\":\"/b\"\}", limits)
    return family
}

/// 7. Every field of every kind, given the wrong type.
///
/// Six wrong values against each field of each seed. This is the family that
/// catches a reader that trusts `int_field` to have been given an int.
fn family_types(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("wrong types")
    var wrong: List<string> = []
    wrong.push("null")
    wrong.push("true")
    wrong.push("false")
    wrong.push("0")
    wrong.push("-1")
    // A POSITIVE one as well as a zero and a negative, because `n` is the
    // message sequence and zero means "no fence": with only 0 and -1 in this
    // list, no shape in the whole corpus ever asked for a `seen` and the
    // fence — B11, the thing that stops the client sitting in `onmessage`
    // forever — was never reached by the fuzz at all.
    wrong.push("1")
    wrong.push("9223372036854775807")
    wrong.push("\"\"")
    wrong.push("\"x\"")
    wrong.push("[]")
    wrong.push("\{\}")
    wrong.push("[1,2]")
    wrong.push("\{\"a\":1\}")

    var fields: List<string> = []
    fields.push("t")
    fields.push("c")
    fields.push("u")
    fields.push("h")
    fields.push("k")
    fields.push("p")
    fields.push("b")
    fields.push("a")
    fields.push("i")
    fields.push("ok")
    fields.push("v")
    fields.push("s")
    fields.push("n")

    for kind: string in ["attach", "resume", "ev", "ack", "nav", "js", "range"] {
        for name: string in fields {
            for value: string in wrong {
                family.generated += 1
                // The kind is spelled first, so a wrong `t` overwrites it and
                // every other field lands on a message that is otherwise the
                // legal shape for that kind.
                feed(c, family,
                     "\{\"t\":\"{kind}\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\",\"h\":1,\"k\":\"click\",\"b\":1,\"a\":1,\"i\":1,\"s\":0,\"{name}\":{value}\}",
                     limits)
            }
        }
    }
    return family
}

/// 8. Shapes that are not objects at all, and shapes that are not JSON.
fn family_shapes(c: Corpus, limits: WireLimits) -> Family {
    var family: Family = new Family("not a message")
    var texts: List<string> = []
    texts.push("")
    texts.push(" ")
    texts.push("null")
    texts.push("true")
    texts.push("false")
    texts.push("0")
    texts.push("-0")
    texts.push("00")
    texts.push("\"a string\"")
    texts.push("[]")
    texts.push("[\{\"t\":\"ack\",\"b\":1\}]")
    texts.push("\{\}")
    texts.push("\{\}\{\}")
    texts.push("\{\"t\":\"ack\",\"b\":1\} trailing")
    texts.push("\{\"t\":\"ack\",\"b\":1\}\{\"t\":\"ack\",\"b\":2\}")
    texts.push("\{'t':'ack'\}")
    texts.push("\{t:\"ack\"\}")
    texts.push("\{\"t\":\"ack\",\}")
    texts.push("\{\"t\"\}")
    texts.push("\{\"t\":\}")
    texts.push("\{:\"ack\"\}")
    texts.push("\{\"t\" \"ack\"\}")
    texts.push("[,]")
    texts.push("[1,]")
    texts.push("nul")
    texts.push("tru")
    texts.push("NaN")
    texts.push("Infinity")
    texts.push("-Infinity")
    texts.push("\{\"t\":\"ack\",\"b\":+1\}")
    texts.push("\{\"t\":\"ack\",\"b\":.5\}")
    texts.push("\{\"t\":\"ack\",\"b\":1.\}")
    texts.push("\{\"t\":\"ack\",\"b\":01\}")
    texts.push("\{\"t\":\"\\\\q\"\}")
    texts.push("\{\"t\":\"\\\\u00\"\}")
    texts.push("\{\"t\":\"\\\\uZZZZ\"\}")
    texts.push("\{\"t\":\"unclosed\}")
    for text: string in texts {
        family.generated += 1
        feed(c, family, text, limits)
    }
    return family
}

// ============================================================== the checks

/// The properties every family must hold, whatever it generated.
fn audit(r: Report, family: Family) {
    // The generator ran. A family that produced nothing would otherwise hold
    // every property below and read as a clean run.
    r.yes("hostile.{family.name}.the-generator-produced-shapes", family.generated > 0)
    // Everything generated was fed. This is the check that says the process
    // did not die partway: a panic on shape n ends the run before this line.
    r.eqi("hostile.{family.name}.every-shape-was-fed", family.fed, family.generated)
    // Every shape was decided one way or the other.
    r.eqi("hostile.{family.name}.refused-plus-accepted-is-every-shape",
          family.refused + family.accepted, family.generated)
    // No shape decoded into a message with no kind: a `ClientMessage` with an
    // empty fault and kind 0 is a message the dispatcher would fall off the
    // end of, and it is the state a defaulted field would produce.
    r.eqi("hostile.{family.name}.no-shape-decoded-into-limbo", family.limbo, 0)
    // No fault carried a byte off the wire, or grew past the bound.
    r.eqi("hostile.{family.name}.no-fault-is-loud", family.loud, 0)
    // Every shape reached a fresh circuit and it answered.
    r.eqi("hostile.{family.name}.every-fresh-circuit-answered",
          family.ended + family.survived, family.generated)
    // And every shape that got past the decoder reached an ATTACHED one — the
    // state where `on_event`, `on_ack`, `on_nav`, `on_js` and `on_range` are
    // the code that runs. A family whose accepted count is zero fed the second
    // leg nothing, and this check says so out loud rather than reading as a
    // clean run.
    r.eqi("hostile.{family.name}.every-decoded-shape-reached-an-attached-circuit",
          family.attached_fed, family.accepted)
    r.eqi("hostile.{family.name}.every-attached-circuit-answered",
          family.attached_ended + family.attached_survived, family.attached_fed)
    // A live circuit that survived a hostile shape is still attached. Losing
    // the attachment without ending would leave a mounted page nobody can
    // drive and no `bye` on the wire to say why.
    r.eqi("hostile.{family.name}.no-shape-silently-un-attached-a-live-circuit",
          family.attached_lost, 0)
}

/// The property the corpus's second leg rests on, asserted rather than assumed.
///
/// `Circuit.accept` refuses a message the decoder faulted BEFORE it dispatches,
/// so a shape the decoder refused reaches no handler and an attached circuit
/// answers it exactly as a fresh one does. That is why the corpus feeds the
/// attached leg only the shapes that decoded — and a claim used to skip nearly
/// eight thousand runs has to be a case, with the fault text spelled out and a
/// control that DOES reach a handler beside it.
fn section_refusal_comes_first(r: Report) {
    let limits: WireLimits = new WireLimits()
    var refused: List<string> = []
    refused.push("")
    refused.push("\{")
    refused.push("\{\"t\":\"ev\",\"h\":0,\"k\":\"click\"\}")
    refused.push("\{\"t\":\"ack\"\}")
    refused.push("\{\"t\":\"nope\"\}")
    refused.push("[1,2,3]")
    refused.push("\{\"t\":\"ack\",\"b\":1,\"n\":-1\}")
    refused.push("\{\"t\":\"range\",\"h\":1,\"s\":-1,\"c\":1\}")

    var index: int = 0
    for index < refused.len() {
        let text: string = refused[index]
        let fresh: Circuit = blank_circuit(limits)
        fresh.open(0)
        let _: List<string> = fresh.take_outbox()
        fresh.accept(text, 1)

        let live: Circuit = blank_circuit(limits)
        live.open(0)
        live.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
        let _2: List<string> = live.take_outbox()
        live.accept(text, 2)

        r.eq("hostile.refusal-comes-first.{index}",
             "{fresh.end_reason()}/{live.end_reason()}", "protocol/protocol")
        r.eq("hostile.refusal-comes-first.{index}-same-message",
             fresh.take_outbox().join(" "), live.take_outbox().join(" "))
        index += 1
    }

    // The control: a message the decoder ACCEPTS is answered differently by the
    // two states, so the pairs above are equal because the refusal came first
    // and not because the two circuits are the same circuit.
    let click: string = "\{\"t\":\"ack\",\"b\":0\}"
    let fresh: Circuit = blank_circuit(limits)
    fresh.open(0)
    let _3: List<string> = fresh.take_outbox()
    fresh.accept(click, 1)
    let live: Circuit = blank_circuit(limits)
    live.open(0)
    live.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _4: List<string> = live.take_outbox()
    live.accept(click, 2)
    r.eq("hostile.control-an-accepted-message-is-answered-differently",
         "{fresh.end_reason()}/{live.end_reason()}", "protocol/")
}

fn main() {
    var r: Report = new Report()
    var c: Corpus = new Corpus()
    let limits: WireLimits = new WireLimits()

    section_refusal_comes_first(r)

    // The size family alone builds several 64 KB strings, so it gets a smaller
    // WireLimits: the caps are what is under test, not the machine.
    var small: WireLimits = new WireLimits()
    small.max_message = 4096
    small.max_depth = 8
    small.max_items = 32
    small.max_text = 1024

    c.families.push(family_truncated(c, limits))
    c.families.push(family_substituted(c, limits))
    c.families.push(family_inserted(c, limits))
    c.families.push(family_depth(c, small))
    c.families.push(family_sizes(c, small))
    c.families.push(family_keys(c, limits))
    c.families.push(family_types(c, limits))
    c.families.push(family_shapes(c, limits))

    io.println("")
    io.println("== what each family generated ==")
    var total: int = 0
    for family: Family in c.families {
        total += family.generated
        io.println("   {family.name}: {family.generated} shapes, {family.refused} refused, {family.accepted} accepted; fresh circuit ended {family.ended}, attached circuit ended {family.attached_ended}")
    }
    io.println("   TOTAL: {total} hostile shapes")

    io.println("")
    for family: Family in c.families { audit(r, family) }

    c.faults.print("the fault vocabulary, digits normalised")
    c.byes.print("the bye kinds a hostile shape produced")
    // Not every frame latte can send — the ones a hostile CLIENT MESSAGE can
    // cause. `hello` is taken off the outbox before the shape is fed, `err`
    // needs a handler that panics and the page here has none, and `nav` and
    // `js` are server-driven. So this set is complete for this corpus and a
    // new member means a shape reached an encoder that did not expect it.
    c.frames.print("the outbox frame kinds a hostile shape produced")

    // The three vocabularies are the load-bearing part of this golden, so they
    // get assertions of their own rather than only being printed. A frame kind
    // latte's own encoders cannot produce means a hostile shape reached the
    // encoder with something it did not expect.
    r.no("hostile.no-outbox-frame-was-unparseable", c.frames.holds("unparseable"))
    r.no("hostile.no-outbox-frame-lacked-a-kind", c.frames.holds("no-t"))
    r.yes("hostile.the-corpus-produced-byes", c.byes.size() > 0)
    r.yes("hostile.the-corpus-produced-faults", c.faults.size() > 0)

    io.println("")
    io.println("{total} hostile shapes, {r.checks} checks, {r.bad} failed")
}
