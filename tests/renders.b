// tests/renders.b — the update model.
//
// This is the gate that proves latte's headline claim, and the one a framework
// quietly fails: "the page is never re-rendered. Not on an event, not on a
// navigation inside a circuit, not ever." Every other suite here passes just as
// well for a framework that re-renders the world.
//
// So every assertion is an EXACT NUMBER, and the numbers are taken from
// `Renderer.render_count`, which counts from `Builder.diffed` — a buffer that
// is unsettled at the end of a pass and settled at the start of it ran exactly
// once. Nothing in this file counts renders by incrementing a field of its own;
// a counter a test component keeps only counts the components the test
// remembered to instrument.
//
// The board is 200 rows. That is not decoration: "notifying one row runs one
// render, not two hundred" is a claim about two hundred, and a case built from
// two rows would pass for a framework that renders every one of them.
package main

import std.io
import {Applier, Builder, Component, Renderer, Frame, Batch, Edit, ComponentUpdate,
        describe_edit, MouseEvent, InputEvent, Serializer, Signal} from latte

const ROWS: int = 200

// ---------------------------------------------------------------- fixtures

/// A row. It compares its own parameter and answers `should_render` from that,
/// which is what makes "a parameter that did not change runs zero" a property
/// of the framework honouring the answer rather than of the row being lazy.
class Row extends Component {
    pub label: string = ""
    pub hits: int = 0
    seen: string = "<unset>"
    changed: bool = true
    pub inits: int = 0
    pub params_set: int = 0
    pub disposals: int = 0
    pub fn init() {}

    pub override fn on_init() { self.inits += 1 }
    pub override fn dispose() { self.disposals += 1 }

    /// The parameter comparison goes HERE and not in `should_render`, and the
    /// difference is not stylistic: `should_render` is consulted only from the
    /// second render onward, so a component that snapshots there never records
    /// the first render's parameters and answers "changed" for ever after.
    /// `on_params_set` runs on every render including the first.
    pub override fn on_params_set() {
        self.params_set += 1
        self.changed = self.seen != self.label
        self.seen = self.label
    }

    pub override fn should_render() -> bool { return self.changed }

    pub override fn render(b: Builder) {
        b.open(0, "li")
        b.on_click(1, fn(e: MouseEvent) { self.hits += 1 })
        b.text(2, "{self.label}/{self.hits}")
        // A constant subtree, in the two arms generated code emits. The folded
        // arm takes the run's first number and the unfolded arm spends 3, 4
        // and 5, so the sibling after it is 6 in both.
        if b.fold { b.constant(3, "<em class=\"tag\">row</em>") }
        else {
            b.open(3, "em")
            b.attr(4, "class", "tag")
            b.text(5, "row")
            b.close()
        }
        b.text(6, ".")
        b.close()
    }
}

/// Keys and labels are separate lists on purpose. A row's identity is its key
/// and its parameter is its label, and a test that changes one string for both
/// cannot tell "the same row re-rendered because its parameter changed" from
/// "a differently-keyed row was mounted and the old one disposed" — which are
/// different claims with the same render count.
class Board extends Component {
    pub keys: List<string> = []
    pub labels: List<string> = []
    pub heading: string = "board"
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "ul")
        b.attr(1, "class", "board")
        b.text(2, "{self.heading}")
        for index: int in 0..self.keys.len() {
            let text: string = self.labels[index]
            b.region(3, self.keys[index])
            b.component<Row>(0, fn(c: Row) { c.label = text })
            b.end_region()
        }
        b.close()
    }
}

// ---------------------------------------------------------------- live
//
// The third tier's fixtures. `LiveBoard` is `Board` with one live cell in its
// heading, and it carries the same ROWS rows for the same reason: "a signal
// write runs no render at all" is a claim about the whole page, and a page
// with one component in it would pass for an implementation that re-rendered
// everything it could reach.
//
// The live expression reads ONE of two signals depending on `mode`, because a
// dependency set that is only ever added to is not a dependency set. A branch
// flip has to make the signal it stopped reading stop waking it.

class LiveBoard extends Component {
    pub keys: List<string> = []
    pub labels: List<string> = []
    pub heading: string = "live"
    pub count: Signal<int> = new Signal<int>(0)
    pub name: Signal<string> = new Signal<string>("a")
    pub mode: bool = true
    pub fn init() {}

    /// `own(self)` cannot go in the field initializer or in `init`: `self` may
    /// not be passed on until every field is assigned, and these signals are
    /// exactly the fields that are not. `on_init` runs after activation, when
    /// the component is whole and the framework has already wired it.
    pub override fn on_init() {
        self.count.own(self)
        self.name.own(self)
    }

    pub override fn render(b: Builder) {
        b.open(0, "ul")
        b.attr(1, "class", "board")
        b.text(2, "{self.heading}")
        b.open(3, "li")
        b.attr(4, "class", "head")
        b.live_text(5, fn() -> string {
            if self.mode { return "c{self.count.get()}" }
            return "n{self.name.get()}"
        })
        b.close()
        for index: int in 0..self.keys.len() {
            let text: string = self.labels[index]
            b.region(6, self.keys[index])
            b.component<Row>(0, fn(c: Row) { c.label = text })
            b.end_region()
        }
        b.close()
    }
}

/// `LiveBoard`'s markup, frame for frame, with the heading cell written by
/// `b.text` from a plain field instead of by `b.live_text` from a signal.
///
/// It exists for one row: the edit a signal write produces must be the edit
/// the DIFFER produces for the same change. A live binding computes its child
/// indices forwards, from `scan_spans`; the differ computes them by comparison
/// while merging two frame lists. If those two ever disagreed, a signal write
/// would land a `set_text` on the wrong node and every other row in § 10 would
/// still pass — they all read the signal side.
class PlainBoard extends Component {
    pub keys: List<string> = []
    pub labels: List<string> = []
    pub heading: string = "live"
    pub count: int = 0
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "ul")
        b.attr(1, "class", "board")
        b.text(2, "{self.heading}")
        b.open(3, "li")
        b.attr(4, "class", "head")
        b.text(5, "c{self.count}")
        b.close()
        for index: int in 0..self.keys.len() {
            let text: string = self.labels[index]
            b.region(6, self.keys[index])
            b.component<Row>(0, fn(c: Row) { c.label = text })
            b.end_region()
        }
        b.close()
    }
}

/// A mounted child that owns its own signal, so § 11 can ask which component
/// an edit is addressed to.
class Meter extends Component {
    pub value: Signal<int> = new Signal<int>(0)
    pub fn init() {}
    pub override fn on_init() { self.value.own(self) }
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.live_text(1, fn() -> string { return "m{self.value.get()}" })
        b.close()
    }
}

class Shell extends Component {
    pub show: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "shell")
        if self.show { b.component<Meter>(2, fn(m: Meter) {}) }
        b.close()
    }
}

/// A live expression under `preserve`. The differ emits nothing at all for a
/// preserved element — not its attributes and not its children — because
/// something else owns what is under there now, and the live tier has to be
/// silent in exactly the same place.
class Kept extends Component {
    pub value: Signal<int> = new Signal<int>(0)
    pub fn init() {}
    pub override fn on_init() { self.value.own(self) }
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.preserve(1)
        b.live_text(2, fn() -> string { return "k{self.value.get()}" })
        b.close()
    }
}

// ---------------------------------------------------------------- reporting

/// Module-level values are `const` in Beans, so the failure count lives in an
/// object rather than in a mutable global.
class Report {
    pub failures: int = 0
    pub fn init() {}

    pub fn check(label: string, got: int, want: int) {
        if got == want {
            io.println("ok   {label}: {got}")
        } else {
            io.println("FAIL {label}: got {got}, want {want}")
            self.failures += 1
        }
    }

    pub fn check_text(label: string, got: string, want: string) {
        if got == want {
            io.println("ok   {label}: {got}")
        } else {
            io.println("FAIL {label}: got \"{got}\", want \"{want}\"")
            self.failures += 1
        }
    }
}

/// Every component whose render count is not `want`, so a failure names the
/// rows rather than saying "some row moved".
fn count_where(r: Renderer, want: int) -> int {
    var n: int = 0
    var ids: List<int> = r.ids()
    for id: int in ids { if r.render_count(id) == want { n += 1 } }
    return n
}

fn total_renders(r: Renderer) -> int {
    var n: int = 0
    var ids: List<int> = r.ids()
    for id: int in ids { n += r.render_count(id) }
    return n
}

/// The handler slot bound by one component, so a test can fire a row by name
/// rather than by guessing a number.
fn handler_of(r: Renderer, id: int) -> int {
    match r.buffer(id) {
        some(buffer) => {
            for frame: Frame in buffer.frames.items {
                match frame {
                    handler(_, _, slot) => { return slot }
                    _ => {}
                }
            }
            return -1
        }
        none => { return -1 }
    }
}

/// The component id of the n-th mounted row, in mount order.
fn row_id(r: Renderer, index: int) -> int {
    var ids: List<int> = r.ids()
    var seen: int = 0
    for id: int in ids {
        if id == 0 { continue }
        if seen == index { return id }
        seen += 1
    }
    return -1
}

fn edits_of(batch: Batch, component: int) -> int {
    for update: ComponentUpdate in batch.updates {
        if update.component == component { return update.edits.len() }
    }
    return 0
}

fn frame_count(r: Renderer, id: int) -> int {
    match r.buffer(id) {
        some(buffer) => { return buffer.frames.len() }
        none => { return -1 }
    }
}

// ---------------------------------------------------------------- the gate

fn main() {
    let report: Report = new Report()
    let board: Board = new Board()
    var i: int = 0
    for i < ROWS {
        board.keys.push("k{i}")
        board.labels.push("r{i}")
        i += 1
    }

    let r: Renderer = new Renderer()
    r.mount(board)

    io.println("== 1. the first render mounts everything, once ==")
    report.check("components mounted (board + rows)", r.ids().len(), ROWS + 1)
    report.check("board renders", r.render_count(0), 1)
    report.check("rows that rendered exactly once", count_where(r, 1), ROWS + 1)
    report.check("total renders across the page", total_renders(r), ROWS + 1)
    report.check("faults", r.all_faults().len(), 0)

    // Drain the first batch so what follows is measured from a settled tree.
    let first: Batch = r.batch()
    report.check("first batch: one update per component", first.updates.len(), ROWS + 1)

    io.println("")
    io.println("== 2. notifying one row runs ONE render, not two hundred ==")
    let target: int = row_id(r, 137)
    let slot: int = handler_of(r, target)
    // Two slot ids per row — the mount and its handler — allocated in mount
    // order from 1, so these are derived, not observed.
    report.check("row 137 is a mounted component", target, 1 + 2 * 137)
    report.check("it bound exactly one handler slot", slot, 2 + 2 * 137)
    let ev: MouseEvent = new MouseEvent()
    report.check("dispatch found the handler", if r.fire_mouse(slot, ev) { 1 } else { 0 }, 1)
    report.check("exactly one component is dirty", r.pending(), 1)
    report.check("the dirty one is the row that owns the handler",
          if r.is_dirty(target) { 1 } else { 0 }, 1)
    report.check("the flush ran exactly one render", r.flush(), 1)
    report.check("that row has now rendered twice", r.render_count(target), 2)
    report.check("the board has NOT re-rendered", r.render_count(0), 1)
    report.check("every other component is still at one", count_where(r, 1), ROWS)
    report.check("total renders across the page", total_renders(r), ROWS + 2)

    let second: Batch = r.batch()
    report.check("the batch touches exactly one component", second.updates.len(), 1)
    report.check("one structural edit", structural_edits(second), 1)
    report.check("three edits in all, the other two being the cursor",
                 second.edit_count(), 3)
    report.check_text("and this is the whole stream", describe_all(second),
                      "in 0 | text 0 = r137/1 | out")

    io.println("")
    io.println("== 3. a parameter that did not change runs ZERO ==")
    // Re-render the board itself. It walks all 200 rows and calls every
    // setter; not one row's label changed, so not one row re-renders.
    r.mark(0)
    report.check("the flush ran the board and nothing else", r.flush(), 1)
    report.check("the board has rendered twice", r.render_count(0), 2)
    report.check("row 137 is still at two", r.render_count(target), 2)
    report.check("total renders across the page", total_renders(r), ROWS + 3)
    report.check("on_params_set ran for every row anyway", params_set_of(r, target), 3)
    let third: Batch = r.batch()
    report.check("a board render that changed nothing sends nothing",
          third.edit_count(), 0)

    io.println("")
    io.println("== 4. a parameter that DID change runs exactly the rows it hit ==")
    board.labels[7] = "moved"
    board.heading = "board!"
    r.mark(0)
    report.check("the flush ran the board and one row", r.flush(), 2)
    report.check("the board has rendered three times", r.render_count(0), 3)
    report.check("the row whose label changed has rendered twice",
          r.render_count(row_id(r, 7)), 2)
    report.check("row 6 has not re-rendered", r.render_count(row_id(r, 6)), 1)
    report.check("row 8 has not re-rendered", r.render_count(row_id(r, 8)), 1)
    report.check("total renders across the page", total_renders(r), ROWS + 5)

    io.println("")
    io.println("== 5. a constant subtree is one frame, and is never walked ==")
    // A row's markup is: li, handler, text, <the constant>, text, close.
    // Folded that is 6 frames; unfolded it is 9, because the subtree the fold
    // replaced is open+attr+text+close.
    report.check("a row's frames, folded", frame_count(r, target), 6)
    let unfolded: Renderer = new Renderer()
    unfolded.root.fold = false
    let plain: Board = new Board()
    plain.keys.push("k")
    plain.labels.push("only")
    unfolded.mount(plain)
    report.check("a row's frames, unfolded",
                 frame_count(unfolded, row_id(unfolded, 0)), 9)
    let folded: Renderer = new Renderer()
    let twin: Board = new Board()
    twin.keys.push("k")
    twin.labels.push("only")
    folded.mount(twin)
    report.check("a row's frames, folded again", frame_count(folded, row_id(folded, 0)), 6)
    report.check_text("and the two arms serialize to the same bytes",
                      row_html_of(unfolded, row_id(unfolded, 0)),
                      row_html_of(folded, row_id(folded, 0)))

    // Change the row's dynamic text and diff. The constant carries the same
    // seq and the same html, so the differ compares two numbers and a string
    // and emits nothing for it — one edit for the whole row.
    let _: Batch = r.batch()
    let _: bool = r.fire_mouse(handler_of(r, target), new MouseEvent())
    report.check("one render", r.flush(), 1)
    let batch5: Batch = r.batch()
    report.check("one structural edit for the whole row",
                 structural_edits(batch5), 1)
    report.check("and none of it names the constant", markup_edits(batch5), 0)

    io.println("")
    io.println("== 6. an event on an unknown id changes nothing ==")
    report.check("dispatch refuses it",
          if r.fire_mouse(999999, new MouseEvent()) { 1 } else { 0 }, 0)
    report.check("nothing is dirty", r.pending(), 0)
    report.check("the flush runs nothing", r.flush(), 0)
    report.check("total renders is unchanged", total_renders(r), ROWS + 6)

    io.println("")
    io.println("== 7. a dirty ancestor swallows a dirty descendant ==")
    // Both marked. Rendering the board renders the row through component<T>,
    // so the row must not also be rendered on its own — a buffer rendered
    // twice before a diff has a `previous` that is the middle pass, and the
    // batch would re-send the last batch's inserts, removes and moves.
    board.labels[7] = "moved again"
    r.mark(0)
    r.mark(row_id(r, 7))
    report.check("both are dirty", r.pending(), 2)
    report.check("the flush ran the board and the row ONCE each", r.flush(), 2)
    report.check("the board", r.render_count(0), 4)
    report.check("the row", r.render_count(row_id(r, 7)), 3)
    report.check("total renders across the page", total_renders(r), ROWS + 8)
    let batch7: Batch = r.batch()
    // ONE, not two. The board re-rendered and produced byte-identical frames —
    // its heading and its keys did not change — so it contributes no update at
    // all. A render is not an edit, and this is the assertion that says so.
    report.check("but only the row that changed sends anything",
                 batch7.updates.len(), 1)

    io.println("")
    io.println("== 7b. a marked row under a marked parent whose parameter did NOT change ==")
    // The case § 7 cannot reach. Here the row's own state changed (its click
    // counter) while its parameter did not, so the parent's cascade asks
    // `should_render`, is told no, and skips it. Without the second look the
    // row never renders and the click is silently lost — and § 7 passes
    // anyway, because there the parameter had changed too.
    let quiet: int = row_id(r, 20)
    let quiet_handler: int = handler_of(r, quiet)
    report.check("the click was dispatched",
                 if r.fire_mouse(quiet_handler, new MouseEvent()) { 1 } else { 0 }, 1)
    board.heading = "board!!"
    r.mark(0)
    report.check("both are dirty", r.pending(), 2)
    report.check("the flush ran the board and the row", r.flush(), 2)
    report.check("the board", r.render_count(0), 5)
    report.check("the row whose own state changed", r.render_count(quiet), 2)
    report.check("its neighbour did not", r.render_count(row_id(r, 21)), 1)
    let batch7b: Batch = r.batch()
    report.check("two components send edits", batch7b.updates.len(), 2)
    report.check_text("and this is the whole stream", describe_all(batch7b),
                      "in 0 | text 0 = board!! | out | in 0 | text 0 = r20/1 | out")

    io.println("")
    io.println("== 8. one appended row is one row's render and one insert ==")
    board.keys.push("k{ROWS}")
    board.labels.push("appended")
    r.mark(0)
    report.check("the flush ran the board and the new row", r.flush(), 2)
    report.check("the new row rendered once", r.render_count(row_id(r, ROWS)), 1)
    report.check("the board", r.render_count(0), 6)
    // Still at their first render: every original row except the three this
    // suite has re-rendered (row 7 in § 4 and § 7, row 137 in § 2 and § 5,
    // row 20 in § 7b), plus the row just appended.
    report.check("every other row is still at its first render",
                 count_where(r, 1), ROWS - 3 + 1)
    report.check("the page now has one more component", r.ids().len(), ROWS + 2)
    let batch8: Batch = r.batch()
    report.check("the board sends one structural edit", board_structural(batch8), 1)
    report.check_text("and this is the whole stream", describe_all(batch8),
                      "in 0 | insert 201 <- ref@0 | out | insert 0 <- ref@3")

    io.println("")
    io.println("== 9. a removed row is disposed, once, and its handler dies ==")
    let doomed: int = row_id(r, 7)
    let doomed_handler: int = handler_of(r, doomed)
    let disposals_before: int = disposals_of(r, doomed)
    let victim: Row = row_of(r, doomed)
    let _: string = board.keys.remove(7)
    let _: string = board.labels.remove(7)
    r.mark(0)
    report.check("the flush ran the board only", r.flush(), 1)
    report.check("the page has one fewer component", r.ids().len(), ROWS + 1)
    report.check("the row is no longer mounted", if r.mounted(doomed) { 1 } else { 0 }, 0)
    report.check("dispose ran exactly once", victim.disposals, disposals_before + 1)
    report.check("its handler no longer dispatches",
          if r.fire_mouse(doomed_handler, new MouseEvent()) { 1 } else { 0 }, 0)
    report.check("and marking its id does nothing", after_mark(r, doomed), 0)
    report.check("faults", r.all_faults().len(), 0)

    io.println("")
    io.println("== 10. a signal write runs ZERO renders ==")
    // A signal write updates the one bound expression directly — no render
    // pass, no diff, one edit. Both halves are asserted here, and the second
    // is why signals exist at all: a signal that still cost a diff would
    // cost the same as an ordinary re-render.
    let lb: LiveBoard = new LiveBoard()
    var k: int = 0
    for k < ROWS {
        lb.keys.push("k{k}")
        lb.labels.push("r{k}")
        k += 1
    }
    let lr: Renderer = new Renderer()
    lr.mount(lb)
    report.check("the live board mounted every row", lr.ids().len(), ROWS + 1)
    report.check("everything rendered exactly once", count_where(lr, 1), ROWS + 1)
    report.check("total renders across the page", total_renders(lr), ROWS + 1)
    report.check("faults", lr.all_faults().len(), 0)
    let live_first: Batch = lr.batch()
    report.check("first batch: one update per component",
                 live_first.updates.len(), ROWS + 1)

    lb.count.set(1)
    report.check("nothing is dirty", lr.pending(), 0)
    report.check("no flush happened", lr.flushes, 0)
    report.check("the board has NOT re-rendered", lr.render_count(0), 1)
    report.check("EVERY component is still at exactly one render",
                 count_where(lr, 1), ROWS + 1)
    report.check("total renders across the page", total_renders(lr), ROWS + 1)
    let sig1: Batch = lr.batch()
    report.check("one component sends anything", sig1.updates.len(), 1)
    report.check("one structural edit", structural_edits(sig1), 1)
    report.check("five edits in all, the other four being the cursor",
                 sig1.edit_count(), 5)
    report.check_text("and this is the whole stream", describe_all(sig1),
                      "in 0 | in 1 | text 0 = c1 | out | out")

    io.println("")
    io.println("== 10b. the same edit the DIFFER would have produced ==")
    // The row that says the child indices are right and not merely stable.
    // Same markup, same change, one side live and one side not: the live side
    // computed `[0, 1, 0]` forwards out of `scan_spans`, and the plain side
    // got there by merging two frame lists. The two streams have to be one
    // string.
    let twin_board: PlainBoard = new PlainBoard()
    k = 0
    for k < ROWS {
        twin_board.keys.push("k{k}")
        twin_board.labels.push("r{k}")
        k += 1
    }
    let mirror: Renderer = new Renderer()
    mirror.mount(twin_board)
    report.check("the plain twin mounted the same page", mirror.ids().len(), ROWS + 1)
    let _: Batch = mirror.batch()
    twin_board.count = 1
    mirror.mark(0)
    report.check("the twin re-rendered the board", mirror.flush(), 1)
    report.check("the twin board has rendered twice", mirror.render_count(0), 2)
    let rendered: Batch = mirror.batch()
    report.check_text("and the differ's edits are the signal's edits, exactly",
                      describe_all(rendered), describe_all(sig1))
    report.check("one component, on that side too", rendered.updates.len(), 1)
    report.check("the signal side ran no render at all", lr.render_count(0), 1)

    io.println("")
    io.println("== 10c. repeated writes between two batches are ONE edit ==")
    // The differ cannot reach this case, so nothing else in the suite covers
    // it: a signal rewrites the frame in place, and a second write before the
    // batch REWRITES the queued edit rather than appending another. The wire
    // carries what the client needs, not a history of it.
    lb.count.set(2)
    lb.count.set(3)
    let sig3: Batch = lr.batch()
    report.check("still one update", sig3.updates.len(), 1)
    report.check("still five edits", sig3.edit_count(), 5)
    report.check_text("carrying the LAST value", describe_all(sig3),
                      "in 0 | in 1 | text 0 = c3 | out | out")
    report.check("and still no render", lr.render_count(0), 1)

    io.println("")
    io.println("== 10d. a write that changes nothing sends nothing ==")
    lb.count.set(3)
    let sig4: Batch = lr.batch()
    report.check("a write of the same value", sig4.edit_count(), 0)
    lb.name.set("zz")
    let sig5: Batch = lr.batch()
    report.check("a write to a signal the expression did not read",
                 sig5.edit_count(), 0)
    report.check("the read signal has one subscriber",
                 lb.count.cell.subscribers(), 1)
    report.check("the unread one has none", lb.name.cell.subscribers(), 0)
    report.check("no render, still", lr.render_count(0), 1)
    report.check("no flush, still", lr.flushes, 0)

    io.println("")
    io.println("== 10e. the counter CAN move — a render moves it ==")
    // Without this row "zero renders" is indistinguishable from a counter that
    // does not count. Same renderer, same component, one `mark` apart.
    lb.mode = false
    lr.mark(0)
    report.check("the flush ran the board and nothing else", lr.flush(), 1)
    report.check("the board has now rendered twice", lr.render_count(0), 2)
    report.check("total renders across the page", total_renders(lr), ROWS + 2)
    report.check("every row is still at its first render", count_where(lr, 1), ROWS)
    let flipped: Batch = lr.batch()
    report.check_text("and the branch flip is one edit", describe_all(flipped),
                      "in 0 | in 1 | text 0 = nzz | out | out")

    io.println("")
    io.println("== 10f. the dependency set is the LAST read, not the union ==")
    report.check("the signal it stopped reading has no subscriber",
                 lb.count.cell.subscribers(), 0)
    report.check("the one it reads now has one", lb.name.cell.subscribers(), 1)
    lb.count.set(4)
    let sig6: Batch = lr.batch()
    report.check("writing the abandoned signal sends nothing", sig6.edit_count(), 0)
    lb.name.set("q")
    let sig7: Batch = lr.batch()
    report.check_text("writing the live one still sends one edit",
                      describe_all(sig7), "in 0 | in 1 | text 0 = nq | out | out")
    report.check("and neither write rendered anything", lr.render_count(0), 2)
    report.check("one flush in the whole section", lr.flushes, 1)
    report.check("faults", lr.all_faults().len(), 0)

    io.println("")
    io.println("== 10g. a write and then a render, before the next batch ==")
    // The case with no analogue anywhere else in the framework, and the one
    // that was WRONG when this section was first written.
    //
    // A signal rewrites the frame body in place. `reset()` then assigns
    // `previous = frames`, so the mutation lands on BOTH sides of the next
    // diff and the differ cannot see it — while the client is still holding
    // the value from before the write. Dropping the queued edit as "the diff
    // will carry it" loses the write silently, and every other row in § 10
    // stays green while it does.
    //
    // So the queued edit leads the update and the render's own edits follow:
    // one walks the client to `previous`, the other walks it on to `frames`.
    lb.name.set("r")
    lb.heading = "live!"
    lr.mark(0)
    report.check("the flush ran the board", lr.flush(), 1)
    report.check("the board has rendered three times", lr.render_count(0), 3)
    let both: Batch = lr.batch()
    report.check("one component", both.updates.len(), 1)
    report.check("two structural edits", structural_edits(both), 2)
    report.check("eight edits in all", both.edit_count(), 8)
    report.check_text("the signal's edit first, then the render's",
                      describe_all(both),
                      "in 0 | in 1 | text 0 = nr | out | out | in 0 | text 0 = live! | out")
    report.check("every row is STILL at its first render", count_where(lr, 1), ROWS)

    io.println("")
    io.println("== 11. a signal in a mounted child is addressed to the CHILD ==")
    let shell: Shell = new Shell()
    let sr: Renderer = new Renderer()
    sr.mount(shell)
    report.check("two components", sr.ids().len(), 2)
    let _: Batch = sr.batch()
    let meter: Meter = meter_of(sr, 1)
    meter.value.set(5)
    report.check("the shell did not render", sr.render_count(0), 1)
    report.check("the meter did not render either", sr.render_count(1), 1)
    report.check("nothing is dirty", sr.pending(), 0)
    let child: Batch = sr.batch()
    report.check("one component sends anything", child.updates.len(), 1)
    report.check("and it is the child", component_at(child, 0), 1)
    report.check("the parent sends nothing", edits_of(child, 0), 0)
    report.check_text("the stream is addressed inside the child",
                      describe_all(child), "in 0 | text 0 = m5 | out")

    io.println("")
    io.println("== 12. a live expression under `preserve` is silent ==")
    // `Differ.pair` emits NOTHING for a preserved element, attributes and
    // children alike, because something else owns what is under there now. A
    // live binding that sent an edit anyway would be the one path in the
    // framework that writes into a preserved subtree.
    let kept: Kept = new Kept()
    let kr: Renderer = new Renderer()
    kr.mount(kept)
    let _: Batch = kr.batch()
    kept.value.set(1)
    let silent: Batch = kr.batch()
    report.check("no edit crosses the wire", silent.edit_count(), 0)
    report.check("and no render ran", kr.render_count(0), 1)
    // The frame IS rewritten, so the serializer and the next real render both
    // see the new value. Only the wire is silent, which is what `preserve`
    // asks for.
    report.check_text("but the frames moved", kr.html(), "<div>k1</div>")

    io.println("")
    io.println("== 13. a signal write after disposal is inert ==")
    shell.show = false
    sr.mark(0)
    report.check("the flush ran the shell", sr.flush(), 1)
    report.check("the meter is gone", sr.ids().len(), 1)
    let _: Batch = sr.batch()
    meter.value.set(9)
    let dead: Batch = sr.batch()
    report.check("the write sends nothing", dead.edit_count(), 0)
    report.check("nothing is dirty", sr.pending(), 0)
    report.check("faults", sr.all_faults().len(), 0)

    io.println("")
    io.println("== 14. a signal batch APPLIES to the tree it describes ==")
    // §§ 10-13 assert what crosses the wire. This asserts that what crosses
    // the wire means the right thing when something applies it — gate 3's
    // contract, over the streams only the live tier produces. § 10b proved the
    // signal's edits equal the differ's for one shape; this walks a real
    // applier through a write, a write-then-render, and a branch flip, and
    // requires the applier's DOM to be the serializer's HTML of the same
    // frames every time.
    let small: LiveBoard = new LiveBoard()
    var j: int = 0
    for j < 3 {
        small.keys.push("k{j}")
        small.labels.push("r{j}")
        j += 1
    }
    let ar: Renderer = new Renderer()
    let dom: Applier = new Applier()
    ar.mount(small)
    dom.apply(ar.batch())
    report.check_text("the first render lands", dom.html(), page_html(ar))
    report.check_text("and it is this page", dom.html(), expected_page("live", "c0"))

    small.count.set(4)
    dom.apply(ar.batch())
    report.check_text("a signal write lands", dom.html(), page_html(ar))
    report.check_text("and only the live cell moved", dom.html(),
                      expected_page("live", "c4"))

    // The § 10g shape: the queued edit and the render's edits in one update.
    small.count.set(5)
    small.heading = "live!"
    ar.mark(0)
    report.check("the flush ran the board", ar.flush(), 1)
    dom.apply(ar.batch())
    report.check_text("a write and a render in one batch land", dom.html(), page_html(ar))
    report.check_text("and both changes are there", dom.html(),
                      expected_page("live!", "c5"))

    small.mode = false
    ar.mark(0)
    report.check("the flush ran the board", ar.flush(), 1)
    dom.apply(ar.batch())
    report.check_text("the branch flip lands", dom.html(), page_html(ar))
    small.name.set("z")
    dom.apply(ar.batch())
    report.check_text("and the other signal drives it now", dom.html(),
                      expected_page("live!", "nz"))
    report.check("the applier raised nothing", dom.faults.len(), 0)
    report.check("the board rendered twice in this section", ar.render_count(0), 3)
    report.check("faults", ar.all_faults().len(), 0)

    io.println("")
    if report.failures == 0 {
        io.println("renders: every count exact")
    } else {
        io.println("renders: {report.failures} FAILED")
    }
}

// ---------------------------------------------------------------- helpers

/// Every edit in the batch, in order, as one line. An edit count on its own
/// cannot tell a `set_text` from a `remove`, and the cursor edits (`in`/`out`)
/// are part of what the applier receives, so they are shown rather than
/// filtered — a golden that hides half the stream is a golden that cannot fail
/// when the differ starts sending the wrong half.
fn describe_all(batch: Batch) -> string {
    var out: string = ""
    for update: ComponentUpdate in batch.updates {
        for edit: Edit in update.edits {
            if out == "" { out = describe_edit(edit) }
            else { out = "{out} | {describe_edit(edit)}" }
        }
    }
    if out == "" { return "<none>" }
    return out
}

/// Edits that change the DOM, as against the cursor edits that move around it.
/// "One appended row is one insert" is a claim about these; a raw edit count
/// includes the `in`/`out` pair that carries the insert to the right node.
fn structural_edits(batch: Batch) -> int {
    var n: int = 0
    for update: ComponentUpdate in batch.updates {
        for edit: Edit in update.edits { n += if cursor_edit(edit) { 0 } else { 1 } }
    }
    return n
}

fn board_structural(batch: Batch) -> int {
    var n: int = 0
    for update: ComponentUpdate in batch.updates {
        if update.component != 0 { continue }
        for edit: Edit in update.edits { n += if cursor_edit(edit) { 0 } else { 1 } }
    }
    return n
}

fn cursor_edit(edit: Edit) -> bool {
    match edit {
        step_in(_) => { return true }
        step_out => { return true }
        _ => { return false }
    }
}

fn markup_edits(batch: Batch) -> int {
    var n: int = 0
    for update: ComponentUpdate in batch.updates {
        for edit: Edit in update.edits {
            match edit {
                set_markup(_, _) => { n += 1 }
                _ => {}
            }
        }
    }
    return n
}

fn params_set_of(r: Renderer, id: int) -> int {
    match r.component(id) {
        some(component) => {
            match component as? Row {
                some(row) => { return row.params_set }
                none => { return -1 }
            }
        }
        none => { return -1 }
    }
}

fn disposals_of(r: Renderer, id: int) -> int {
    match r.component(id) {
        some(component) => {
            match component as? Row {
                some(row) => { return row.disposals }
                none => { return -1 }
            }
        }
        none => { return -1 }
    }
}

fn row_of(r: Renderer, id: int) -> Row {
    match r.component(id) {
        some(component) => {
            match component as? Row {
                some(row) => { return row }
                none => { return new Row() }
            }
        }
        none => { return new Row() }
    }
}

fn after_mark(r: Renderer, id: int) -> int {
    r.mark(id)
    return r.pending()
}

/// The component id an update at `index` is addressed to.
fn component_at(batch: Batch, index: int) -> int {
    if index >= batch.updates.len() { return -1 }
    return batch.updates[index].component
}

fn meter_of(r: Renderer, id: int) -> Meter {
    match r.component(id) {
        some(component) => {
            match component as? Meter {
                some(meter) => { return meter }
                none => { return new Meter() }
            }
        }
        none => { return new Meter() }
    }
}

/// The whole three-row live page, with the heading and the live cell written
/// out. Parameterised on the two things § 14 changes and on nothing else, so a
/// row that passes is a row that saw the rest of the page too.
fn expected_page(heading: string, cell: string) -> string {
    let rows: string = "<li>r0/0<em class=\"tag\">row</em>.</li><li>r1/0<em class=\"tag\">row</em>.</li><li>r2/0<em class=\"tag\">row</em>.</li>"
    return "<ul class=\"board\">{heading}<li class=\"head\">{cell}</li>{rows}</ul>"
}

fn page_html(r: Renderer) -> string {
    let writer: Serializer = new Serializer()
    return writer.page(r.root)
}

fn row_html_of(r: Renderer, id: int) -> string {
    let writer: Serializer = new Serializer()
    match r.buffer(id) {
        some(buffer) => { return writer.page(buffer) }
        none => { return "<missing>" }
    }
}
