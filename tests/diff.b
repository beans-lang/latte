// Edits for old and new pairs, including keyed reorders of at least five
// items, nested component swaps and branch flips. Every step also applies its
// own batch and asserts the applier landed on the serializer's HTML of the
// new tree.
//
// Two things this suite is built to refuse to let slide:
//
//   * **Edit COUNTS are asserted, not just outcomes.** "One insert for one
//     appended row" is the headline claim of the whole update model, and a
//     differ that rebuilds the list every time still lands on the right HTML.
//     Every named case pins its number.
//   * **Five rows, and 120 permutations of them.** A single swap proves
//     nothing about a keyed pass — this workspace has shipped a bug behind a
//     test that passed only because n=1.
package main

import std.io
import {Applier, Batch, Builder, Component, Differ, InputEvent, MouseEvent,
        Serializer} from latte

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

pub class Row extends Component {
    pub label: string = ""
    pub inits: int = 0
    pub renders: int = 0
    pub quiet: bool = false
    pub fn init() {}
    pub override fn on_init() { self.inits += 1 }
    pub override fn should_render() -> bool { return !self.quiet }
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "span")
        b.attr(1, "class", "row")
        b.text(2, self.label)
        b.close()
    }
}

pub class Alpha extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "em")
        b.text(1, "alpha")
        b.close()
    }
}

pub class Beta extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "strong")
        b.text(1, "beta")
        b.close()
    }
}

/// One component with every shape the differ has a rule for, reachable by
/// flipping a field. Sequence numbers are laid out so the two arms of each
/// branch get disjoint ranges, which is the property the whole merge rests on.
pub class Page extends Component {
    pub rows: List<string> = []
    pub title: string = "title"
    pub note: string = "note"
    pub markup: string = "<b>m</b>"
    pub tail: string = "one"
    pub extra: Map<string, string> = {}
    pub show_list: bool = true
    pub flag_on: bool = true
    pub with_handler: bool = true
    pub which: int = 0
    pub preserved: bool = false
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "root")
        b.attr(2, "data-title", self.title)
        b.flag(3, "hidden", self.flag_on)
        b.attrs(4, self.extra)
        if self.with_handler { b.on_click(5, fn(e: MouseEvent) {}) }
        b.text(6, self.title)
        b.raw(7, self.markup)
        if self.show_list {
            b.open(8, "ul")
            for id: string in self.rows {
                b.region(0, id)
                b.open(0, "li")
                b.attr(1, "data-key", id)
                b.on_click(2, fn(e: MouseEvent) {})
                b.component<Row>(3, fn(r: Row) { r.label = id })
                b.close()
                b.end_region()
            }
            b.close()
        } else {
            b.text(20, self.note)
        }
        if self.which == 1 { b.component<Alpha>(30, fn(x: Alpha) {}) }
        else if self.which == 2 { b.component<Beta>(31, fn(x: Beta) {}) }
        b.open(40, "section")
        if self.preserved { b.preserve(41) }
        b.text(42, self.tail)
        b.close()
        b.close()
    }
}

// ---------------------------------------------------------------- harness

pub class Harness {
    pub page: Page = new Page()
    pub builder: Builder = new Builder()
    pub applier: Applier = new Applier()
    pub differ: Differ = new Differ()
    pub report: Report = new Report()
    pub steps: int = 0
    pub total_edits: int = 0
    pub diverged: int = 0
    /// The last batch, so a case can look at it after the fact.
    pub last: Batch = new Batch()
    pub fn init(report: Report) { self.report = report }

    /// Render, diff, apply, and check the two halves of the invariant: the
    /// applier landed on the serializer's HTML of the new tree, and neither
    /// side complained. `expect` is the edit count; -1 means "do not pin it".
    /// `agree` is false only for `preserve`, which is a divergence by design.
    pub fn step(name: string, expect: int, agree: bool) {
        self.builder.render_root(self.page)
        let batch: Batch = self.differ.batch(self.builder)
        self.last = batch
        self.applier.apply(batch)
        self.steps += 1
        self.total_edits += batch.edit_count()

        let writer: Serializer = new Serializer()
        let want: string = writer.page(self.builder)
        let got: string = self.applier.html()

        io.println("-- {name}  ({batch.edit_count()} edit(s))")
        io.print(batch.dump())
        io.println("   html: {want}")
        if expect >= 0 { self.report.eqi("{name}: edit count", batch.edit_count(), expect) }
        if agree {
            self.report.eq("{name}: applier == serializer", got, want)
        } else {
            self.diverged += 1
            self.report.no("{name}: applier deliberately differs", got == want)
            io.println("   applier: {got}")
        }
        self.report.eqi("{name}: differ faults", self.differ.faults.len(), 0)
        self.report.eqi("{name}: applier faults", self.applier.faults.len(), 0)
        self.report.eqi("{name}: builder faults", self.builder.all_faults().len(), 0)
        for fault: string in self.differ.faults { io.println("   differ: {fault}") }
        for fault: string in self.applier.faults { io.println("   applier: {fault}") }
        for fault: string in self.builder.all_faults() { io.println("   builder: {fault}") }
        self.applier.faults.clear()
    }

    /// The same cycle with no printing, for the sweeps. Answers whether the
    /// applier agreed, and how many edits it took.
    pub fn quiet_step() -> int {
        self.builder.render_root(self.page)
        let batch: Batch = self.differ.batch(self.builder)
        self.applier.apply(batch)
        self.steps += 1
        self.total_edits += batch.edit_count()
        let writer: Serializer = new Serializer()
        if writer.page(self.builder) != self.applier.html() { return -1 }
        if self.differ.faults.len() > 0 { return -2 }
        if self.applier.faults.len() > 0 { return -3 }
        if self.builder.all_faults().len() > 0 { return -4 }
        return batch.edit_count()
    }
}

fn labels(order: List<int>, names: List<string>) -> List<string> {
    var out: List<string> = []
    for index: int in order { out.push(names[index]) }
    return move out
}

/// Lexicographic next permutation, so the sweep is every arrangement in a
/// fixed order and the golden is stable.
fn next_permutation(order: List<int>) -> bool {
    var i: int = order.len() - 2
    for i >= 0 {
        if order[i] < order[i + 1] { break }
        i -= 1
    }
    if i < 0 { return false }
    var j: int = order.len() - 1
    for order[j] <= order[i] { j -= 1 }
    let swap: int = order[i]
    order[i] = order[j]
    order[j] = swap
    var lo: int = i + 1
    var hi: int = order.len() - 1
    for lo < hi {
        let held: int = order[lo]
        order[lo] = order[hi]
        order[hi] = held
        lo += 1
        hi -= 1
    }
    return true
}

fn set_rows(page: Page, values: List<string>) {
    page.rows.clear()
    for value: string in values { page.rows.push(value) }
}

// ---------------------------------------------------------------- sections

fn basics(h: Harness, r: Report) {
    io.println("== 1 the first render, and no render at all")
    set_rows(h.page, ["a", "b", "c", "d", "e"])
    // The first render is a diff against an empty old side: one insert for the
    // root element plus one per mounted child's own build. That is the same
    // code path an insert takes later, which is the point of the reference
    // pool.
    h.step("first render", 6, true)
    h.step("nothing changed", 0, true)
    r.eqi("an unchanged pass produces an empty batch", h.last.updates.len(), 0)
    r.eqi("and stages nothing", h.last.reference.len(), 0)
}

fn scalars(h: Harness, r: Report) {
    io.println("== 2 text, markup, attributes, flags, splats, handlers")

    h.page.title = "second"
    // One attribute and one text node, inside one step_in/step_out pair.
    h.step("a changed field touches its attribute and its text", 4, true)

    h.page.markup = "<i>changed</i>"
    h.step("raw markup", 3, true)

    h.page.flag_on = false
    // An absent flag is a TOMBSTONE, not a removal: it shadows an earlier slot
    // of the same name, so the edit has to be able to say "absent" rather than
    // "gone".
    h.step("a flag turns off", 3, true)
    h.page.flag_on = true
    h.step("and back on", 3, true)

    h.page.extra["data-z"] = "z"
    h.page.extra["aria-live"] = "polite"
    h.step("a splat gains two names", 4, true)
    let _: bool = h.page.extra.remove("data-z")
    h.step("and loses one", 3, true)
    h.page.extra["aria-live"] = "assertive"
    h.step("and changes one", 3, true)

    h.page.with_handler = false
    h.step("a handler goes away", 3, true)
    h.page.with_handler = true
    // Coming back is a NEW id: the slot was swept when the pass stopped naming
    // it, so a client holding the old id finds nothing, which is the point.
    h.step("and comes back with a fresh id", 3, true)
}

fn keyed(h: Harness, r: Report) {
    io.println("== 3 keyed rows — the shapes people hit")

    set_rows(h.page, ["a", "b", "c", "d", "e", "f"])
    h.step("append one row", 6, true)

    set_rows(h.page, ["z", "a", "b", "c", "d", "e", "f"])
    h.step("prepend one row", 6, true)

    set_rows(h.page, ["z", "a", "b", "d", "e", "f"])
    // Four frames of cursor overhead — `in 0` into the div, `in 2` into the
    // <ul>, and the two `out`s — plus the one edit that did the work. Every
    // count in this section is that four plus its own edits.
    h.step("remove from the middle", 5, true)

    set_rows(h.page, ["a", "b", "d", "e", "f", "z"])
    // Rotate LEFT costs n-1 moves under the selection pass, because the row
    // that has to travel to the end is passed over by every step before it.
    h.step("rotate left", 9, true)

    set_rows(h.page, ["z", "a", "b", "d", "e", "f"])
    // Rotate RIGHT costs one, because the row that has to travel to the front
    // is found by the first step. The asymmetry is real and is the price of
    // not running a longest-increasing-subsequence pass; it is pinned here
    // rather than described, so landing LIS later shows up as these numbers
    // changing.
    h.step("rotate right", 5, true)

    set_rows(h.page, ["f", "e", "d", "b", "a", "z"])
    // Reversal is the case where the selection pass is already optimal: the
    // longest increasing subsequence of a reversal is one row, so n-1 moves
    // is the floor and LIS would not beat it.
    h.step("reverse", 9, true)

    set_rows(h.page, ["f", "z"])
    h.step("drop four", 8, true)

    set_rows(h.page, [])
    h.step("empty the list", 6, true)
    r.eqi("emptying disposed both rows", h.last.disposed.len(), 2)

    set_rows(h.page, ["p", "q", "r", "s", "t"])
    // Five inserts for five new rows, plus each new child's own first build.
    // One insert per row is the claim; anything that rebuilt the <ul> would
    // read 4 + 1 here and still print the right html.
    h.step("refill with five new rows", 14, true)
}

fn permutations(r: Report) {
    io.println("== 4 every permutation of five keyed rows")
    let local: Report = new Report()
    let h: Harness = new Harness(local)
    let names: List<string> = ["a", "b", "c", "d", "e"]
    var order: List<int> = [0, 1, 2, 3, 4]
    set_rows(h.page, labels(order, names))
    h.page.show_list = true

    var seen: int = 0
    var bad: int = 0
    var worst: int = 0
    var moves_total: int = 0
    var more: bool = true
    for more {
        set_rows(h.page, labels(order, names))
        let cost: int = h.quiet_step()
        seen += 1
        if cost < 0 { bad += 1 }
        else {
            moves_total += cost
            if cost > worst { worst = cost }
        }
        more = next_permutation(order)
    }
    io.println("permutations: {seen}, disagreements: {bad}, worst batch: {worst} edits")
    io.println("total edits across the sweep: {moves_total}")
    r.eqi("all 120 permutations of five rows", seen, 120)
    r.eqi("every one applied to the same html", bad, 0)
    // A reorder must never re-mount. Five rows, 120 arrangements, and every
    // Row still reports one activation — that is the claim "existing rows are
    // matched by key and left alone", measured rather than asserted in prose.
    var kids: List<int> = h.builder.nested.keys()
    kids.sort()
    r.eqi("five children survived the whole sweep", kids.len(), 5)
    var reactivated: int = 0
    var renders: int = 0
    for slot: int in kids {
        match h.builder.children.get(slot) {
            some(stored) => {
                match stored.copy() as? Row {
                    some(row) => {
                        if row.inits != 1 { reactivated += 1 }
                        renders += row.renders
                    }
                    none => { reactivated += 1 }
                }
            }
            none => { reactivated += 1 }
        }
    }
    r.eqi("no row was ever re-activated", reactivated, 0)
    io.println("row renders across the sweep: {renders}")
    r.eqi("the sweep found no faults anywhere", local.bad, 0)
}

fn subsets(r: Report) {
    io.println("== 5 every subset of five keyed rows")
    let local: Report = new Report()
    let h: Harness = new Harness(local)
    let names: List<string> = ["a", "b", "c", "d", "e"]
    var mask: int = 0
    var seen: int = 0
    var bad: int = 0
    var worst: int = 0
    for mask < 32 {
        var wanted: List<string> = []
        var bit: int = 0
        for bit < 5 {
            if (mask / (1 << bit)) % 2 == 1 { wanted.push(names[bit]) }
            bit += 1
        }
        set_rows(h.page, wanted)
        let cost: int = h.quiet_step()
        seen += 1
        if cost < 0 { bad += 1 } else { if cost > worst { worst = cost } }
        mask += 1
    }
    io.println("subsets: {seen}, disagreements: {bad}, worst batch: {worst} edits")
    r.eqi("all 32 subsets", seen, 32)
    r.eqi("every one applied to the same html", bad, 0)
    r.eqi("the sweep found no faults anywhere", local.bad, 0)
}

fn branches(h: Harness, r: Report) {
    io.println("== 6 branch flips and nested component swaps")

    set_rows(h.page, ["a", "b", "c", "d", "e"])
    // Every key changed, so this is five removes and five inserts — the
    // worst case the keyed pass has, and the one a reader should compare the
    // permutation sweep against.
    h.step("back to five rows", 19, true)

    h.page.show_list = false
    // The whole <ul> unit leaves and the text takes its place. Five children
    // are disposed with it, and the batch says so.
    h.step("the branch flips to the other arm", 4, true)
    r.eqi("five children were disposed", h.last.disposed.len(), 5)

    h.page.show_list = true
    // ONE insert brings the whole <ul> back, five rows and all, because the
    // reference pool stages the entire subtree. The five extra edits are the
    // remounted children building their own buffers.
    h.step("and flips back", 9, true)

    h.page.which = 1
    h.step("mount Alpha", 4, true)
    h.page.which = 2
    // Two different components at two different source positions: Alpha's slot
    // is not reached, so it is disposed, and Beta mounts. Nothing is reused
    // across the swap, which is right — they are different types.
    h.step("swap Alpha for Beta", 5, true)
    r.eqi("Alpha was disposed", h.last.disposed.len(), 1)
    h.page.which = 0
    h.step("unmount both", 3, true)
}

fn quiet_children(r: Report) {
    io.println("== 7 a child that answers should_render() == false")
    let local: Report = new Report()
    let h: Harness = new Harness(local)
    set_rows(h.page, ["a", "b", "c", "d", "e"])
    h.page.show_list = true
    let _: int = h.quiet_step()

    var kids: List<int> = h.builder.nested.keys()
    kids.sort()
    var quiet_slot: int = kids[2]
    match h.builder.children.get(quiet_slot) {
        some(stored) => {
            match stored.copy() as? Row {
                some(row) => { row.quiet = true }
                none => {}
            }
        }
        none => {}
    }

    // The quiet child is never reset, so its `previous` and `frames` still
    // hold the pair the LAST batch was built from. Diffing it again would
    // re-send that batch — and inserts, removes and moves are not idempotent.
    // `Builder.diffed` is what stops it.
    h.page.title = "quiet pass"
    let cost: int = h.quiet_step()
    r.yes("the pass still applies cleanly", cost >= 0)
    io.println("edits with one quiet child: {cost}")
    let again: Batch = h.differ.batch(h.builder)
    r.eqi("a second diff with no render in between emits nothing",
        again.edit_count(), 0)
    r.eqi("and names no component at all", again.updates.len(), 0)

    // It renders again once it stops being quiet.
    match h.builder.children.get(quiet_slot) {
        some(stored) => {
            match stored.copy() as? Row {
                some(row) => { row.quiet = false; row.label = "loud" }
                none => {}
            }
        }
        none => {}
    }
    h.page.title = "loud again"
    let after: int = h.quiet_step()
    r.yes("and the tree agrees again", after >= 0)
    r.eqi("no faults in the quiet section", local.bad, 0)
}

fn preserved(r: Report) {
    io.println("== 8 preserve — the divergence that is on purpose")
    let h: Harness = new Harness(r)
    set_rows(h.page, [])
    h.page.show_list = false
    h.page.tail = "one"
    h.step("before preserve", 1, true)

    h.page.preserved = true
    h.page.tail = "two"
    // D6: the differ emits NOTHING for a preserved element — not its
    // attributes and not its children — so "the applier lands on the
    // serializer's html" is deliberately false here. Stating it as a test is
    // the only honest way to have a rule like this.
    h.step("preserve on, text changed", 0, false)

    h.page.tail = "three"
    h.step("still preserved", 0, false)

    h.page.preserved = false
    h.page.tail = "four"
    // The OLD render preserved it, so our old frames no longer describe what
    // is in the DOM: emitting edits against them would be edits for a tree we
    // do not own. So this pass is silent too, in the other direction.
    h.step("preserve off — still silent, because the old side had it", 0, false)

    h.page.tail = "five"
    // Now neither side is preserved and ordinary diffing resumes. The applier
    // catches up in one step.
    h.step("the pass after that resyncs", 5, true)
    r.eqi("three passes diverged, on purpose", h.diverged, 3)
}

fn nested_depth(r: Report) {
    io.println("== 9 a keyed row inside a keyed row")
    let local: Report = new Report()
    let h: Harness = new Harness(local)
    let grid: Grid = new Grid()
    grid.outer = ["r1", "r2", "r3", "r4", "r5"]
    grid.inner = ["c1", "c2", "c3", "c4", "c5"]
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(grid)
    a.apply(d.batch(b))
    let writer: Serializer = new Serializer()
    r.eq("a 5x5 grid builds", a.html(), writer.page(b))

    // Reorder the OUTER rows: the inner runs travel with them untouched.
    grid.outer = ["r5", "r4", "r3", "r2", "r1"]
    b.render_root(grid)
    let outer: Batch = d.batch(b)
    a.apply(outer)
    let writer2: Serializer = new Serializer()
    r.eq("reordering the outer rows", a.html(), writer2.page(b))
    io.println("outer reorder: {outer.edit_count()} edits for 25 cells")
    // `in 0` into the table, four moves, one `out`. Twenty-five cells and the
    // differ never looked inside a single one of them, because the row bodies
    // were unchanged and the speculative step_in was dropped.
    r.eqi("a 5-row reversal is four moves and one step pair", outer.edit_count(), 6)

    // Reorder the INNER columns of every row: five runs, each one move.
    grid.inner = ["c5", "c1", "c2", "c3", "c4"]
    b.render_root(grid)
    let inner: Batch = d.batch(b)
    a.apply(inner)
    let writer3: Serializer = new Serializer()
    r.eq("reordering every inner run", a.html(), writer3.page(b))
    io.println("inner reorder: {inner.edit_count()} edits")

    // Drop an outer row and an inner column at once.
    grid.outer = ["r5", "r4", "r2", "r1"]
    grid.inner = ["c5", "c1", "c3", "c4"]
    b.render_root(grid)
    a.apply(d.batch(b))
    let writer4: Serializer = new Serializer()
    r.eq("dropping in both dimensions", a.html(), writer4.page(b))
    r.eqi("no faults", local.bad + d.faults.len() + a.faults.len(), 0)
    io.println(b.dump())
}

pub class Grid extends Component {
    pub outer: List<string> = []
    pub inner: List<string> = []
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "table")
        for row: string in self.outer {
            b.region(1, row)
            b.open(0, "tr")
            b.attr(1, "data-row", row)
            for cell: string in self.inner {
                b.region(2, cell)
                b.open(0, "td")
                b.text(1, "{row}/{cell}")
                b.close()
                b.end_region()
            }
            b.close()
            b.end_region()
        }
        b.close()
    }
}

fn boundaries(r: Report) {
    io.println("== 10 a boundary whose failure flips")
    let local: Report = new Report()
    let guard: Guard = new Guard()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(guard)
    a.apply(d.batch(b))
    let w1: Serializer = new Serializer()
    r.eq("the body rendered", a.html(), w1.page(b))

    guard.blow_up = true
    b.render_root(guard)
    let flip: Batch = d.batch(b)
    a.apply(flip)
    let w2: Serializer = new Serializer()
    r.eq("the boundary failed", a.html(), w2.page(b))
    io.println("failure flip: {flip.edit_count()} edits")
    io.print(flip.dump())
    // A failed flip is a REPLACEMENT. Matching it would diff the fallback
    // against the body that panicked, which are two unrelated trees that
    // happen to share a scope.
    r.eqi("a failed flip replaces rather than matches", flip.edit_count(), 4)

    guard.blow_up = false
    b.render_root(guard)
    let back: Batch = d.batch(b)
    a.apply(back)
    let w3: Serializer = new Serializer()
    r.eq("and recovers", a.html(), w3.page(b))
    r.eqi("also a replacement", back.edit_count(), 4)
    r.eqi("no faults", local.bad + d.faults.len() + a.faults.len(), 0)
}

pub class Guard extends Component {
    pub blow_up: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "p")
        b.text(1, "the body")
        b.close()
        if self.blow_up {
            b.fail_boundary("boom")
            b.open(0, "p")
            b.attr(1, "class", "error")
            b.text(2, "sorry")
            b.close()
        }
        b.end_boundary()
        b.close()
    }
}

fn fragments(r: Report) {
    io.println("== 11 fragments — a parent's markup placed in a child")
    let local: Report = new Report()
    let host: Host = new Host()
    host.items = ["one", "two", "three", "four", "five"]
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(host)
    a.apply(d.batch(b))
    let w1: Serializer = new Serializer()
    r.eq("a fragment builds", a.html(), w1.page(b))

    host.items = ["five", "four", "three", "two", "one"]
    b.render_root(host)
    let batch: Batch = d.batch(b)
    a.apply(batch)
    let w2: Serializer = new Serializer()
    r.eq("keyed rows inside a fragment reorder", a.html(), w2.page(b))
    io.println("fragment reorder: {batch.edit_count()} edits")
    io.print(batch.dump())

    host.wrap = false
    b.render_root(host)
    a.apply(d.batch(b))
    let w3: Serializer = new Serializer()
    r.eq("the fragment goes away", a.html(), w3.page(b))
    r.eqi("no faults", local.bad + d.faults.len() + a.faults.len(), 0)
}

pub class Host extends Component {
    pub items: List<string> = []
    pub wrap: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if self.wrap {
            b.fragment(1, fn(inner: Builder) {
                for item: string in self.items {
                    inner.region(0, item)
                    inner.open(0, "b")
                    inner.text(1, item)
                    inner.close()
                    inner.end_region()
                }
            })
        } else {
            b.text(5, "unwrapped")
        }
        b.close()
    }
}

// ---------------------------------------------------------------- main

fn main() {
    let r: Report = new Report()
    let h: Harness = new Harness(r)

    basics(h, r)
    scalars(h, r)
    keyed(h, r)
    permutations(r)
    subsets(r)
    branches(h, r)
    quiet_children(r)
    preserved(r)
    nested_depth(r)
    boundaries(r)
    fragments(r)

    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
