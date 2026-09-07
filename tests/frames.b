// The slot-id gate, and the Builder's refusals.
//
// This suite exists because everything it asserts was WORKING and UNGATED. A
// regression to keying the mount table by the bare sequence number — which is
// what `probes/BUILDER.md` said before the W1 correction — would have gone
// green in this repo, because the one probe that exercised `component<T>` put
// it OUTSIDE the keyed region. One row is the shape RULES.md rule 4 says
// proves nothing, and it is exactly the shape that hid this.
//
// So: FIVE rows everywhere. Five is enough that a reorder is a real
// permutation rather than a swap, and enough that "all N rows share one child"
// reads as 1 against 5 rather than 1 against 2.
//
// Sections:
//   1  five keyed rows      — distinct children, buffers, handlers; reuse
//   2  reorder              — the same instances come back with their state
//   3  dispatch             — firing one row's id touches one row
//   4  the sweep            — a dropped row takes its child, buffer and handler
//   5  lifecycle            — on_init once, on_params_set every pass, should_render
//   6  refusals             — every fault the Builder can raise
//   7  unbalanced bodies    — a fragment that leaves an element open
//   8  boundaries           — ok, failed, failed mid-element, nested
//   9  handles              — an element `ref`, and `preserve`
//  10  a component-tag ref  — the assignment that replaced `Reference.child`
//  11  the factory mount    — component_made<T> over a closed generic
//  12  the dirty sink       — MountHandle, Component.id(), Callback.call
//  13  every fault site     — all 24, each with a trip, a control and a count
package main

import std.io
import {Builder, Callback, Component, DirtySink, Frame, FocusEvent, InputEvent,
        KeyboardEvent, MouseEvent, Reference, Renderer, Serializer, SubmitEvent,
        describe_frame} from latte

// ---------------------------------------------------------------- reporting
//
// Concrete values go in the golden so drift shows as a diff; the invariants
// that matter get an explicit ok/FAIL line so a person reading a failure is
// told what was supposed to be true, not left to compare two numbers.
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
            io.println("FAIL {name}: got {got}, want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

// ---------------------------------------------------------------- fixtures

/// A shared record every mounted Row writes to, so disposal — which happens
/// after the component is unreachable from the test — is still observable.
pub class Ledger {
    pub disposed: List<string> = []
    pub fn init() {}
    pub fn record(label: string) { self.disposed.push(label) }
}

/// A child component with its own state. `inits` counts activations,
/// `sets` counts setter runs, `params` counts `on_params_set`. Reuse is
/// `inits == 1` while `sets` climbs; re-activation would reset both.
pub class Row extends Component {
    pub label: string = ""
    pub inits: int = 0
    pub sets: int = 0
    pub params: int = 0
    pub renders: int = 0
    pub clicks: int = 0
    pub quiet: bool = false
    pub ledger: Option<Ledger> = none

    pub fn init() {}

    pub override fn on_init() { self.inits += 1 }
    pub override fn on_params_set() { self.params += 1 }
    pub override fn should_render() -> bool { return !self.quiet }

    pub override fn dispose() {
        match self.ledger {
            some(book) => { book.record(self.label) }
            none => {}
        }
    }

    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "span")
        b.text(1, "{self.label}/{self.sets}/{self.clicks}")
        b.close()
    }
}

/// A keyed loop with a handler AND a mounted child in each row, both at one
/// source position. This is the shape the old rule got wrong: `on_click(1, …)`
/// and `component<Row>(2, …)` are called five times with the same seq.
pub class Table extends Component {
    pub rows: List<string> = []
    pub ledger: Ledger = new Ledger()
    pub hits: Map<string, int> = {}
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "ul")
        for id: string in self.rows {
            b.region(1, id)
            b.open(0, "li")
            b.attr(1, "data-key", id)
            b.on_click(2, fn(e: MouseEvent) { self.bump(id) })
            b.component<Row>(3, fn(r: Row) {
                r.label = id
                r.sets += 1
                r.ledger = some(self.ledger)
            })
            b.close()
            b.end_region()
        }
        b.close()
    }

    pub fn bump(id: string) {
        match self.hits.get(id) {
            some(n) => { self.hits[id] = n + 1 }
            none => { self.hits[id] = 1 }
        }
    }

    pub fn hits_for(id: string) -> int {
        match self.hits.get(id) {
            some(n) => { return n }
            none => { return 0 }
        }
    }
}

/// A component whose render body is supplied by the case, so a refusal can be
/// written inline without a class per case.
pub class Sheet extends Component {
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) { self.body(b) }
}

/// The child a component-tag `ref` hands back. `reload()` is PLAN.md's own
/// example of what an author does with one, and it is callable WITHOUT a
/// downcast only because the setup closure is typed `fn(Grid)`.
pub class Grid extends Component {
    pub rows: int = 0
    pub reloads: int = 0
    pub stamp: int = 0
    pub fn init() {}
    pub fn reload() { self.reloads += 1 }
    pub override fn render(b: Builder) {
        b.open(0, "table")
        b.text(1, "rows={self.rows} reloads={self.reloads} stamp={self.stamp}")
        b.close()
    }
}

/// `<Grid ref={self.grid} rows={self.rows} />`. W2 emits exactly this: a plain
/// assignment inside the setup closure the emitter already writes. There is no
/// attribute-position call, because a component tag opens no element and
/// `in_attributes` is therefore never set.
pub class Panel extends Component {
    pub grid: Option<Grid> = none
    pub rows: int = 0
    pub mounted: bool = true
    pub stamps: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if self.mounted {
            b.component<Grid>(1, fn(c: Grid) {
                c.rows = self.rows
                if c.stamp == 0 { self.stamps += 1; c.stamp = self.stamps }
                self.grid = some(c)
            })
        } else {
            b.text(5, "no grid")
        }
        b.close()
    }
}

/// Not a Component. `component<T>` cannot refuse this in the type system —
/// bounds in Beans are interfaces only — so it must be a fault.
pub class NotAComponent {
    pub value: int = 0
    pub fn init() {}
}

/// A real Component that reflection cannot activate: its initializer takes an
/// argument. `initializer()` still answers `some` — the descriptor exists — so
/// this reaches `ctor.call([])` and fails there, which is a DIFFERENT site from
/// the closed generic that has no descriptor at all.
pub class NeedsSeed extends Component {
    pub seed: int = 0
    pub fn init(seed: int) { self.seed = seed }
    pub override fn render(b: Builder) { b.text(0, "seed={self.seed}") }
}

/// The other way an activation fails: a zero-argument initializer that is not
/// `pub`. Reflection finds it and refuses to call it.
pub class HiddenInit extends Component {
    pub value: int = 0
    fn init() {}
    pub override fn render(b: Builder) { b.text(0, "hidden") }
}

// ---------------------------------------------------------------- frame reads

fn child_ids(b: Builder) -> List<int> {
    var out: List<int> = []
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            child(_, _, id) => { out.push(id) }
            _ => {}
        }
        index += 1
    }
    return move out
}

fn handler_ids(b: Builder) -> List<int> {
    var out: List<int> = []
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            handler(_, _, id) => { out.push(id) }
            _ => {}
        }
        index += 1
    }
    return move out
}

fn region_keys(b: Builder) -> List<string> {
    var out: List<string> = []
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            region_open(_, key) => { out.push(key) }
            _ => {}
        }
        index += 1
    }
    return move out
}

fn count_distinct(values: List<int>) -> int {
    var seen: Map<int, bool> = {}
    for value: int in values { seen[value] = true }
    return seen.len()
}

fn count_distinct_text(values: List<string>) -> int {
    var seen: Map<string, bool> = {}
    for value: string in values { seen[value] = true }
    return seen.len()
}

fn ints_to_text(values: List<int>) -> string {
    var out: string = ""
    var index: int = 0
    for index < values.len() {
        if index > 0 { out = "{out}," }
        out = "{out}{values[index]}"
        index += 1
    }
    return out
}

fn overlap(a: List<int>, b: List<int>) -> int {
    var seen: Map<int, bool> = {}
    for value: int in a { seen[value] = true }
    var shared: int = 0
    for value: int in b { if seen.contains_key(value) { shared += 1 } }
    return shared
}

/// The mounted `Row` behind a slot, or `none`. The mount table holds the
/// `reflect.Value` the activation produced (BLOCKERS.md B6), and the test
/// reads it back the same way the Builder does.
fn row_at(b: Builder, slot: int) -> Option<Row> {
    match b.children.get(slot) {
        some(stored) => { return stored.copy() as? Row }
        none => { return none }
    }
}

fn row_state(b: Builder, slot: int) -> string {
    match row_at(b, slot) {
        some(row) => {
            return "{row.label} inits={row.inits} sets={row.sets} params={row.params} renders={row.renders} clicks={row.clicks}"
        }
        none => { return "<no row at {slot}>" }
    }
}

fn buffer_dump(b: Builder, slot: int) -> string {
    match b.child_buffer(slot) {
        some(buffer) => { return buffer.dump() }
        none => { return "<no buffer at {slot}>" }
    }
}

fn render_body(b: Builder, body: fn(Builder)) {
    let sheet: Sheet = new Sheet()
    sheet.body = body
    b.render_root(sheet)
}

fn show_faults(b: Builder) {
    for fault: string in b.all_faults() { io.println("   fault: {fault}") }
}

/// The first fault, or a sentinel. `all_faults()[0]` on a builder that raised
/// none is a panic, and a panic ends the whole suite at that line — so a
/// refusal that stops working takes every later check down with it and names
/// nothing. This turns the same mistake into one FAIL that says which rule
/// went missing. `probes/delete_faults.sh` found all three of these by
/// deleting the report sites they guard.
fn first_fault(b: Builder) -> string {
    if b.all_faults().len() == 0 { return "<no fault was raised>" }
    return b.all_faults()[0]
}

fn html_of(b: Builder) -> string {
    let writer: Serializer = new Serializer()
    return writer.page(b)
}

// ---------------------------------------------------------------- sections

fn five_rows(r: Report, b: Builder, t: Table) {
    io.println("== 1 five keyed rows")
    b.render_root(t)

    let kids: List<int> = child_ids(b)
    let hands: List<int> = handler_ids(b)
    io.println("child ids:   {ints_to_text(kids)}")
    io.println("handler ids: {ints_to_text(hands)}")
    io.println("region keys: {region_keys(b)}")

    // The headline. Five rows, five children — not one child shared by five
    // rows, which is what a seq-keyed table gives.
    r.eqi("five rows mount five children", b.children.len(), 5)
    r.eqi("five rows get five buffers", b.nested.len(), 5)
    r.eqi("five rows bind five handlers", b.registry.mouse.len(), 5)
    r.eqi("five child frames", kids.len(), 5)
    r.eqi("five DISTINCT child ids", count_distinct(kids), 5)
    r.eqi("five handler frames", hands.len(), 5)
    r.eqi("five DISTINCT handler ids", count_distinct(hands), 5)

    // A slot id is page-unique across kinds too: a handler id is never also a
    // mount id, which is what lets one int be both on the wire.
    r.eqi("no id is both a mount and a handler", overlap(kids, hands), 0)
    r.eqi("no builder faults", b.all_faults().len(), 0)

    // Five buffers, each holding that row's own frames.
    var dumps: List<string> = []
    for slot: int in kids { dumps.push(buffer_dump(b, slot)) }
    r.eqi("five DISTINCT child buffers", count_distinct_text(dumps), 5)
    var index: int = 0
    for index < kids.len() {
        io.println("slot {kids[index]}: {row_state(b, kids[index])}")
        index += 1
    }
    io.println("html: {html_of(b)}")

    // Second pass at the same source positions: the same ids, and state that
    // climbed rather than reset. `inits` staying 1 is what separates reuse
    // from re-activation — a re-activated child would read inits=1 sets=1 too,
    // so the setter counter ALONE proves nothing.
    b.render_root(t)
    let kids2: List<int> = child_ids(b)
    let hands2: List<int> = handler_ids(b)
    r.eq("pass 2 reuses the same child ids", ints_to_text(kids2), ints_to_text(kids))
    r.eq("pass 2 reuses the same handler ids", ints_to_text(hands2), ints_to_text(hands))
    r.eqi("pass 2 mounts nothing new", b.children.len(), 5)
    index = 0
    for index < kids2.len() {
        io.println("slot {kids2[index]}: {row_state(b, kids2[index])}")
        index += 1
    }
    match row_at(b, kids2[2]) {
        some(row) => {
            r.eqi("row c was activated once", row.inits, 1)
            r.eqi("row c ran its setter twice", row.sets, 2)
            r.eqi("row c saw on_params_set twice", row.params, 2)
            r.eqi("row c rendered twice", row.renders, 2)
        }
        none => { r.yes("row c is mounted", false) }
    }
}

fn reorder(r: Report, b: Builder, t: Table) {
    io.println("== 2 reorder")
    let before: List<int> = child_ids(b)
    t.rows = ["e", "d", "c", "b", "a"]
    b.render_root(t)
    let after: List<int> = child_ids(b)
    io.println("child ids after reorder: {ints_to_text(after)}")
    io.println("region keys: {region_keys(b)}")

    // Reversed order, same five ids: each row's identity followed its KEY and
    // not its position. Position-keying would print the same list as before.
    var reversed: List<int> = []
    var index: int = before.len() - 1
    for index >= 0 { reversed.push(before[index]); index -= 1 }
    r.eq("a reorder permutes the ids", ints_to_text(after), ints_to_text(reversed))
    r.no("a reorder is not a no-op", ints_to_text(after) == ints_to_text(before))
    r.eqi("nothing was mounted or dropped", b.children.len(), 5)
    r.eqi("no handler was rebound", b.registry.mouse.len(), 5)

    index = 0
    for index < after.len() {
        io.println("slot {after[index]}: {row_state(b, after[index])}")
        index += 1
    }
    match row_at(b, after[0]) {
        some(row) => {
            r.eq("the row that moved to the front is still 'e'", row.label, "e")
            r.eqi("and it was never re-activated", row.inits, 1)
            r.eqi("and its counter kept climbing", row.sets, 3)
        }
        none => { r.yes("row e is mounted", false) }
    }
    io.println("html: {html_of(b)}")
}

fn dispatch(r: Report, b: Builder, t: Table) {
    io.println("== 3 dispatch")
    // The rows are e,d,c,b,a; handler ids are in that render order.
    let hands: List<int> = handler_ids(b)
    let target: int = hands[2]
    io.println("firing handler {target} (the third row rendered, key 'c')")
    let fired: bool = b.registry.fire_mouse(target, new MouseEvent())
    r.yes("the id dispatched", fired)
    r.eqi("row c was hit once", t.hits_for("c"), 1)
    r.eqi("row a was not hit", t.hits_for("a"), 0)
    r.eqi("row b was not hit", t.hits_for("b"), 0)
    r.eqi("row d was not hit", t.hits_for("d"), 0)
    r.eqi("row e was not hit", t.hits_for("e"), 0)
    r.eqi("one row in five was touched", t.hits.len(), 1)

    // An id from a family that never bound it is not a hit.
    r.no("a mouse id is not an input id", b.registry.fire_input(target, new InputEvent()))
    r.no("an unknown id finds nothing", b.registry.fire_mouse(9999, new MouseEvent()))
}

fn sweep(r: Report, b: Builder, t: Table) {
    io.println("== 4 the sweep")
    let before: List<int> = child_ids(b)
    let dropped_slot: int = before[2]
    let dropped_handler: int = handler_ids(b)[2]
    io.println("dropping key 'c' — slot {dropped_slot}, handler {dropped_handler}")

    t.rows = ["e", "d", "b", "a"]
    b.render_root(t)

    r.eqi("four rows mount four children", b.children.len(), 4)
    r.eqi("four rows keep four buffers", b.nested.len(), 4)
    r.eqi("four rows keep four handlers", b.registry.mouse.len(), 4)
    r.eqi("four child frames", child_ids(b).len(), 4)
    r.no("the dropped slot is gone", b.children.contains_key(dropped_slot))
    r.no("its buffer is gone", b.nested.contains_key(dropped_slot))
    r.no("its handler is forgotten", b.registry.mouse.contains_key(dropped_handler))
    r.no("a stale wire id finds nothing",
        b.registry.fire_mouse(dropped_handler, new MouseEvent()))
    r.eqi("row c was not hit again by the stale id", t.hits_for("c"), 1)

    // The component itself was disposed, which is only observable through the
    // ledger it wrote to before it went.
    io.println("disposed: {t.ledger.disposed}")
    r.eqi("exactly one component was disposed", t.ledger.disposed.len(), 1)
    r.eq("and it was row c", t.ledger.disposed[0], "c")

    // The survivors kept their identity through the drop.
    let after: List<int> = child_ids(b)
    io.println("child ids: {ints_to_text(after)}")
    var index: int = 0
    for index < after.len() {
        io.println("slot {after[index]}: {row_state(b, after[index])}")
        index += 1
    }
    match row_at(b, after[0]) {
        some(row) => { r.eqi("row e survived with its counter", row.sets, 4) }
        none => { r.yes("row e is mounted", false) }
    }

    // Re-adding the key mounts a NEW component: the id must not be recycled
    // into a live handler table while a client may still hold the old one.
    t.rows = ["e", "d", "c", "b", "a"]
    b.render_root(t)
    let back: List<int> = child_ids(b)
    io.println("child ids after 'c' returns: {ints_to_text(back)}")
    r.eqi("five rows again", b.children.len(), 5)
    r.no("the returning row did NOT get the dead slot back",
        back[2] == dropped_slot)
    match row_at(b, back[2]) {
        some(row) => {
            r.eq("the returning row is 'c'", row.label, "c")
            r.eqi("and it is a fresh component", row.sets, 1)
            r.eqi("activated once", row.inits, 1)
        }
        none => { r.yes("row c is mounted again", false) }
    }
}

fn lifecycle(r: Report) {
    io.println("== 5 lifecycle")
    let t: Table = new Table()
    t.rows = ["a", "b", "c", "d", "e"]
    let b: Builder = new Builder()
    b.render_root(t)
    let kids: List<int> = child_ids(b)

    // A component that answers `should_render() == false` keeps the frames it
    // already has. Its setter and on_params_set still run — the parent's data
    // reached it; it just decided the render would change nothing.
    match row_at(b, kids[1]) {
        some(row) => { row.quiet = true }
        none => {}
    }
    let quiet_before: string = buffer_dump(b, kids[1])
    b.render_root(t)
    let quiet_after: string = buffer_dump(b, kids[1])
    r.eq("a quiet child keeps its frames", quiet_after, quiet_before)
    match row_at(b, kids[1]) {
        some(row) => {
            r.eqi("but its setter ran", row.sets, 2)
            r.eqi("and on_params_set ran", row.params, 2)
            r.eqi("and render did NOT", row.renders, 1)
        }
        none => { r.yes("the quiet row is mounted", false) }
    }
    let loud_after: string = buffer_dump(b, kids[0])
    io.println("loud child: {loud_after}")
    io.println("quiet child: {quiet_after}")

    // Speaking again re-renders.
    match row_at(b, kids[1]) {
        some(row) => { row.quiet = false }
        none => {}
    }
    b.render_root(t)
    match row_at(b, kids[1]) {
        some(row) => { r.eqi("and it renders again when it stops being quiet", row.renders, 2) }
        none => {}
    }

    // Tearing the whole tree down disposes every child exactly once.
    t.rows = []
    b.render_root(t)
    var names: List<string> = []
    for name: string in t.ledger.disposed { names.push(name) }
    names.sort()
    io.println("disposed on teardown: {names}")
    r.eqi("every child was disposed", t.ledger.disposed.len(), 5)
    r.eqi("nothing is mounted", b.children.len(), 0)
    r.eqi("no buffers are left", b.nested.len(), 0)
    r.eqi("no handlers are left", b.registry.mouse.len(), 0)
}

// ---------------------------------------------------------------- refusals

pub class Refusal {
    pub name: string = ""
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init(name: string, body: fn(Builder)) {
        self.name = name
        self.body = body
    }
}

fn refusals() -> List<Refusal> {
    var cases: List<Refusal> = []

    cases.push(new Refusal("unsafe-tag", fn(b: Builder) {
        // Substituted with <span> rather than dropped: dropping would silently
        // change the shape of the tree the differ walks.
        b.open(0, "sc ript>")
        b.text(1, "inside")
        b.close()
    }))

    cases.push(new Refusal("empty-tag", fn(b: Builder) {
        b.open(0, "")
        b.close()
    }))

    cases.push(new Refusal("unsafe-attribute-name", fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class\" onload=\"x", "y")
        b.attr(2, "ok", "kept")
        b.close()
    }))

    cases.push(new Refusal("inline-handler-attribute", fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "onclick", "steal()")
        b.flag(2, "onerror", true)
        b.close()
    }))

    cases.push(new Refusal("splatted-refusals", fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["onmouseover"] = "steal()"
        extra["bad name"] = "x"
        extra["fine"] = "kept"
        b.open(0, "div")
        b.attrs(1, extra)
        b.close()
    }))

    cases.push(new Refusal("url-scheme", fn(b: Builder) {
        b.open(0, "a")
        b.attr(1, "href", "javascript:alert(1)")
        b.close()
    }))

    cases.push(new Refusal("url-scheme-obfuscated", fn(b: Builder) {
        // A browser drops TAB, LF and CR from inside a URL, so this reaches
        // the scheme parser as `javascript:`.
        b.open(0, "a")
        b.attr(1, "href", "java\tscript:alert(1)")
        b.close()
    }))

    cases.push(new Refusal("url-scheme-xlink", fn(b: Builder) {
        // W1's addition to BUILDER.md's six names: SVG's xlink:href runs
        // script in every browser that renders SVG.
        b.open(0, "a")
        b.attr(1, "xlink:href", "javascript:alert(1)")
        b.close()
    }))

    cases.push(new Refusal("url-scheme-allowed", fn(b: Builder) {
        // The allowlist must not refuse what it is there to permit, and a
        // colon inside a path is not a scheme.
        b.open(0, "a")
        b.attr(1, "href", "https://example.com/a:b")
        b.attr(2, "download", "javascript:not-a-url")
        b.close()
        b.open(3, "a")
        b.attr(4, "href", "/local/path:with-colon")
        b.close()
    }))

    cases.push(new Refusal("attribute-outside-its-run", fn(b: Builder) {
        b.open(0, "div")
        b.text(1, "content first")
        b.attr(2, "class", "too late")
        b.close()
    }))

    cases.push(new Refusal("attribute-out-of-order", fn(b: Builder) {
        b.open(0, "div")
        b.attr(3, "a", "1")
        b.attr(1, "b", "2")
        b.close()
    }))

    cases.push(new Refusal("attribute-name-out-of-order", fn(b: Builder) {
        // The half of the rule that only the differ needs: within one seq,
        // NAMES must increase too, because the differ merges the two attribute
        // runs on `(seq, name)` and the applier keeps its slots in that order.
        // A run the applier cannot reproduce is a gate-3 divergence, so it is
        // refused here instead.
        b.open(0, "div")
        b.attr(1, "z", "1")
        b.attr(1, "a", "2")
        b.close()
    }))

    cases.push(new Refusal("attribute-slot-repeats", fn(b: Builder) {
        // Two slots with one merge key is a merge with no answer.
        b.open(0, "div")
        b.attr(1, "same", "first")
        b.attr(1, "same", "second")
        b.close()
    }))

    cases.push(new Refusal("two-handlers-at-one-seq", fn(b: Builder) {
        // Both would call `slot_for(1)` and get the SAME id, so the wire could
        // only ever reach one of them — `registry.mouse[id]` holds whichever
        // bound last, while the frames claim two live handlers. Two handlers
        // are two source positions; sharing a seq is a markup-compiler bug and
        // the second is refused.
        b.open(0, "div")
        b.on_click(1, fn(e: MouseEvent) {})
        b.on_dblclick(1, fn(e: MouseEvent) {})
        b.close()
    }))

    cases.push(new Refusal("handler-then-attribute-at-one-seq", fn(b: Builder) {
        // NOT a refusal, and worth saying so: a handler takes `(seq, "")` and
        // a named attribute takes `(seq, name)`, so they are distinct keys in
        // distinct tables and nothing collides. Only two UNNAMED slots at one
        // seq collide, which is the case above.
        b.open(0, "div")
        b.on_click(1, fn(e: MouseEvent) {})
        b.attr(1, "class", "x")
        b.close()
    }))

    cases.push(new Refusal("splat-under-an-earlier-name", fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["a"] = "from splat"
        b.open(0, "div")
        b.attr(1, "z", "explicit")
        b.attrs(1, extra)
        b.close()
    }))

    cases.push(new Refusal("splat-then-name-at-one-seq", fn(b: Builder) {
        // Legal: the splat marker takes (2, ""), its entries take (2, "a") and
        // (2, "b"), and an explicit attribute at a later seq follows them all.
        var extra: Map<string, string> = {}
        extra["b"] = "two"
        extra["a"] = "one"
        b.open(0, "div")
        b.attr(1, "class", "first")
        b.attrs(2, extra)
        b.attr(3, "id", "last")
        b.close()
    }))

    cases.push(new Refusal("sibling-seq-goes-backwards", fn(b: Builder) {
        b.open(5, "p")
        b.close()
        b.open(2, "p")
        b.close()
    }))

    cases.push(new Refusal("sibling-seq-repeats", fn(b: Builder) {
        b.text(1, "one")
        b.text(1, "two")
    }))

    cases.push(new Refusal("duplicate-key", fn(b: Builder) {
        b.open(0, "ul")
        b.region(1, "same")
        b.text(0, "first")
        b.end_region()
        b.region(1, "same")
        b.text(0, "second")
        b.end_region()
        b.region(1, "same")
        b.text(0, "third")
        b.end_region()
        b.close()
    }))

    cases.push(new Refusal("close-with-nothing-open", fn(b: Builder) {
        b.close()
    }))

    cases.push(new Refusal("end-region-with-nothing-open", fn(b: Builder) {
        b.end_region()
    }))

    cases.push(new Refusal("end-boundary-with-nothing-open", fn(b: Builder) {
        b.end_boundary()
    }))

    cases.push(new Refusal("fail-boundary-with-nothing-open", fn(b: Builder) {
        b.fail_boundary("nothing to fail")
    }))

    cases.push(new Refusal("mount-a-non-component", fn(b: Builder) {
        // Bounds in Beans are interfaces only, so `component<T>` cannot demand
        // `T extends Component`. W2 refuses this at markup-compile time; the
        // Builder refuses it too, because a hand-written call never saw W2.
        b.component<NotAComponent>(0, fn(x: NotAComponent) { x.value = 1 })
    }))

    cases.push(new Refusal("region-left-open", fn(b: Builder) {
        b.open(0, "ul")
        b.region(1, "row")
        b.text(0, "no end_region")
        b.close()
    }))

    cases.push(new Refusal("element-left-open-at-pass-end", fn(b: Builder) {
        b.open(0, "div")
        b.open(1, "p")
        b.text(2, "neither is closed")
    }))

    return move cases
}

fn run_refusals(r: Report) {
    io.println("== 6 refusals")
    var total: int = 0
    for probe: Refusal in refusals() {
        let b: Builder = new Builder()
        render_body(b, probe.body)
        io.println("-- {probe.name}")
        io.println("   html: {html_of(b)}")
        io.println("   balanced: {b.balanced()}")
        for fault: string in b.all_faults() {
            io.println("   fault: {fault}")
            total += 1
        }
    }
    // Every refusal above must actually refuse something, except the two that
    // are there to prove the allowlist does not over-refuse.
    r.yes("the refusal corpus raised faults", total > 0)
    io.println("faults raised across the corpus: {total}")

    // The two that must stay silent, asserted on their own rather than left
    // to a reader of the dump.
    let clean: Builder = new Builder()
    render_body(clean, fn(b: Builder) {
        b.open(0, "a")
        b.attr(1, "href", "https://example.com/a:b")
        b.attr(2, "download", "javascript:not-a-url")
        b.close()
        b.open(3, "a")
        b.attr(4, "href", "/local/path:with-colon")
        b.close()
    })
    r.eqi("an allowed URL raises nothing", clean.all_faults().len(), 0)
    r.yes("and it is still balanced", clean.balanced())
}

// ---------------------------------------------------------------- unbalanced

fn unbalanced(r: Report) {
    io.println("== 7 unbalanced bodies")

    // A fragment body is written by the PARENT and placed in the child, so a
    // parent that leaves an element open would otherwise swallow the rest of
    // the child's markup. The builder closes it at the fragment's edge.
    let b: Builder = new Builder()
    render_body(b, fn(inner: Builder) {
        inner.open(0, "section")
        inner.fragment(1, fn(f: Builder) {
            f.open(0, "div")
            f.text(1, "the fragment never closes this")
        })
        inner.text(2, "after the fragment")
        inner.close()
    })
    io.println("html: {html_of(b)}")
    io.println(b.dump())
    show_faults(b)
    r.yes("the pass is balanced anyway", b.balanced())
    r.eqi("and it said so once", b.all_faults().len(), 1)
    r.yes("the text after the fragment is a sibling, not a child",
        html_of(b).contains("</div>after the fragment"))

    // A region left open inside a fragment: both are closed, both are faults,
    // and the frames still nest.
    let two: Builder = new Builder()
    render_body(two, fn(inner: Builder) {
        inner.fragment(0, fn(f: Builder) {
            f.region(0, "k")
            f.open(0, "li")
        })
        inner.text(1, "after")
    })
    io.println(two.dump())
    show_faults(two)
    r.yes("two unbalanced scopes, still balanced at the end", two.balanced())
    r.eqi("two faults", two.all_faults().len(), 2)
}

// ---------------------------------------------------------------- boundaries

fn boundaries(r: Report) {
    io.println("== 8 boundaries")

    let ok: Builder = new Builder()
    render_body(ok, fn(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "p")
        b.text(1, "the body rendered")
        b.close()
        b.end_boundary()
        b.close()
    })
    io.println("-- ok")
    io.println(ok.dump())
    io.println("   html: {html_of(ok)}")
    r.eqi("an ok boundary raises nothing", ok.all_faults().len(), 0)
    r.eqi("and records no failure", ok.failures.len(), 0)

    let failed: Builder = new Builder()
    render_body(failed, fn(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "p")
        b.text(1, "this content is thrown away")
        b.close()
        b.fail_boundary("the body panicked")
        b.open(0, "p")
        b.attr(1, "class", "error")
        b.text(2, "something went wrong")
        b.close()
        b.end_boundary()
        b.close()
    })
    io.println("-- failed")
    io.println(failed.dump())
    io.println("   html: {html_of(failed)}")
    r.eqi("a failed boundary raises no fault", failed.all_faults().len(), 0)
    r.eqi("and records the message", failed.failures.len(), 1)
    r.eq("the message", failed.failures[0], "the body panicked")
    r.no("the thrown-away content is gone",
        html_of(failed).contains("this content is thrown away"))
    r.yes("the fallback is what is left", html_of(failed).contains("something went wrong"))
    r.yes("the frame says failed", failed.dump().contains("1 boundary failed=true"))

    // The hard one: failing in the MIDDLE of an element, with the attribute
    // run half written. Everything the body opened has to be unwound, or the
    // fallback lands inside a dangling <div>.
    let midway: Builder = new Builder()
    render_body(midway, fn(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "div")
        b.attr(1, "class", "half-written")
        b.open(2, "span")
        b.text(3, "deep")
        b.fail_boundary("panicked three levels down")
        b.text(0, "fallback")
        b.end_boundary()
        b.close()
    })
    io.println("-- failed mid-element")
    io.println(midway.dump())
    io.println("   html: {html_of(midway)}")
    r.yes("the pass is balanced after unwinding three levels", midway.balanced())
    r.eqi("and no fault was needed to get there", midway.all_faults().len(), 0)
    r.eq("the html is the fallback inside main", html_of(midway), "<main>fallback</main>")

    // Nested: the inner one fails, the outer one carries on. A boundary that
    // swallowed its parent would be worse than no boundary at all.
    let nested: Builder = new Builder()
    render_body(nested, fn(b: Builder) {
        b.boundary(0)
        b.open(0, "section")
        b.text(1, "outer before ")
        b.boundary(2)
        b.open(0, "em")
        b.text(1, "inner body")
        b.close()
        b.fail_boundary("inner blew up")
        b.text(0, "inner fallback")
        b.end_boundary()
        b.text(3, " outer after")
        b.close()
        b.end_boundary()
    })
    io.println("-- nested, inner failed")
    io.println(nested.dump())
    io.println("   html: {html_of(nested)}")
    r.eqi("no faults", nested.all_faults().len(), 0)
    r.eqi("one failure, the inner one", nested.failures.len(), 1)
    r.eq("the outer boundary survived",
        html_of(nested), "<section>outer before inner fallback outer after</section>")
    r.yes("the outer frame is still ok", nested.dump().contains("0 boundary failed=false"))
    r.yes("the inner frame is failed", nested.dump().contains("2 boundary failed=true"))

    // A boundary that is never ended is closed by the sweep, loudly.
    let dangling: Builder = new Builder()
    render_body(dangling, fn(b: Builder) {
        b.boundary(0)
        b.text(0, "no end_boundary")
    })
    io.println("-- never ended")
    io.println(dangling.dump())
    show_faults(dangling)
    r.yes("closed by the sweep", dangling.balanced())
    r.eqi("with one fault", dangling.all_faults().len(), 1)
}

// ---------------------------------------------------------------- handles

fn handles(r: Report) {
    io.println("== 9 handles")
    let b: Builder = new Builder()
    let seen: Ledger = new Ledger()
    let body: fn(Builder) = fn(inner: Builder) {
        inner.open(0, "div")
        inner.reference(1, fn(handle: Reference) { seen.record("ref->{handle.node}") })
        inner.preserve(2)
        inner.text(3, "kept")
        inner.close()
    }
    render_body(b, body)
    io.println(b.dump())
    io.println("html: {html_of(b)}")
    io.println("sink saw: {seen.disposed}")
    r.eqi("the sink was called once", seen.disposed.len(), 1)
    r.eqi("neither handle writes html", html_of(b).len(), "<div>kept</div>".len())
    r.eq("the html", html_of(b), "<div>kept</div>")
    r.eqi("no faults", b.all_faults().len(), 0)

    // The same source position answers the same node id on the next pass — a
    // Reference whose node changed under a re-render would point at nothing.
    let first: string = seen.disposed[0]
    render_body(b, body)
    render_body(b, body)
    r.eqi("three passes, three sink calls", seen.disposed.len(), 3)
    r.eq("a reference keeps its node id across passes",
        seen.disposed[seen.disposed.len() - 1], first)

    // But a pass that does NOT reach the position drops it, and the position
    // is allocated fresh when it comes back. That is the same rule as a mount:
    // a slot dies with the pass that stopped naming it.
    render_body(b, fn(inner: Builder) { inner.text(0, "the ref is not rendered") })
    render_body(b, body)
    r.eqi("four sink calls", seen.disposed.len(), 4)
    r.no("a reference that left the tree does not come back with its old id",
        seen.disposed[3] == first)
}

// ------------------------------------------------- a component-tag ref

/// `Reference` carries a node id and nothing else. `ref` on a COMPONENT tag is
/// not an attribute-position call at all — every one of those needs
/// `in_attributes`, which only `open()` sets, and a component tag opens no
/// element — so it compiles to an assignment inside the setup closure instead.
/// This section is the core half of that: what the closure hands back, and for
/// how long it stays the same object.
fn component_ref(r: Report) {
    io.println("== 10 `ref` on a component tag")
    let panel: Panel = new Panel()
    panel.rows = 3
    let b: Builder = new Builder()
    b.render_root(panel)
    io.println(b.dump_tree())

    // 1 — the closure hands back the CONCRETE type, so a method on the child
    //     is callable with no downcast. That is the whole reason this beats a
    //     `Reference.child: Option<Component>`.
    var reloads: int = -1
    var stamp: int = -1
    match panel.grid {
        some(child) => { child.reload(); reloads = child.reloads; stamp = child.stamp }
        none => {}
    }
    r.eqi("the setup closure filled the handle", reloads, 1)
    r.eqi("and it is the first mounted instance", stamp, 1)

    // 2 — the call reached the mounted instance, not a copy: the next render
    //     prints it.
    b.render_root(panel)
    r.eq("a method call through the handle is visible in the child's frames",
        html_of(b), "<div><table>rows=3 reloads=1 stamp=1</table></div>")

    // 3 — the same instance comes back on every later pass. A handle that was
    //     re-filled with a fresh child would read stamp=2 here, and the whole
    //     point of keying the mount table by slot id would be gone.
    panel.rows = 7
    b.render_root(panel)
    var second: int = -1
    match panel.grid {
        some(child) => { second = child.stamp }
        none => {}
    }
    r.eqi("the handle still names the first instance", second, 1)
    r.eqi("nothing was re-activated", panel.stamps, 1)
    r.eq("and the parameter went through", html_of(b),
        "<div><table>rows=7 reloads=1 stamp=1</table></div>")

    // 4 — it is the very object the mount table holds, not a second one.
    var slots: List<int> = b.children.keys()
    slots.sort()
    r.eqi("one mounted child", slots.len(), 1)
    var same: bool = false
    match b.children.get(slots[0]) {
        some(stored) => {
            match stored.copy() as? Grid {
                some(mounted) => {
                    mounted.reload()
                    match panel.grid {
                        some(held) => { same = held.reloads == mounted.reloads }
                        none => {}
                    }
                }
                none => {}
            }
        }
        none => {}
    }
    r.yes("the handle and the mount table are one object", same)

    // 5 — the branch drops the child. The slot is swept and the component
    //     disposed, but the author's field is the author's: it still points at
    //     the instance that left the page until they clear it. Say so here
    //     rather than let a page author discover it.
    panel.mounted = false
    b.render_root(panel)
    r.eq("the child left the page", html_of(b), "<div>no grid</div>")
    r.eqi("and its slot went with it", b.children.keys().len(), 0)
    var stale: bool = false
    match panel.grid { some(_) => { stale = true } none => {} }
    r.yes("the author's field still holds the departed child", stale)

    // 6 — coming back is a NEW instance, which is what makes the stale field
    //     above worth knowing about.
    panel.mounted = true
    b.render_root(panel)
    var third: int = -1
    match panel.grid {
        some(child) => { third = child.stamp }
        none => {}
    }
    r.eqi("a remount is a fresh instance", third, 2)
    r.eqi("no faults anywhere", b.all_faults().len(), 0)
}


// ------------------------------------------------- the factory mount

/// A GENERIC component. Reflection cannot build one: `type_of(Cell<int>)`
/// answers `none` for `initializer()` on both backends (BLOCKERS.md B1), so
/// `component<Cell<int>>` faults and `component_made<Cell<int>>` is the whole
/// reason that call exists.
pub class Cell<T> extends Component {
    pub label: string = ""
    pub renders: int = 0
    pub inits: int = 0
    pub fn init() {}
    pub override fn on_init() { self.inits += 1 }
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "td")
        b.text(1, "{self.label}/{self.renders}")
        b.close()
    }
}

/// The control: the same call over a NON-generic component. Without it a green
/// run cannot tell "the factory route works" from "the factory route did
/// nothing and the assertions were about an empty page".
pub class Plain extends Component {
    pub label: string = ""
    pub renders: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "p")
        b.text(1, "{self.label}/{self.renders}")
        b.close()
    }
}

/// A second non-generic component, so "this slot holds the wrong class" has
/// two classes to be wrong between.
pub class Other extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "other") }
}

/// A page that mounts one child, by whichever route and class the case picks.
pub class Mounts extends Component {
    pub route: int = 0
    pub label: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        if self.route == 0 {
            b.component_made<Cell<int>>(0,
                fn() -> Cell<int> { return new Cell<int>() },
                fn(c: Cell<int>) { c.label = self.label })
        } else if self.route == 1 {
            b.component_made<Plain>(0,
                fn() -> Plain { return new Plain() },
                fn(c: Plain) { c.label = self.label })
        } else if self.route == 2 {
            b.component<Plain>(0, fn(c: Plain) { c.label = self.label })
        } else if self.route == 3 {
            b.component_made<Other>(0, fn() -> Other { return new Other() }, fn(c: Other) {})
        } else {
            b.component<Cell<int>>(0, fn(c: Cell<int>) { c.label = self.label })
        }
    }
}

fn factory_mount(r: Report) {
    io.println("== 11 the factory mount")

    // The subject: a closed generic, which is what reflection cannot build.
    let host: Mounts = new Mounts()
    host.label = "one"
    let b: Builder = new Builder()
    b.render_root(host)
    io.println("-- component_made<Cell<int>>")
    io.println(b.dump_tree())
    io.println("   html: {html_of(b)}")
    r.eq("a generic component mounts through a factory", html_of(b), "<td>one/1</td>")
    r.eqi("no faults", b.all_faults().len(), 0)
    r.eqi("one child buffer", b.nested.keys().len(), 1)

    // Two renders at one slot, because a mount that is never reused is the n=1
    // shape that proves nothing: the SAME instance has to come back.
    host.label = "two"
    b.render_root(host)
    r.eq("and the second render reuses it", html_of(b), "<td>two/2</td>")
    r.eqi("still one child", b.nested.keys().len(), 1)
    r.eqi("still no faults", b.all_faults().len(), 0)

    // The control. Same call, non-generic component.
    let plain_host: Mounts = new Mounts()
    plain_host.route = 1
    plain_host.label = "p"
    let pb: Builder = new Builder()
    pb.render_root(plain_host)
    pb.render_root(plain_host)
    r.eq("the same call mounts a non-generic component too", html_of(pb), "<p>p/2</p>")
    r.eqi("no faults", pb.all_faults().len(), 0)

    // The reflective route on the SAME generic type: this is the fault that
    // makes `component_made` necessary, and it reads the same on both backends
    // (B1 -- a closed generic has no initializer DESCRIPTOR, which is a
    // different thing from B7's descriptor that only fails when called).
    let reflective: Mounts = new Mounts()
    reflective.route = 4
    let rb: Builder = new Builder()
    rb.render_root(reflective)
    io.println("-- component<Cell<int>>, the reflective route")
    show_faults(rb)
    r.eqi("reflection cannot build a closed generic", rb.all_faults().len(), 1)
    r.yes("and says which type",
        first_fault(rb).contains("has no zero-argument initializer"))
    r.eq("so nothing renders", html_of(rb), "")

    // The factory route's own refusal, and it must be the same message the
    // reflective route gives, because `mount_made` is not allowed to invent a
    // second vocabulary for the same mistake.
    let bad: Builder = new Builder()
    render_body(bad, fn(inner: Builder) {
        inner.component_made<NotAComponent>(0,
            fn() -> NotAComponent { return new NotAComponent() },
            fn(x: NotAComponent) { x.value = 1 })
    })
    io.println("-- component_made<NotAComponent>")
    show_faults(bad)
    r.eqi("a factory that does not build a Component is refused",
        bad.all_faults().len(), 1)
    r.eq("with the same message the reflective route gives",
        first_fault(bad), "0: NotAComponent is not a Component")

    // The two routes share one slot table, so a slot filled by one is reused
    // by the other. If they did not, a markup compiler that switched routes
    // between two releases would silently re-activate every component on a page.
    let shared: Mounts = new Mounts()
    shared.route = 1
    shared.label = "s"
    let sb: Builder = new Builder()
    sb.render_root(shared)
    shared.route = 2                      // the reflective call, same seq
    sb.render_root(shared)
    r.eq("a slot mounted by the factory is reused by component<T>",
        html_of(sb), "<p>s/2</p>")
    r.eqi("and nothing was refused", sb.all_faults().len(), 0)

    // The wrong class at one slot -- through the FACTORY route, so the shared
    // tail is what raises it. This is the fault site the sweep can never reach,
    // because the sweep asserts there are none.
    let flip: Mounts = new Mounts()
    flip.route = 1
    flip.label = "f"
    let fb: Builder = new Builder()
    fb.render_root(flip)
    flip.route = 3                        // Other, at the same seq
    fb.render_root(flip)
    io.println("-- a slot asked for a different class")
    show_faults(fb)
    r.eqi("a slot that holds another class is refused", fb.all_faults().len(), 1)
    r.eq("and names both", first_fault(fb),
        "0: slot 1 holds a Plain, not a Other")
    // The control beside it: the SAME class at the same seq is not a fault.
    flip.route = 1
    fb.render_root(flip)
    r.eqi("the same class at the same seq is not", fb.all_faults().len(), 0)
    r.eq("and the original instance is still there", html_of(fb), "<p>f/3</p>")
}

// ------------------------------------------------- the dirty sink

/// A sink that records rather than renders. It is a subclass, which is the
/// reason `DirtySink` is a class and not an interface: a component holds one
/// `weak`, and a weak field's type must be `Option<C>` for a class `C`.
pub class Recorder extends DirtySink {
    pub marks: List<int> = []
    pub fn init() { super.init() }
    pub override fn mark(id: int) { self.marks.push(id) }
}

/// A child that hands its parent a `Callback` and fires it. The code the
/// callback runs is the PARENT's, so the component the renderer would mark on
/// its own -- the one that bound the DOM handler, which is this child -- is the
/// wrong one. That is the whole reason `Callback.call` notifies.
pub class Speaker extends Component {
    pub out: Option<Callback<string>> = none
    pub renders: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) { self.shout() })
        b.text(2, "speak")
        b.close()
    }
    pub fn shout() {
        match self.out {
            some(cb) => { cb.call("hello") }
            none => {}
        }
    }
}

pub class Listener extends Component {
    pub heard: string = ""
    pub renders: int = 0
    pub kid: Option<Speaker> = none
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "div")
        b.text(1, self.heard)
        b.component<Speaker>(2, fn(c: Speaker) {
            self.kid = some(c)
            c.out = some(new Callback<string>(self, fn(word: string) {
                self.heard = word
            }))
        })
        b.close()
    }
}

/// A page whose one row can be dropped, so a component can be disposed while
/// the test still holds it.
pub class Board extends Component {
    pub keep: bool = true
    pub held: Option<Row> = none
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "ul")
        if self.keep {
            b.component<Row>(1, fn(row: Row) {
                row.label = "kept"
                self.held = some(row)
            })
        }
        b.close()
    }
}

fn dirty_sink(r: Report) {
    io.println("== 12 the dirty sink")

    // Without a renderer there is no sink, and `notify()` is a no-op rather
    // than a crash. That is what a Builder driven by hand looks like -- every
    // other suite in this repo -- so it has to be the quiet case.
    let bare_host: Mounts = new Mounts()
    bare_host.route = 1
    let bare: Builder = new Builder()
    bare.render_root(bare_host)
    var mounted: List<int> = bare.nested.keys()
    r.eqi("a hand-driven Builder mounts a child", mounted.len(), 1)
    match bare.children.get(mounted[0]) {
        some(stored) => {
            match stored.copy() as? Component {
                some(child) => {
                    r.eqi("the child knows its slot id", child.id(), mounted[0])
                    child.notify()
                    r.yes("and notify() with no sink does nothing", true)
                }
                none => { r.yes("the child is a Component", false) }
            }
        }
        none => { r.yes("the child is there", false) }
    }

    // A component nothing has mounted must mark NOTHING. With an id defaulting
    // to 0 it would mark the page root instead and re-render the whole page,
    // which is the one wrong answer that looks like it works.
    let orphan: Row = new Row()
    let book: Recorder = new Recorder()
    orphan.mount.sink = some(book)
    r.eqi("an unmounted component has no id", orphan.id(), -1)
    orphan.notify()
    r.eqi("and marks nothing", book.marks.len(), 0)

    // With a renderer: every mounted component knows its own id, and notify()
    // reaches the renderer.
    let page: Listener = new Listener()
    let engine: Renderer = new Renderer()
    engine.mount(page)
    r.eqi("the page is component 0", page.id(), 0)
    r.eqi("no faults", engine.all_faults().len(), 0)
    var kid_id: int = -1
    match page.kid {
        some(kid) => { kid_id = kid.id() }
        none => {}
    }
    r.yes("the mounted child has an id of its own", kid_id > 0)
    r.eqi("the page rendered once", engine.render_count(0), 1)
    r.eqi("and the child once", engine.render_count(kid_id), 1)

    page.notify()
    r.yes("notify() marks the page", engine.is_dirty(0))
    // TWO, not one: rendering a parent runs `component<T>` for every child it
    // still has, and `Speaker` does not override `should_render`. The number
    // is the renderer's own count of buffers that ran, so it says what really
    // happened rather than what the dirty set asked for.
    r.eqi("the page and its child rendered", engine.flush(), 2)
    r.eqi("the page rendered twice", engine.render_count(0), 2)

    // The callback. The CHILD fires it; the PARENT is what has to be marked,
    // because the parent is whose state the handler changed.
    r.eqi("nothing is pending", engine.pending(), 0)
    match page.kid {
        some(kid) => { kid.shout() }
        none => {}
    }
    r.eq("the parent's state changed", page.heard, "hello")
    r.yes("and the PARENT is the one marked dirty", engine.is_dirty(0))
    r.no("not the child that fired it", engine.is_dirty(kid_id))
    let ran: int = engine.flush()
    r.eqi("the marked parent and its child rendered", ran, 2)
    r.eq("and the page says so", engine.html(),
        "<div>hello<button>speak</button></div>")
    r.eqi("no faults anywhere", engine.all_faults().len(), 0)

    // The dead owner. A disposed component that something still holds DOES
    // reach the live renderer through `notify()` -- that is not prevented, and
    // it does not need to be. `Renderer.mark` drops an id it no longer holds,
    // and ids are never reused, so the mark can never land on somebody else.
    let board: Board = new Board()
    let engine2: Renderer = new Renderer()
    engine2.mount(board)
    var row_id: int = -1
    match board.held {
        some(row) => { row_id = row.id() }
        none => {}
    }
    r.yes("the row mounted", row_id > 0)
    board.keep = false
    board.notify()
    let _: int = engine2.flush()
    r.no("the row is gone", engine2.mounted(row_id))
    r.eqi("nothing is pending", engine2.pending(), 0)

    // It is still ALIVE, because the test holds it. Now let it notify.
    match board.held {
        some(row) => {
            r.eqi("the disposed row still remembers its id", row.id(), row_id)
            row.notify()
        }
        none => { r.yes("the row is still held", false) }
    }
    r.eqi("a disposed component's notify() marks nothing", engine2.pending(), 0)
    r.no("and did not mark the page instead", engine2.is_dirty(0))

    // The second half of the same argument, and it is the half that would be
    // silent if it broke: the mark reaches the sink and is dropped THERE. A
    // Recorder says so where a Renderer cannot.
    let watcher: Recorder = new Recorder()
    match board.held {
        some(row) => {
            row.mount.sink = some(watcher)
            row.notify()
        }
        none => {}
    }
    r.eqi("the mark really was raised", watcher.marks.len(), 1)
    r.eqi("with the dead component's own id", watcher.marks[0], row_id)

    // ...which is safe only because ids are never reused. A row that comes
    // back gets a NEW id, so the stale mark above can never name it.
    board.keep = true
    board.notify()
    let _again: int = engine2.flush()
    var back_id: int = -1
    match board.held {
        some(row) => { back_id = row.id() }
        none => {}
    }
    r.yes("the row came back", back_id > 0)
    r.no("with an id that is not the dead one", back_id == row_id)
    r.eqi("no faults", engine2.all_faults().len(), 0)
}

// ------------------------------------------------- 13 every fault site
//
// One entry per `self.faults.push(...)` in `builder.b`, and there are 24 of
// them. Each entry is four facts and not one:
//
//   1. an input that trips THAT site, with the EXACT fault text and count —
//      not "a fault happened". A count and a message are what tell a coarser
//      refusal standing in front of a finer one from the finer one firing.
//   2. what the refusal left behind: the substituted tag, the inert URL, the
//      dropped slot. A refusal that reports and then writes the value anyway
//      is not a refusal.
//   3. the pass is still BALANCED. Every one of these runs through
//      `render_root`, so `settle` has closed whatever the case left open; a
//      refusal that leaves the frame list unbalanced hands the differ and the
//      applier a tree they have to guess at.
//   4. a POSITIVE CONTROL beside it — the nearest legal input, which must be
//      accepted and must render. Without one you cannot tell "refused for the
//      right reason" from "refused earlier, for a coarser one", and the
//      message in the golden is the only thing that would have told you.
//
// RULES.md, "The refusal that never runs": W2 found four bugs by exercising
// refusals that had been written and never run, and the worst of them was a
// live refusal no input could reach, because a broader rule upstream swallowed
// it first — `xlink:href`'s scheme check, listed as covered in two files and
// never once executed. The same shape was live in THIS file: `attrs`' copy of
// the URL-scheme check had never run, because § 6's splat case carried no URL
// name. It does now: `attrs-refused-scheme` below.
//
// The other half of the audit does not live in a suite and cannot: each of the
// 24 report sites was deleted, one at a time, and the case below that names it
// was watched to FAIL. A refusal whose deletion changes nothing is either
// untested or unreachable, and this file says which in the lane notes.
// `probes/refusal_deletions.sh` re-runs the whole pass.

/// One fault site, one trip, one control.
pub class Site {
    /// The report site, named by the method it lives in and its message. A
    /// name and not a line number, because a line number in a golden goes
    /// stale the first time anything above it moves.
    pub site: string = ""
    /// This case's own name — one site can be reached by several shapes.
    pub name: string = ""
    /// Input that must be refused.
    pub trip: fn(Builder) = fn(b: Builder) {}
    /// The exact faults it must raise, joined with " | ". Empty means none.
    pub want: string = ""
    /// The html the refusal leaves behind.
    pub left: string = ""
    /// The nearest legal input, which must be accepted.
    pub control: fn(Builder) = fn(b: Builder) {}
    /// What the control renders. An empty control proves nothing, so every one
    /// of these is non-empty and asserted.
    pub accepted: string = ""

    pub fn init(site: string, name: string, trip: fn(Builder), want: string,
                left: string, control: fn(Builder), accepted: string) {
        self.site = site
        self.name = name
        self.trip = trip
        self.want = want
        self.left = left
        self.control = control
        self.accepted = accepted
    }
}

fn joined(b: Builder) -> string {
    var out: string = ""
    var first: bool = true
    for fault: string in b.all_faults() {
        if !first { out = "{out} | " }
        out = "{out}{fault}"
        first = false
    }
    return out
}

const SITE_SIBLING: string = "note_sibling / sequence N does not follow M in this scope"
const SITE_OUTSIDE: string = "take_attribute_slot / X is outside an element's attribute run"
const SITE_ORDER: string = "take_attribute_slot / X does not follow Y in this element's attribute run"
const SITE_TAG: string = "open / refused tag name"
const SITE_CLOSE: string = "close / close with no open element"
const SITE_ATTR_URL: string = "attr / attribute N carried a refused scheme"
const SITE_ATTR_NAME: string = "name_is_writable / refused attribute name"
const SITE_ATTR_ON: string = "name_is_writable / refused inline handler attribute"
const SITE_SPLAT_NAME: string = "attrs / refused splatted attribute name"
const SITE_SPLAT_ON: string = "attrs / refused splatted inline handler"
const SITE_SPLAT_URL: string = "attrs / attribute N carried a refused scheme"
const SITE_WRONG_CLASS: string = "fill_slot / slot N holds a X, not a Y"
const SITE_NOT_COMPONENT: string = "mount / X is not a Component"
const SITE_ACTIVATE: string = "mount / cannot activate X"
const SITE_NO_CTOR: string = "mount / X has no zero-argument initializer"
const SITE_MADE_NOT_COMPONENT: string = "mount_made / X is not a Component"
const SITE_DUP_KEY: string = "region / duplicate key"
const SITE_END_REGION: string = "end_region / end_region with no open region"
const SITE_FAIL_BOUNDARY: string = "fail_boundary / fail_boundary with no open boundary"
const SITE_END_BOUNDARY: string = "end_boundary / end_boundary with no open boundary"
const SITE_OPEN_ELEMENT: string = "unwind_to / an element was left open"
const SITE_OPEN_REGION: string = "unwind_to / a region was left open"
const SITE_OPEN_FRAGMENT: string = "unwind_to / a fragment was left open"
const SITE_OPEN_BOUNDARY: string = "unwind_to / a boundary was left open"

/// Every report site in `builder.b` except the one that needs two render
/// passes; `wrong_class_at_one_slot` below carries that one.
fn sites() -> List<Site> {
    var out: List<Site> = []

    // -- note_sibling -----------------------------------------------------
    out.push(new Site(SITE_SIBLING, "sibling-seq-repeats",
        fn(b: Builder) {
            b.text(0, "one")
            b.text(0, "two")
        },
        "0: sequence 0 does not follow 0 in this scope", "onetwo",
        fn(b: Builder) {
            b.text(0, "one")
            b.text(1, "two")
        }, "onetwo"))

    out.push(new Site(SITE_SIBLING, "sibling-seq-goes-backwards",
        fn(b: Builder) {
            b.open(5, "p")
            b.close()
            b.open(2, "p")
            b.close()
        },
        "0: sequence 2 does not follow 5 in this scope", "<p></p><p></p>",
        fn(b: Builder) {
            b.open(2, "p")
            b.close()
            b.open(5, "p")
            b.close()
        }, "<p></p><p></p>"))

    // The exception the rule carries, and the reason it needs its own control:
    // a run of regions from one loop all share the loop's seq, and that is NOT
    // a violation. A test that only ever fed increasing numbers could not tell
    // this rule from "seq must always increase", which would refuse every
    // keyed list in the framework.
    out.push(new Site(SITE_SIBLING, "a-plain-sibling-reusing-the-loops-number",
        fn(b: Builder) {
            b.region(1, "a")
            b.text(0, "row")
            b.end_region()
            b.text(1, "tail")
        },
        "0: sequence 1 does not follow 1 in this scope", "rowtail",
        fn(b: Builder) {
            b.region(1, "a")
            b.text(0, "one")
            b.end_region()
            b.region(1, "b")
            b.text(0, "two")
            b.end_region()
            b.text(2, "tail")
        }, "onetwotail"))

    // -- take_attribute_slot, outside the run -----------------------------
    out.push(new Site(SITE_OUTSIDE, "attribute-after-content",
        fn(b: Builder) {
            b.open(0, "div")
            b.text(1, "content first")
            b.attr(2, "class", "too late")
            b.close()
        },
        "0: attribute 2:\"class\" is outside an element's attribute run",
        "<div>content first</div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "class", "in time")
            b.text(2, "content after")
            b.close()
        }, "<div class=\"in time\">content after</div>"))

    out.push(new Site(SITE_OUTSIDE, "attribute-with-no-element-at-all",
        fn(b: Builder) {
            b.attr(0, "class", "nowhere")
            b.text(1, "text")
        },
        "0: attribute 0:\"class\" is outside an element's attribute run", "text",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "class", "somewhere")
            b.close()
            b.text(2, "text")
        }, "<div class=\"somewhere\"></div>text"))

    out.push(new Site(SITE_OUTSIDE, "handler-after-the-element-closed",
        fn(b: Builder) {
            b.open(0, "div")
            b.close()
            b.on_click(1, fn(e: MouseEvent) {})
        },
        "0: on:click 1:\"\" is outside an element's attribute run", "<div></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.on_click(1, fn(e: MouseEvent) {})
            b.close()
        }, "<div></div>"))

    // -- take_attribute_slot, ordering ------------------------------------
    out.push(new Site(SITE_ORDER, "attribute-seq-goes-backwards",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(3, "a", "1")
            b.attr(1, "b", "2")
            b.close()
        },
        "0: attribute 1:\"b\" does not follow 3:\"a\" in this element's attribute run",
        "<div a=\"1\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "b", "2")
            b.attr(3, "a", "1")
            b.close()
        }, "<div b=\"2\" a=\"1\"></div>"))

    // The half of the rule only the differ needs: the merge key is the pair,
    // so within one seq the NAMES have to increase too. The control is the
    // same two names in the other order, which must be accepted — otherwise
    // the rule would be "one attribute per seq", which is not what it says.
    out.push(new Site(SITE_ORDER, "attribute-name-goes-backwards",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "z", "1")
            b.attr(1, "a", "2")
            b.close()
        },
        "0: attribute 1:\"a\" does not follow 1:\"z\" in this element's attribute run",
        "<div z=\"1\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "a", "2")
            b.attr(1, "z", "1")
            b.close()
        }, "<div a=\"2\" z=\"1\"></div>"))

    out.push(new Site(SITE_ORDER, "attribute-slot-repeats",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "same", "first")
            b.attr(1, "same", "second")
            b.close()
        },
        "0: attribute 1:\"same\" does not follow 1:\"same\" in this element's attribute run",
        "<div same=\"first\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "same", "first")
            b.attr(2, "same", "second")
            b.close()
        }, "<div same=\"second\"></div>"))

    out.push(new Site(SITE_ORDER, "two-handlers-at-one-seq",
        fn(b: Builder) {
            b.open(0, "div")
            b.on_click(1, fn(e: MouseEvent) {})
            b.on_dblclick(1, fn(e: MouseEvent) {})
            b.close()
        },
        "0: on:dblclick 1:\"\" does not follow 1:\"\" in this element's attribute run",
        "<div></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.on_click(1, fn(e: MouseEvent) {})
            b.attr(1, "class", "x")
            b.on_dblclick(2, fn(e: MouseEvent) {})
            b.close()
        }, "<div class=\"x\"></div>"))

    out.push(new Site(SITE_ORDER, "a-ref-and-a-preserve-at-one-seq",
        fn(b: Builder) {
            b.open(0, "div")
            b.reference(1, fn(h: Reference) {})
            b.preserve(1)
            b.close()
        },
        "0: preserve 1:\"\" does not follow 1:\"\" in this element's attribute run",
        "<div></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.reference(1, fn(h: Reference) {})
            b.preserve(2)
            b.close()
        }, "<div></div>"))

    out.push(new Site(SITE_ORDER, "splat-marker-under-an-earlier-name",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["a"] = "from splat"
            b.open(0, "div")
            b.attr(1, "z", "explicit")
            b.attrs(1, extra)
            b.close()
        },
        "0: attrs 1:\"\" does not follow 1:\"z\" in this element's attribute run",
        "<div z=\"explicit\"></div>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["a"] = "from splat"
            b.open(0, "div")
            b.attr(1, "z", "explicit")
            b.attrs(2, extra)
            b.close()
        }, "<div z=\"explicit\" a=\"from splat\"></div>"))

    // -- open -------------------------------------------------------------
    out.push(new Site(SITE_TAG, "unsafe-tag",
        fn(b: Builder) {
            b.open(0, "sc ript>")
            b.text(1, "inside")
            b.close()
        },
        "0: refused tag name \"sc ript>\"", "<span>inside</span>",
        fn(b: Builder) {
            b.open(0, "script")
            b.text(1, "let x = 1")
            b.close()
        }, "<script>let x = 1</script>"))

    out.push(new Site(SITE_TAG, "empty-tag",
        fn(b: Builder) {
            b.open(0, "")
            b.close()
        },
        "0: refused tag name \"\"", "<span></span>",
        fn(b: Builder) {
            b.open(0, "my-widget")
            b.text(1, "x")
            b.close()
        }, "<my-widget>x</my-widget>"))

    out.push(new Site(SITE_TAG, "digit-first-tag",
        fn(b: Builder) {
            b.open(0, "1bad")
            b.close()
        },
        "0: refused tag name \"1bad\"", "<span></span>",
        fn(b: Builder) {
            b.open(0, "h1")
            b.close()
        }, "<h1></h1>"))

    // -- close ------------------------------------------------------------
    out.push(new Site(SITE_CLOSE, "close-with-nothing-open",
        fn(b: Builder) {
            b.close()
            b.text(0, "after")
        },
        "0: close with no open element", "after",
        fn(b: Builder) {
            b.open(0, "div")
            b.close()
            b.text(1, "after")
        }, "<div></div>after"))

    // A `close` whose top scope is a REGION and not an element. The extra
    // fault is `settle` finding the region still open, which is the right
    // answer: refusing the close is what stopped the region from being
    // silently ended by the wrong call.
    out.push(new Site(SITE_CLOSE, "close-inside-a-region",
        fn(b: Builder) {
            b.region(0, "k")
            b.close()
        },
        "0: close with no open element | 0: a region was left open", "",
        fn(b: Builder) {
            b.region(0, "k")
            b.open(0, "li")
            b.close()
            b.end_region()
        }, "<li></li>"))

    // -- attr, the URL allowlist ------------------------------------------
    out.push(new Site(SITE_ATTR_URL, "url-scheme",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "javascript:alert(1)")
            b.close()
        },
        "0: attribute href carried a refused scheme", "<a href=\"about:blank\"></a>",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "https://example.com/a:b")
            b.close()
        }, "<a href=\"https://example.com/a:b\"></a>"))

    // A browser drops TAB, LF and CR from inside a URL, so this reaches the
    // scheme parser as `javascript:`. The control is a URL with a colon in its
    // PATH, which is not a scheme and must survive.
    out.push(new Site(SITE_ATTR_URL, "url-scheme-obfuscated",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "java\tscript:alert(1)")
            b.close()
        },
        "0: attribute href carried a refused scheme", "<a href=\"about:blank\"></a>",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "/local/path:with-colon")
            b.close()
        }, "<a href=\"/local/path:with-colon\"></a>"))

    // The name W2 found dead in their own lane: an SVG `<a xlink:href>` runs
    // script in every browser that renders SVG, and the check on it had never
    // executed once while two files documented it as covered. Its control is
    // an xlink:href that must be KEPT, so "refused because xlink:href is
    // rejected outright" cannot pass for "refused because of the scheme".
    out.push(new Site(SITE_ATTR_URL, "url-scheme-xlink",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "xlink:href", "javascript:alert(1)")
            b.close()
        },
        "0: attribute xlink:href carried a refused scheme",
        "<a xlink:href=\"about:blank\"></a>",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "xlink:href", "https://example.com/icon.svg#x")
            b.close()
        }, "<a xlink:href=\"https://example.com/icon.svg#x\"></a>"))

    out.push(new Site(SITE_ATTR_URL, "url-scheme-data-on-a-void-element",
        fn(b: Builder) {
            b.open(0, "img")
            b.attr(1, "src", "data:text/html,<script>alert(1)</script>")
            b.close()
        },
        "0: attribute src carried a refused scheme", "<img src=\"about:blank\">",
        fn(b: Builder) {
            b.open(0, "img")
            b.attr(1, "src", "https://example.com/a.png")
            b.close()
        }, "<img src=\"https://example.com/a.png\">"))

    // The other direction of the same rule: a value that LOOKS like a scheme
    // on an attribute that is not a URL must be left alone. `download` takes a
    // filename, and rewriting it to about:blank would be the allowlist
    // over-reaching into content it does not govern.
    out.push(new Site(SITE_ATTR_URL, "not-a-url-attribute",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "vbscript:msgbox(1)")
            b.attr(2, "download", "javascript:not-a-url")
            b.close()
        },
        "0: attribute href carried a refused scheme",
        "<a href=\"about:blank\" download=\"javascript:not-a-url\"></a>",
        fn(b: Builder) {
            b.open(0, "a")
            b.attr(1, "href", "mailto:x@example.com")
            b.attr(2, "download", "javascript:not-a-url")
            b.close()
        }, "<a href=\"mailto:x@example.com\" download=\"javascript:not-a-url\"></a>"))

    // -- name_is_writable, the name --------------------------------------
    out.push(new Site(SITE_ATTR_NAME, "unsafe-attribute-name",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "class\" onload=\"x", "y")
            b.attr(2, "ok", "kept")
            b.close()
        },
        "0: refused attribute name \"class\" onload=\"x\"", "<div ok=\"kept\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "data-x:y.z_w-1", "punctuation is fine")
            b.attr(2, "ok", "kept")
            b.close()
        }, "<div data-x:y.z_w-1=\"punctuation is fine\" ok=\"kept\"></div>"))

    out.push(new Site(SITE_ATTR_NAME, "empty-attribute-name",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "", "x")
            b.attr(2, "ok", "kept")
            b.close()
        },
        "0: refused attribute name \"\"", "<div ok=\"kept\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "_private", "x")
            b.attr(2, "ok", "kept")
            b.close()
        }, "<div _private=\"x\" ok=\"kept\"></div>"))

    // The `flag` route into the same check. Two callers reach
    // `name_is_writable`, and a case that only used `attr` would leave the
    // other one covered by nothing.
    out.push(new Site(SITE_ATTR_NAME, "unsafe-flag-name",
        fn(b: Builder) {
            b.open(0, "div")
            b.flag(1, "a>b", true)
            b.flag(2, "hidden", true)
            b.close()
        },
        "0: refused attribute name \"a>b\"", "<div hidden=\"\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.flag(1, "a-b", true)
            b.flag(2, "hidden", true)
            b.close()
        }, "<div a-b=\"\" hidden=\"\"></div>"))

    // -- name_is_writable, the on* rule -----------------------------------
    //
    // Its control is the length edge: the rule is `len >= 3 && starts_with
    // "on"`, so an attribute literally named `on` is not an inline handler and
    // must be written. Without that control, a rule that refused every name
    // beginning "on" — or every name at all — would pass this case.
    out.push(new Site(SITE_ATTR_ON, "inline-handler-attribute",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "onclick", "steal()")
            b.attr(2, "ok", "kept")
            b.close()
        },
        "0: refused inline handler attribute \"onclick\"", "<div ok=\"kept\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "on", "two bytes, not a handler")
            b.attr(2, "data-onclick", "does not start with on")
            b.close()
        }, "<div on=\"two bytes, not a handler\" data-onclick=\"does not start with on\"></div>"))

    out.push(new Site(SITE_ATTR_ON, "inline-handler-in-capitals",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "ONCLICK", "steal()")
            b.close()
        },
        "0: refused inline handler attribute \"ONCLICK\"", "<div></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.attr(1, "ON", "still two bytes")
            b.close()
        }, "<div ON=\"still two bytes\"></div>"))

    out.push(new Site(SITE_ATTR_ON, "inline-handler-as-a-flag",
        fn(b: Builder) {
            b.open(0, "div")
            b.flag(1, "onerror", true)
            b.flag(2, "hidden", true)
            b.close()
        },
        "0: refused inline handler attribute \"onerror\"", "<div hidden=\"\"></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.flag(1, "on", true)
            b.flag(2, "hidden", true)
            b.close()
        }, "<div on=\"\" hidden=\"\"></div>"))

    // -- attrs, the splat -------------------------------------------------
    out.push(new Site(SITE_SPLAT_NAME, "splatted-unsafe-name",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["bad name"] = "x"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        },
        "0: refused splatted attribute name \"bad name\"", "<div fine=\"kept\"></div>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["data-bad-name"] = "x"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        }, "<div data-bad-name=\"x\" fine=\"kept\"></div>"))

    out.push(new Site(SITE_SPLAT_NAME, "splatted-empty-name",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra[""] = "x"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        },
        "0: refused splatted attribute name \"\"", "<div fine=\"kept\"></div>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["_"] = "x"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        }, "<div _=\"x\" fine=\"kept\"></div>"))

    out.push(new Site(SITE_SPLAT_ON, "splatted-inline-handler",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["onmouseover"] = "steal()"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        },
        "0: refused splatted inline handler \"onmouseover\"", "<div fine=\"kept\"></div>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["on"] = "two bytes"
            extra["fine"] = "kept"
            b.open(0, "div")
            b.attrs(1, extra)
            b.close()
        }, "<div fine=\"kept\" on=\"two bytes\"></div>"))

    // -- attrs, the URL allowlist -----------------------------------------
    //
    // THE ONE THAT HAD NEVER RUN. It is a second copy of `attr`'s scheme
    // check, on the path a splatted map takes, and § 6's splat case carried no
    // URL name — so a `javascript:` value arriving through `attrs={...}`
    // exercised nothing at all, in a control that is the difference between a
    // link and an XSS. Nothing swallows it: `href` is a safe name, it is not
    // an `on*` name, and it takes its slot; the check was simply never fed.
    out.push(new Site(SITE_SPLAT_URL, "splatted-refused-scheme",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["href"] = "javascript:alert(1)"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        },
        "0: attribute href carried a refused scheme", "<a href=\"about:blank\"></a>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["href"] = "https://example.com/x"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        }, "<a href=\"https://example.com/x\"></a>"))

    out.push(new Site(SITE_SPLAT_URL, "splatted-refused-scheme-xlink",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["xlink:href"] = "java\tscript:alert(1)"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        },
        "0: attribute xlink:href carried a refused scheme",
        "<a xlink:href=\"about:blank\"></a>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["xlink:href"] = "#gradient"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        }, "<a xlink:href=\"#gradient\"></a>"))

    // Two refused names in one splat, so the loop is proven to keep going
    // rather than stopping at the first. Sorted, so href comes before poster.
    out.push(new Site(SITE_SPLAT_URL, "two-refused-schemes-in-one-splat",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["href"] = "javascript:alert(1)"
            extra["poster"] = "data:text/html,x"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        },
        "0: attribute href carried a refused scheme | 0: attribute poster carried a refused scheme",
        "<a href=\"about:blank\" poster=\"about:blank\"></a>",
        fn(b: Builder) {
            var extra: Map<string, string> = {}
            extra["href"] = "https://example.com/v"
            extra["poster"] = "https://example.com/p.png"
            b.open(0, "a")
            b.attrs(1, extra)
            b.close()
        }, "<a href=\"https://example.com/v\" poster=\"https://example.com/p.png\"></a>"))

    // -- mounting ---------------------------------------------------------
    out.push(new Site(SITE_NOT_COMPONENT, "mount-a-non-component",
        fn(b: Builder) {
            b.component<NotAComponent>(0, fn(x: NotAComponent) { x.value = 1 })
        },
        "0: NotAComponent is not a Component", "",
        fn(b: Builder) {
            b.component<Plain>(0, fn(c: Plain) { c.label = "ok" })
        }, "<p>ok/1</p>"))

    // Reflection CAN find an initializer here and cannot call it. Two shapes
    // reach it and they are different reflect failures, so both are named.
    out.push(new Site(SITE_ACTIVATE, "mount-a-component-whose-init-takes-an-argument",
        fn(b: Builder) {
            b.component<NeedsSeed>(0, fn(c: NeedsSeed) {})
        },
        "0: cannot activate NeedsSeed: wrong reflected argument count", "",
        fn(b: Builder) {
            b.component<Plain>(0, fn(c: Plain) { c.label = "ok" })
        }, "<p>ok/1</p>"))

    out.push(new Site(SITE_ACTIVATE, "mount-a-component-whose-init-is-not-public",
        fn(b: Builder) {
            b.component<HiddenInit>(0, fn(c: HiddenInit) {})
        },
        "0: cannot activate HiddenInit: reflected member is not public", "",
        fn(b: Builder) {
            b.component<Plain>(0, fn(c: Plain) { c.label = "ok" })
        }, "<p>ok/1</p>"))

    // A closed generic has no initializer DESCRIPTOR at all (BLOCKERS.md B1),
    // which is the whole reason `component_made` exists — and that is its
    // control: the same type, mounted by the route that works.
    out.push(new Site(SITE_NO_CTOR, "mount-a-closed-generic-reflectively",
        fn(b: Builder) {
            b.component<Cell<int>>(0, fn(c: Cell<int>) { c.label = "g" })
        },
        "0: Cell has no zero-argument initializer", "",
        fn(b: Builder) {
            b.component_made<Cell<int>>(0,
                fn() -> Cell<int> { return new Cell<int>() },
                fn(c: Cell<int>) { c.label = "g" })
        }, "<td>g/1</td>"))

    out.push(new Site(SITE_MADE_NOT_COMPONENT, "a-factory-that-does-not-build-a-component",
        fn(b: Builder) {
            b.component_made<NotAComponent>(0,
                fn() -> NotAComponent { return new NotAComponent() },
                fn(x: NotAComponent) { x.value = 1 })
        },
        "0: NotAComponent is not a Component", "",
        fn(b: Builder) {
            b.component_made<Plain>(0,
                fn() -> Plain { return new Plain() },
                fn(c: Plain) { c.label = "ok" })
        }, "<p>ok/1</p>"))

    // -- region -----------------------------------------------------------
    //
    // Three rows with one key: the second and third are both refused, and each
    // keeps a distinct key so the differ still has something well-defined to
    // match on. Its control is three DISTINCT keys at the same seq — which is
    // an ordinary keyed loop and must be silent.
    out.push(new Site(SITE_DUP_KEY, "duplicate-key",
        fn(b: Builder) {
            b.open(0, "ul")
            b.region(1, "same")
            b.text(0, "first")
            b.end_region()
            b.region(1, "same")
            b.text(0, "second")
            b.end_region()
            b.region(1, "same")
            b.text(0, "third")
            b.end_region()
            b.close()
        },
        "0: duplicate key \"same\" in the loop at 1 | 0: duplicate key \"same\" in the loop at 1",
        "<ul>firstsecondthird</ul>",
        fn(b: Builder) {
            b.open(0, "ul")
            b.region(1, "a")
            b.text(0, "first")
            b.end_region()
            b.region(1, "b")
            b.text(0, "second")
            b.end_region()
            b.region(1, "c")
            b.text(0, "third")
            b.end_region()
            b.close()
        }, "<ul>firstsecondthird</ul>"))

    // The key table is per RUN, not per pass: a key used by the loop at seq 1
    // may be used again by the loop at seq 2. Two loops with the same key must
    // be silent, or every page with two lists over the same ids would fault.
    out.push(new Site(SITE_DUP_KEY, "a-key-repeating-inside-one-loop-only",
        fn(b: Builder) {
            b.region(1, "k")
            b.text(0, "one")
            b.end_region()
            b.region(1, "k")
            b.text(0, "two")
            b.end_region()
            b.region(2, "k")
            b.text(0, "three")
            b.end_region()
        },
        "0: duplicate key \"k\" in the loop at 1", "onetwothree",
        fn(b: Builder) {
            b.region(1, "k")
            b.text(0, "one")
            b.end_region()
            b.region(2, "k")
            b.text(0, "two")
            b.end_region()
        }, "onetwo"))

    // -- end_region -------------------------------------------------------
    out.push(new Site(SITE_END_REGION, "end-region-with-nothing-open",
        fn(b: Builder) {
            b.end_region()
            b.text(0, "after")
        },
        "0: end_region with no open region", "after",
        fn(b: Builder) {
            b.region(0, "k")
            b.text(0, "row")
            b.end_region()
            b.text(1, "after")
        }, "rowafter"))

    out.push(new Site(SITE_END_REGION, "end-region-with-an-element-on-top",
        fn(b: Builder) {
            b.open(0, "div")
            b.end_region()
            b.close()
        },
        "0: end_region with no open region", "<div></div>",
        fn(b: Builder) {
            b.region(0, "k")
            b.open(0, "div")
            b.close()
            b.end_region()
        }, "<div></div>"))

    // -- fail_boundary ----------------------------------------------------
    out.push(new Site(SITE_FAIL_BOUNDARY, "fail-boundary-with-nothing-open",
        fn(b: Builder) {
            b.fail_boundary("nothing to fail")
            b.text(0, "after")
        },
        "0: fail_boundary with no open boundary", "after",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.fail_boundary("boom")
            b.text(0, "fallback")
            b.end_boundary()
        }, "fallback"))

    out.push(new Site(SITE_FAIL_BOUNDARY, "fail-boundary-after-the-boundary-closed",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.end_boundary()
            b.fail_boundary("too late")
        },
        "0: fail_boundary with no open boundary", "body",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.fail_boundary("in time")
            b.text(0, "fallback")
            b.end_boundary()
        }, "fallback"))

    // -- end_boundary -----------------------------------------------------
    out.push(new Site(SITE_END_BOUNDARY, "end-boundary-with-nothing-open",
        fn(b: Builder) {
            b.end_boundary()
            b.text(0, "after")
        },
        "0: end_boundary with no open boundary", "after",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.end_boundary()
            b.text(1, "after")
        }, "bodyafter"))

    out.push(new Site(SITE_END_BOUNDARY, "end-boundary-twice",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.end_boundary()
            b.end_boundary()
        },
        "0: end_boundary with no open boundary", "body",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "outer")
            b.boundary(1)
            b.text(0, "inner")
            b.end_boundary()
            b.end_boundary()
        }, "outerinner"))

    // -- unwind_to --------------------------------------------------------
    out.push(new Site(SITE_OPEN_ELEMENT, "element-left-open-at-pass-end",
        fn(b: Builder) {
            b.open(0, "div")
            b.text(1, "no close")
        },
        "0: an element was left open", "<div>no close</div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.text(1, "closed")
            b.close()
        }, "<div>closed</div>"))

    // Two of them, because one proves the report fires and two prove the
    // unwind is a LOOP and not a single step.
    out.push(new Site(SITE_OPEN_ELEMENT, "two-elements-left-open",
        fn(b: Builder) {
            b.open(0, "div")
            b.open(1, "p")
            b.text(2, "neither is closed")
        },
        "0: an element was left open | 0: an element was left open",
        "<div><p>neither is closed</p></div>",
        fn(b: Builder) {
            b.open(0, "div")
            b.open(1, "p")
            b.text(2, "both are closed")
            b.close()
            b.close()
        }, "<div><p>both are closed</p></div>"))

    // The other caller of `unwind_to`: a fragment body that leaves an element
    // open is closed at the fragment's edge, so the text after the fragment is
    // a sibling and not a child.
    out.push(new Site(SITE_OPEN_ELEMENT, "element-left-open-inside-a-fragment",
        fn(b: Builder) {
            b.fragment(0, fn(f: Builder) {
                f.open(0, "div")
                f.text(1, "inside")
            })
            b.text(1, "after")
        },
        "0: an element was left open", "<div>inside</div>after",
        fn(b: Builder) {
            b.fragment(0, fn(f: Builder) {
                f.open(0, "div")
                f.text(1, "inside")
                f.close()
            })
            b.text(1, "after")
        }, "<div>inside</div>after"))

    out.push(new Site(SITE_OPEN_REGION, "region-left-open-at-pass-end",
        fn(b: Builder) {
            b.region(0, "k")
            b.text(0, "row")
        },
        "0: a region was left open", "row",
        fn(b: Builder) {
            b.region(0, "k")
            b.text(0, "row")
            b.end_region()
        }, "row"))

    // A region and an element, unwound in the order they were opened, so the
    // frames still nest.
    out.push(new Site(SITE_OPEN_REGION, "region-left-open-inside-an-element",
        fn(b: Builder) {
            b.open(0, "ul")
            b.region(1, "r")
            b.text(0, "row")
        },
        "0: a region was left open | 0: an element was left open", "<ul>row</ul>",
        fn(b: Builder) {
            b.open(0, "ul")
            b.region(1, "r")
            b.text(0, "row")
            b.end_region()
            b.close()
        }, "<ul>row</ul>"))

    // The ONLY route to this site, and it took a probe to find: a fragment's
    // own scope can be closed out from under it by `end_boundary()` called
    // from inside the body, because `end_boundary` unwinds every scope above
    // the boundary's. `fragment` itself never sees its own scope in
    // `unwind_to(mark + 1)`, and `settle`'s `unwind_to(1)` cannot either,
    // because `fragment` always leaves its scope before returning. The control
    // is the same fragment closing normally, with a sibling after it — which
    // is exactly what the trip lost before `fragment` learned not to close a
    // scope it no longer owns.
    out.push(new Site(SITE_OPEN_FRAGMENT, "fragment-unwound-by-an-inner-end-boundary",
        fn(b: Builder) {
            b.boundary(0)
            b.fragment(1, fn(f: Builder) {
                f.text(0, "in the fragment")
                f.end_boundary()
            })
            b.text(2, "after")
        },
        "0: a fragment was left open", "in the fragmentafter",
        fn(b: Builder) {
            b.boundary(0)
            b.fragment(1, fn(f: Builder) {
                f.text(0, "in the fragment")
            })
            b.end_boundary()
            b.text(2, "after")
        }, "in the fragmentafter"))

    out.push(new Site(SITE_OPEN_FRAGMENT, "an-element-open-when-the-fragment-is-unwound",
        fn(b: Builder) {
            b.boundary(0)
            b.fragment(1, fn(f: Builder) {
                f.open(0, "div")
                f.end_boundary()
            })
            b.text(2, "after")
        },
        "0: an element was left open | 0: a fragment was left open",
        "<div></div>after",
        fn(b: Builder) {
            b.boundary(0)
            b.fragment(1, fn(f: Builder) {
                f.open(0, "div")
                f.close()
            })
            b.end_boundary()
            b.text(2, "after")
        }, "<div></div>after"))

    out.push(new Site(SITE_OPEN_BOUNDARY, "boundary-left-open-at-pass-end",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
        },
        "0: a boundary was left open", "body",
        fn(b: Builder) {
            b.boundary(0)
            b.text(0, "body")
            b.end_boundary()
        }, "body"))

    out.push(new Site(SITE_OPEN_BOUNDARY, "two-boundaries-left-open",
        fn(b: Builder) {
            b.boundary(0)
            b.boundary(0)
            b.text(0, "body")
        },
        "0: a boundary was left open | 0: a boundary was left open", "body",
        fn(b: Builder) {
            b.boundary(0)
            b.boundary(0)
            b.text(0, "body")
            b.end_boundary()
            b.end_boundary()
        }, "body"))

    return move out
}

fn fault_sites(r: Report) {
    io.println("== 13 every fault site in builder.b")
    var reached: Map<string, int> = {}
    for probe: Site in sites() {
        let b: Builder = new Builder()
        render_body(b, probe.trip)
        let control: Builder = new Builder()
        render_body(control, probe.control)

        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {joined(b)}")
        io.println("   left:    {html_of(b)}")
        io.println("   control: {html_of(control)}")

        r.eq("{probe.name}: the exact faults", joined(b), probe.want)
        r.eq("{probe.name}: what the refusal left", html_of(b), probe.left)
        r.yes("{probe.name}: the pass is still balanced", b.balanced())
        r.eq("{probe.name}: the control raises nothing", joined(control), "")
        r.eq("{probe.name}: and the control renders", html_of(control), probe.accepted)

        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    wrong_class_at_one_slot(r)
    reached[SITE_WRONG_CLASS] = 1

    // The accounting. A site nothing below trips is a refusal with no test,
    // and the only way to see that is to count the sites rather than the
    // cases. 24 is every `self.faults.push` in builder.b; `grep -c` says so.
    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in builder.b has a case", names.len(), 24)
}

/// `fill_slot / slot N holds a X, not a Y` — the one site that needs two
/// render passes, so it cannot be a `Site` with one `fn(Builder)` body.
///
/// Its control is the strongest one in this file: the SAME class at the same
/// seq must be silent AND must keep the instance, because a rule that refused
/// on every re-render would look identical here and would tear down every
/// component on the page once a pass.
fn wrong_class_at_one_slot(r: Report) {
    let host: Mounts = new Mounts()
    host.route = 2                          // component<Plain>
    host.label = "one"
    let b: Builder = new Builder()
    b.render_root(host)
    io.println("-- a-slot-that-holds-another-class")
    io.println("   site:    {SITE_WRONG_CLASS}")
    r.eq("a-slot-that-holds-another-class: the first pass is clean", joined(b), "")
    r.eq("a-slot-that-holds-another-class: and it rendered", html_of(b), "<p>one/1</p>")

    host.route = 3                          // component_made<Other>, same seq
    b.render_root(host)
    io.println("   faults:  {joined(b)}")
    io.println("   left:    {html_of(b)}")
    r.eq("a-slot-that-holds-another-class: the exact fault", joined(b),
        "0: slot 1 holds a Plain, not a Other")
    r.yes("a-slot-that-holds-another-class: the pass is still balanced", b.balanced())

    host.route = 2                          // the same class again
    b.render_root(host)
    io.println("   control: {html_of(b)}")
    r.eq("a-slot-that-holds-another-class: the same class at the same seq raises nothing", joined(b), "")
    r.eq("a-slot-that-holds-another-class: and the instance survived all three passes",
        html_of(b), "<p>one/3</p>")
}

// ---------------------------------------------------------------- main

fn main() {
    let r: Report = new Report()
    let t: Table = new Table()
    t.rows = ["a", "b", "c", "d", "e"]
    let b: Builder = new Builder()

    five_rows(r, b, t)
    reorder(r, b, t)
    dispatch(r, b, t)
    sweep(r, b, t)
    lifecycle(r)
    run_refusals(r)
    unbalanced(r)
    boundaries(r)
    handles(r)
    component_ref(r)
    factory_mount(r)
    dirty_sink(r)
    fault_sites(r)

    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
