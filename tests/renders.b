// tests/renders.b — PLAN.md gate 6, the update model.
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
import {Builder, Component, Renderer, Frame, Batch, Edit, ComponentUpdate, describe_edit,
        MouseEvent, InputEvent, Serializer} from latte

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

fn row_html_of(r: Renderer, id: int) -> string {
    let writer: Serializer = new Serializer()
    match r.buffer(id) {
        some(buffer) => { return writer.page(buffer) }
        none => { return "<missing>" }
    }
}
