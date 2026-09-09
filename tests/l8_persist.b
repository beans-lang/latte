// `@persist`: the state a page carries across a prerender, and every way it is
// refused.
//
// The island leaves the server, sits in a document a person can read and edit,
// and comes back. So every value in it is a value the user chose, and the
// suite is mostly about that: a round trip, and then six ways of arriving with
// something that must not be believed. Each refusal has the accepted island
// beside it — without that, "a tampered island is refused" reads the same as
// "no island is ever accepted", which is a much easier thing to build.
//
// The signer here is two closures over a toy MAC. It is not std.crypto and does
// not need to be: what is under test is that the island is bound to the
// session, the url and the expiry, and a toy MAC binds them exactly as a real
// one does. `latte_app` supplies the real one.
package main

import std.io
import {Builder, CircuitOptions, CircuitSet, Component, Island, IslandOutcome,
        Islands, PersistOptions, PersistState, Renderer, STATE_MARKER,
        SeamSigner, ShellOptions, Signer, ViewModel, decode_state,
        describe_island, encode_state, pack_state, persist, render_shell,
        restore_models, restore_state, scan_persist} from latte

// ---------------------------------------------------------------- the model

pub class OrderModel extends ViewModel {
    @persist pub name: string = ""
    @persist pub cups: int = 0
    @persist pub decaf: bool = false
    @persist pub tip: float = 0.0
    /// Not persisted. It must survive a restore untouched — otherwise "restore
    /// wrote the persisted fields" could not be told from "restore wrote
    /// everything it could reach".
    pub note: string = "kept"
    pub fn init() { super.init() }
}

/// A model whose `@persist` field is not a scalar. `scan_persist` must name it.
pub class BadModel extends ViewModel {
    @persist pub rows: List<string> = []
    pub fn init() { super.init() }
}

/// THE CONTROL for the scan: a model with only scalar `@persist` fields, which
/// must NOT be named.
pub class GoodModel extends ViewModel {
    @persist pub label: string = ""
    pub fn init() { super.init() }
}

/// A page that holds one. This is the shape the whole feature is for: a POST
/// renders it holding what the post produced, and the circuit that attaches
/// afterwards would otherwise render it pristine.
pub class OrderPage extends Component {
    pub order: OrderModel = new OrderModel()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "{self.order.name}/{self.order.cups}")
        b.close()
    }
}

// ---------------------------------------------------------------- the signer

/// A toy MAC: the length of the payload and a fold of its bytes. Not a
/// cryptographic function and not pretending to be — it binds the same four
/// inputs, which is the property under test.
fn toy_sign(data: string) -> string {
    var fold: int = 7
    for index: int in 0..data.len() {
        fold = (fold * 31 + data.byte_at(index)) % 1000000007
    }
    return "{data.len()}x{fold}"
}

fn toy_same(left: string, right: string) -> bool { return left == right }

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

fn islands(seconds: int, max_bytes: int) -> Islands {
    var options: PersistOptions = new PersistOptions()
    options.seconds = seconds
    options.max_bytes = max_bytes
    let signer: Signer = new SeamSigner(toy_sign, toy_same)
    return new Islands(signer, options)
}

const SESSION: string = "0123456789abcdef"
const URL: string = "/order/4"

// A circuit id is 256 bits from the host's CSPRNG and the set refuses anything
// under 16 characters — a short id is a guessable one, and guessing one hands
// over a live page.
const ID1: string = "0123456789abcdef0123456789abcd01"
const ID2: string = "0123456789abcdef0123456789abcd02"
const ID3: string = "0123456789abcdef0123456789abcd03"

fn main() {
    let box: Islands = islands(300, 4096)

    io.println("== 1. a model packs into flat text ==")
    var model: OrderModel = new OrderModel()
    model.name = "Ada"
    model.cups = 2
    model.decaf = true
    model.tip = 1.5
    model.note = "changed"
    let packed: PersistState = pack_state(model)
    report("four fields packed", "{packed.len()}", "4")
    report("and the un-annotated one did not", "{packed.values.contains_key("note")}", "false")
    report("the flat form is sorted and stable", encode_state(packed),
           "cups=2&decaf=true&name=Ada&tip=1.5")

    io.println("")
    io.println("== 2. sealed, and opened again ==")
    var sealed: string = ""
    match box.seal(packed, SESSION, URL, 1000) {
        err(problem) => { io.println("FAIL seal: {problem}") }
        ok(text) => { sealed = text }
    }
    report("it is expiry.mac.body", "{sealed.slice(0, 5)}", "1300.")
    // THE CONTROL for everything below: the untouched island opens.
    let opened: Island = box.open(sealed, SESSION, URL, 1000)
    report("THE CONTROL: an untouched island is valid",
           describe_island(opened.outcome), "the island is valid")

    io.println("")
    io.println("== 3. restored onto a fresh model ==")
    var fresh: OrderModel = new OrderModel()
    let problems: List<string> = restore_state(fresh, opened.state)
    report("nothing was refused", problems.join(" | "), "")
    report("string", fresh.name, "Ada")
    report("int", "{fresh.cups}", "2")
    report("bool", "{fresh.decaf}", "true")
    report("float", "{fresh.tip}", "1.5")
    report("and the un-annotated field was NOT written", fresh.note, "kept")

    io.println("")
    io.println("== 4. six ways of not being believed ==")
    // Every one of these is a document a user could have edited by hand.
    let tampered_body: string = "{sealed.slice(0, sealed.len() - 3)}Bob"
    report("a changed body", describe_island(
        box.open(tampered_body, SESSION, URL, 1000).outcome),
        "the state island does not match this session and page")
    match sealed.find(".") {
        none => { io.println("FAIL the sealed island has no dot") }
        some(at) => {
            let forged_mac: string = "{sealed.slice(0, at + 1)}0x0{sealed.slice(sealed.len() - 30, sealed.len())}"
            report("a changed mac", describe_island(
                box.open(forged_mac, SESSION, URL, 1000).outcome),
                "the state island does not match this session and page")
        }
    }
    report("another session", describe_island(
        box.open(sealed, "ffffffffffffffff", URL, 1000).outcome),
        "the state island does not match this session and page")
    report("another page", describe_island(
        box.open(sealed, SESSION, "/order/9", 1000).outcome),
        "the state island does not match this session and page")
    report("past its expiry", describe_island(
        box.open(sealed, SESSION, URL, 9999).outcome),
        "the state island has expired")
    report("not expiry.mac.body at all", describe_island(
        box.open("nonsense", SESSION, URL, 1000).outcome),
        "the state island is malformed")
    report("no island at all", describe_island(
        box.open("", SESSION, URL, 1000).outcome),
        "the document carried no state island")

    io.println("")
    io.println("== 5. bounded ==")
    let small: Islands = islands(300, 16)
    match small.seal(packed, SESSION, URL, 1000) {
        ok(_) => { io.println("FAIL an oversize island was sealed") }
        err(problem) => {
            report("a page that carries too much is refused at seal", problem,
                   "this page's @persist state is 34 bytes and the limit is 16 — persist less, or raise PersistOptions.max_bytes deliberately")
        }
    }
    var empty: OrderModel = new OrderModel()
    // Every field at its default still packs — the point of the empty case is a
    // model with no @persist fields at all.
    var nothing: PersistState = new PersistState()
    match box.seal(nothing, SESSION, URL, 1000) {
        err(problem) => { io.println("FAIL sealing nothing: {problem}") }
        ok(text) => { report("nothing to carry is no island", "[{text}]", "[]") }
    }

    io.println("")
    io.println("== 6. a value that does not parse ==")
    // The island opened, so these bytes are the server's own. They can still be
    // wrong if a model's field changed type between the two renders, and the
    // field must keep the pristine value rather than take a guess.
    var bent: PersistState = new PersistState()
    bent.put("cups", "many")
    bent.put("name", "Ada")
    var partial: OrderModel = new OrderModel()
    let bent_problems: List<string> = restore_state(partial, bent)
    report("the bad one is reported", bent_problems.join(" | "),
           "\"many\" is not an int for \"cups\"")
    report("and it keeps its default", "{partial.cups}", "0")
    report("while the good one beside it is written", partial.name, "Ada")

    io.println("")
    io.println("== 7. the three bytes that would change what it parses as ==")
    var awkward: PersistState = new PersistState()
    awkward.put("name", "a&b=c%d")
    let wire: string = encode_state(awkward)
    report("they are escaped on the wire", wire, "name=a%26b%3Dc%25d")
    report("and come back as they were", decode_state(wire).get("name"), "a&b=c%d")

    io.println("")
    io.println("== 8. the startup scan ==")
    var found: List<string> = scan_persist()
    found.sort()
    report("exactly one model is refused", "{found.len()}", "1")
    report("and it is named, with the reason", found[0],
           "latte$entry.BadModel.rows is @persist but is a List<string>; only string, int, bool and float cross the seam")
    var named_good: bool = false
    for problem: string in found {
        if problem.contains("GoodModel") { named_good = true }
        if problem.contains("OrderModel") { named_good = true }
    }
    report("THE CONTROL: the scalar-only models are not named", "{named_good}", "false")

    // The site tally `test.sh`'s refusal-coverage leg reads. `persist.b` has
    // exactly one report site — the `@persist` field that cannot cross the
    // seam — and the two cases above reach it: a non-scalar field, and the
    // scalar-only control that must not.
    io.println("")
    io.println("-- the sites in persist.b, and how many shapes reach each")
    io.println("   1x persist_plan / a @persist field that is not a scalar")

    io.println("")
    io.println("== 9. the whole path: page -> island -> document -> page ==")
    // The renderer packs the ROOT page's view-models, keyed by the field name
    // the author wrote. A child's model is deliberately not packed — its key
    // would have to be a mounted slot id, which is stable only while the page
    // renders the same shape, and an island keyed on that restores onto the
    // wrong component the first time a $if goes the other way.
    var served: OrderPage = new OrderPage()
    served.order.name = "Ada"
    served.order.cups = 2
    let r1: Renderer = new Renderer()
    r1.mount(served)
    report("the page rendered what the post produced", r1.html(), "<p>Ada/2</p>")
    let carried: PersistState = r1.persist_state()
    report("its model packed, under the field name", encode_state(carried),
           "order.cups=2&order.decaf=false&order.name=Ada&order.tip=0")

    var document_state: string = ""
    match box.seal(carried, SESSION, URL, 1000) {
        err(problem) => { io.println("FAIL seal: {problem}") }
        ok(text) => { document_state = text }
    }
    var options: ShellOptions = new ShellOptions()
    options.title = "Order"
    options.state = document_state
    var document: string = ""
    match render_shell(options, r1.html()) {
        err(problem) => { io.println("FAIL render_shell: {problem}") }
        ok(text) => { document = text }
    }
    report("the document carries a marked HTML comment",
           "{document.contains("<!--{STATE_MARKER}")}", "true")
    // The CSP claim, asserted rather than assumed: latte ships
    // `script-src 'self'` with no unsafe-inline and the cafe asserts the
    // document holds no inline script at all. An island in a <script> block
    // would pass a browser and break that.
    report("and it is NOT an inline script", "{document.contains("<script>")}", "false")

    // What the client would send back, lifted straight out of the markup.
    var returned: string = ""
    match document.find("<!--{STATE_MARKER}") {
        none => { io.println("FAIL the island is not in the document") }
        some(at) => {
            let rest: string = document.slice(at + STATE_MARKER.len() + 4,
                                              document.len())
            match rest.find("-->") {
                none => { io.println("FAIL the island's comment never closes") }
                some(end) => { returned = rest.slice(0, end) }
            }
        }
    }
    report("what a client reads back is what was sealed",
           "{returned == document_state}", "true")

    let reopened: Island = box.open(returned, SESSION, URL, 1000)
    report("it opens", describe_island(reopened.outcome), "the island is valid")
    var attached: OrderPage = new OrderPage()
    let r2: Renderer = new Renderer()
    r2.mount(attached)
    report("a fresh page starts pristine", r2.html(), "<p>/0</p>")
    let restore_problems: List<string> = r2.restore_persist(reopened.state)
    report("restoring raised nothing", restore_problems.join(" | "), "")
    r2.mark(0)
    let _flushed: int = r2.flush()
    report("and the attached page is the one the post produced",
           r2.html(), "<p>Ada/2</p>")

    io.println("")
    io.println("== 10. an island edited in the document ==")
    // The document is markup a person can read and change. This is that.
    let edited: string = "{returned.slice(0, returned.len() - 1)}9"
    let refused: Island = box.open(edited, SESSION, URL, 1000)
    report("it is refused", describe_island(refused.outcome),
           "the state island does not match this session and page")
    var untouched: OrderPage = new OrderPage()
    let r3: Renderer = new Renderer()
    r3.mount(untouched)
    let _ignored: List<string> = r3.restore_persist(refused.state)
    r3.mark(0)
    let _flushed3: int = r3.flush()
    // The failure mode of this feature is the ABSENCE of this feature: a page
    // whose island was rejected renders pristine, which is exactly what it did
    // before any of this existed.
    report("and the page renders pristine, as it did before islands existed",
           r3.html(), "<p>/0</p>")

    io.println("")
    io.println("== 11. over a real circuit ==")
    // The same nine closures `latte.web` hands a socket, driven with no socket.
    // What is under test is the attach path: a client that read an island out
    // of its document sends it as `s`, and the page it gets back is the one the
    // POST produced rather than the pristine one.
    var circuit_options: CircuitOptions = new CircuitOptions()
    let set: CircuitSet = new CircuitSet(circuit_options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new OrderPage())
        })
    // The host's half: verify, then restore. Exactly what `latte_app` installs.
    set.restore = fn(page: Component, session: string, url: string,
                     island: string) -> string {
        if island == "" { return "" }
        let opened: Island = box.open(island, session, url, 1000)
        if !opened.ok() {
            return "a state island was refused: {describe_island(opened.outcome)}"
        }
        return restore_models(page, opened.state).join(" | ")
    }

    var facts: Map<string, string> = {}
    facts["id"] = ID1
    facts["session"] = SESSION
    let handle: int = set.open(facts, 0)
    let hello: List<string> = set.outbox(handle)
    report("the circuit opened", "{handle >= 0 && hello.len() == 1}", "true")

    let batches: List<string> = set.accept(handle,
        "\{\"t\":\"attach\",\"c\":\"{ID1}\",\"u\":\"{URL}\",\"s\":\"{document_state}\"\}", 1)
    report("attach answered one batch", "{batches.len()}", "1")
    report("and the page it rendered is the one the post produced",
           "{batches[0].contains("Ada/2")}", "true")

    // The control, and it is the one that matters: the same circuit set, the
    // same page, an attach carrying an island a person edited. It must render
    // pristine and log why — not render the edited values, and not fail.
    var tampered_facts: Map<string, string> = {}
    tampered_facts["id"] = ID2
    tampered_facts["session"] = SESSION
    let handle2: int = set.open(tampered_facts, 0)
    let _hello2: List<string> = set.outbox(handle2)
    let edited2: string = "{document_state.slice(0, document_state.len() - 1)}9"
    let batches2: List<string> = set.accept(handle2,
        "\{\"t\":\"attach\",\"c\":\"{ID2}\",\"u\":\"{URL}\",\"s\":\"{edited2}\"\}", 1)
    report("a tampered island still answers a batch", "{batches2.len()}", "1")
    report("but the page is pristine", "{batches2[0].contains("Ada/2")}", "false")

    // And an attach with no island at all — the ordinary GET case — is
    // untouched by any of this.
    var plain_facts: Map<string, string> = {}
    plain_facts["id"] = ID3
    plain_facts["session"] = SESSION
    let handle3: int = set.open(plain_facts, 0)
    let _hello3: List<string> = set.outbox(handle3)
    let batches3: List<string> = set.accept(handle3,
        "\{\"t\":\"attach\",\"c\":\"{ID3}\",\"u\":\"{URL}\"\}", 1)
    report("THE CONTROL: no island at all still attaches", "{batches3.len()}", "1")
    report("and renders pristine", "{batches3[0].contains("Ada/2")}", "false")
    report("the set recorded no faults", "{set.faults.len()}", "0")
}
