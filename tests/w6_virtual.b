// Check 8, second row: a window that scrolls to the end and back with NO GAP
// and NO DUPLICATE, over a 50,000-row table.
//
// What "no gap" and "no duplicate" mean here, precisely, because a suite that
// left them vague would pass while the page was wrong:
//
//   * **no gap, in the page.** `top + shown * row_height + bottom` is the
//     whole list's height at every position. A window that breaks it puts the
//     rows at the wrong offset under a scrollbar of the right length, so the
//     row under the cursor is not the row the user thinks it is.
//   * **no gap, in the scroll.** The window must hold every row the viewport
//     shows at that offset, and consecutive windows on the way down must
//     overlap or abut. Two windows with a hole between them is a band of blank
//     rows that appears only while scrolling fast — the bug nobody reproduces.
//   * **no duplicate, in one render.** The keyed region's keys are the row
//     indices, so a row rendered twice is a duplicate key, and a duplicate key
//     is what the differ cannot move correctly. Every render below has its keys
//     read back out of the frames and checked for exactly the window's indices,
//     in order, each once.
//   * **coverage.** Over the whole sweep the union of the windows is exactly
//     0 .. 49,999, with no break anywhere in the chain — so every row of the
//     table was reachable by scrolling to it.
//
// Sections:
//   1  the sweep      — 50,000 rows, every row offset down and back, plus every
//                       pixel at both ends
//   2  the render     — the frames at real positions: keys, spacers, order
//   3  the clamp      — hostile ranges, each with a positive control
//   4  the fault site — virtual.b's report site and the four configuration
//                       refusals, each with a control
package main

import std.io
import {Builder, Circuit, CircuitOptions, Component, Frame, Renderer, Serializer,
        Placement, Virtual, VirtualGeometry,
        VIRTUAL_MAX_WINDOW, VIRTUAL_INITIAL_ROWS} from latte
import {run} from latte.boundary

const ROWS: int = 50000
const ROW_HEIGHT: int = 32
const VIEWPORT: int = 640
const OVERSCAN: int = 4

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

fn joined(items: List<string>) -> string {
    var out: string = ""
    var first: bool = true
    for item: string in items {
        if !first { out = "{out} | " }
        out = "{out}{item}"
        first = false
    }
    return out
}

/// A `Placement` built field by field, so a suite can hand `sound()` one it
/// must REFUSE. Nothing in `virtual.b` produces these — that is the point.
fn hand_made(total: int, row_height: int, start: int, shown: int,
             top: int, bottom: int) -> Placement {
    var out: Placement = new Placement()
    out.total = total
    out.row_height = row_height
    out.start = start
    out.shown = shown
    out.top = top
    out.bottom = bottom
    return out
}

fn table() -> VirtualGeometry {
    var g: VirtualGeometry = new VirtualGeometry()
    g.total = ROWS
    g.row_height = ROW_HEIGHT
    g.overscan = OVERSCAN
    g.max_window = VIRTUAL_MAX_WINDOW
    return g
}

// ---------------------------------------------------------------- the walk

/// One pass over a run of scroll offsets, checking every rule at every one.
///
/// It carries its own counters instead of printing per position, because
/// 112,800 lines is not an expected output anybody reads — and the counts ARE the claim:
/// a sweep that silently exercised three positions would show up here as a 3.
pub class Walk {
    pub positions: int = 0
    /// A window whose arithmetic did not close.
    pub unsound: int = 0
    /// A window that did not hold every row the viewport shows.
    pub uncovered: int = 0
    /// A window past the cap.
    pub oversized: int = 0
    /// A pair of consecutive windows with a hole between them.
    pub gaps: int = 0
    /// A window whose start went backwards while scrolling down, or forwards
    /// while scrolling up.
    pub reversals: int = 0
    pub lowest: int = -1
    pub highest: int = -1
    /// The union of every window in this walk, kept as ONE interval: a window
    /// that neither overlaps nor abuts what has been covered so far cannot be
    /// merged into it, and that is a break. `breaks == 0` with the interval
    /// running 0..total-1 is the whole "no gap" sentence, said once, rather
    /// than inferred from the pairwise check plus monotonicity.
    pub covers_low: int = -1
    pub covers_high: int = -1
    pub breaks: int = 0

    pub fn init() {}

    pub fn describe() -> string {
        return "positions={self.positions} unsound={self.unsound} uncovered={self.uncovered} oversized={self.oversized} gaps={self.gaps} reversals={self.reversals} rows={self.lowest}..{self.highest} union={self.covers_low}..{self.covers_high} breaks={self.breaks}"
    }
}

/// Walk `from` to `to` in steps of `step` pixels, checking every rule.
///
/// `descending` says which way the starts are expected to move, and it is
/// checked rather than assumed: a geometry that answered the same window
/// whatever it was asked would pass every other rule in here.
fn walk(g: VirtualGeometry, from: int, to: int, step: int, descending: bool,
        into: Walk) {
    var previous: Placement = new Placement()
    var have_previous: bool = false
    var offset: int = from
    for true {
        let at: Placement = g.window_at(offset, VIEWPORT)
        into.positions += 1
        if !at.sound() { into.unsound += 1 }
        if at.shown > g.max_window { into.oversized += 1 }

        // Every row the viewport shows at this offset must be in the window.
        // Written as the two ends rather than a loop over the band: `holds` is
        // an interval test, so asking it for the first and the last visible row
        // is the same statement as asking it for each one, and 100,000
        // positions times a twenty-row band is two million calls that say
        // nothing the two ends do not.
        let first: int = offset / g.row_height
        var last: int = (offset + VIEWPORT - 1) / g.row_height
        if last > g.total - 1 { last = g.total - 1 }
        if first <= last {
            if !at.holds(first) || !at.holds(last) { into.uncovered += 1 }
        }

        if have_previous {
            if descending {
                if at.start > previous.start + previous.shown { into.gaps += 1 }
                if at.start < previous.start { into.reversals += 1 }
            } else {
                if previous.start > at.start + at.shown { into.gaps += 1 }
                if at.start > previous.start { into.reversals += 1 }
            }
        }
        previous = at
        have_previous = true

        if into.lowest < 0 || at.start < into.lowest { into.lowest = at.start }
        if at.shown > 0 {
            let end: int = at.start + at.shown - 1
            if end > into.highest { into.highest = end }
            if into.covers_low < 0 {
                into.covers_low = at.start
                into.covers_high = end
            } else if at.start > into.covers_high + 1 || end < into.covers_low - 1 {
                into.breaks += 1
            } else {
                if at.start < into.covers_low { into.covers_low = at.start }
                if end > into.covers_high { into.covers_high = end }
            }
        }

        if descending {
            if offset >= to { break }
            offset += step
            if offset > to { offset = to }
        } else {
            if offset <= to { break }
            offset -= step
            if offset < to { offset = to }
        }
    }
}

/// The first row a row-aligned offset must render, worked out from the
/// geometry and not from the renderer: the viewport starts at `row`, the
/// overscan reaches OVERSCAN rows above it, and 0 is the floor.
fn expected_start(row: int) -> int {
    var at: int = row - OVERSCAN
    if at < 0 { at = 0 }
    return at
}

/// And how many rows it must render: the band ends OVERSCAN rows past the last
/// visible one, and the collection is the ceiling.
fn expected_shown(row: int) -> int {
    var stop: int = row + VIEWPORT / ROW_HEIGHT + OVERSCAN
    if stop > ROWS { stop = ROWS }
    let size: int = stop - expected_start(row)
    if size < 0 { return 0 }
    return size
}

// ---------------------------------------------------------------- the frames

/// The region keys of a rendered `Virtual`, in frame order.
fn keys_of(b: Builder) -> List<string> {
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

/// The two spacer heights, read out of the attribute frames.
fn spacers_of(b: Builder) -> string {
    var top: string = "?"
    var bottom: string = "?"
    var seen: string = ""
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            attribute(_, name, value) => {
                if name == "data-latte-spacer" { seen = value }
                if name == "style" {
                    if seen == "top" { top = value }
                    if seen == "bottom" { bottom = value }
                }
            }
            _ => {}
        }
        index += 1
    }
    return "{top}/{bottom}"
}

/// A mounted 50,000-row table whose rows are `<td>` cells carrying the index.
fn mount_table(r: Renderer) -> Virtual {
    var list: Virtual = new Virtual()
    list.count = ROWS
    list.row_height = ROW_HEIGHT
    list.overscan = OVERSCAN
    list.class_name = "sheet"
    list.row = fn(b: Builder, index: int) {
        b.open(0, "div")
        b.attr(1, "class", "row")
        b.text(2, "row {index}")
        b.close()
    }
    r.mount(list)
    return list
}

// ---------------------------------------------------------- the circuit page

const CID: string = "0123456789abcdef0123"

/// A page whose only content is a virtual list, so the circuit has a component
/// id to address that is NOT the page's own.
pub class Sheet extends Component {
    pub rows: int = ROWS
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.component<Virtual>(1, fn(list: Virtual) {
            list.count = self.rows
            list.row_height = ROW_HEIGHT
            list.overscan = OVERSCAN
            list.row = fn(inner: Builder, index: int) { inner.text(0, "r{index}") }
        })
        b.close()
    }
}

fn attach_message() -> string {
    return "\{\"t\":\"attach\",\"c\":\"{CID}\",\"u\":\"/\"\}"
}

fn range_message(h: int, start: int, count: int) -> string {
    // The count rides on `c`, not `n`: `n` is the message sequence on EVERY
    // client message and is read before the kind, so a count on `n` would be
    // judged by the sequence check and "a range must be two non-negative
    // numbers" would never run. See wire.b's comment at the range decode.
    return "\{\"t\":\"range\",\"h\":{h},\"s\":{start},\"c\":{count}\}"
}

fn sheet_circuit(page: Component) -> Circuit {
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 1000000
    let made: Circuit = new Circuit(CID, options,
        fn(url: string) -> Option<Component> { return some(page) })
    made.guard = run
    made.open(0)
    made.accept(attach_message(), 1)
    let _: List<string> = made.take_outbox()
    return made
}

/// The mounted virtual list's component id, found the way the circuit finds
/// it: by asking the renderer what it mounted, never by assuming a number.
fn list_id(c: Circuit) -> int {
    for id: int in c.renderer.ids() {
        match c.renderer.component(id) {
            some(component) => {
                match component as? Virtual {
                    some(_) => { return id }
                    none => {}
                }
            }
            none => {}
        }
    }
    return -1
}

fn list_of(c: Circuit) -> Option<Virtual> {
    match c.renderer.component(list_id(c)) {
        some(component) => { return component as? Virtual }
        none => { return none }
    }
}

fn placement_of(c: Circuit) -> string {
    match list_of(c) {
        some(list) => { return list.placement.describe() }
        none => { return "no list" }
    }
}

fn last_log(c: Circuit) -> string {
    if c.log.len() == 0 { return "" }
    return c.log[c.log.len() - 1]
}

fn main() {
    var r: Report = new Report()
    io.println("== 1 the sweep: 50,000 rows, to the end and back ==")
    section_one(r)
    io.println("")
    io.println("== 2 the render: keys, order and spacers ==")
    section_two(r)
    io.println("")
    io.println("== 3 the clamp: a range is never believed ==")
    section_three(r)
    io.println("")
    io.println("== 4 every fault site in virtual.b ==")
    section_four(r)
    io.println("")
    io.println("== 5 the circuit hands a range to the list ==")
    section_five(r)
    io.println("")
    io.println("== 6 the four numbers the browser reporter reads ==")
    section_six(r)
    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}

// ============================================================== 1

fn section_one(r: Report) {
    let g: VirtualGeometry = table()
    let span: int = ROWS * ROW_HEIGHT
    let bottom_most: int = span - VIEWPORT

    // Every row offset, all the way down, then all the way back.
    var down: Walk = new Walk()
    walk(g, 0, bottom_most, ROW_HEIGHT, true, down)
    io.println("down, one row at a time:  {down.describe()}")
    var up: Walk = new Walk()
    walk(g, bottom_most, 0, ROW_HEIGHT, false, up)
    io.println("back, one row at a time:  {up.describe()}")

    // Every PIXEL at both ends, where the sub-row arithmetic and the two
    // clamps live. A row-aligned sweep never asks what happens when the
    // viewport straddles a row boundary, and that is most of the time.
    var head: Walk = new Walk()
    walk(g, 0, ROW_HEIGHT * 100, 1, true, head)
    io.println("every pixel, first 100 rows: {head.describe()}")
    var tail: Walk = new Walk()
    walk(g, bottom_most - ROW_HEIGHT * 100, bottom_most, 1, true, tail)
    io.println("every pixel, last 100 rows:  {tail.describe()}")

    // Past both ends: a client can report any offset it likes.
    var beyond: Walk = new Walk()
    walk(g, span, span + ROW_HEIGHT * 10, 1, true, beyond)
    io.println("every pixel past the end:    {beyond.describe()}")

    let total: int = down.positions + up.positions + head.positions +
                     tail.positions + beyond.positions
    io.println("scroll positions exercised: {total}")

    r.eqi("down: every position is sound", down.unsound, 0)
    r.eqi("down: every visible row is in the window", down.uncovered, 0)
    r.eqi("down: no window is over the cap", down.oversized, 0)
    r.eqi("down: no gap between consecutive windows", down.gaps, 0)
    r.eqi("down: the window never goes backwards", down.reversals, 0)
    r.eqi("down: it starts at row 0", down.lowest, 0)
    r.eqi("down: and reaches the last row", down.highest, ROWS - 1)

    r.eqi("back: every position is sound", up.unsound, 0)
    r.eqi("back: every visible row is in the window", up.uncovered, 0)
    r.eqi("back: no window is over the cap", up.oversized, 0)
    r.eqi("back: no gap between consecutive windows", up.gaps, 0)
    r.eqi("back: the window never goes forwards", up.reversals, 0)
    r.eqi("back: it returns to row 0", up.lowest, 0)
    r.eqi("back: having started at the last row", up.highest, ROWS - 1)

    // The check sentence itself: the union of every window on the way down is
    // one unbroken run, and it is exactly the table.
    r.eqi("down: the windows are one unbroken run", down.breaks, 0)
    r.eqi("down: covering row 0", down.covers_low, 0)
    r.eqi("down: through the last row", down.covers_high, ROWS - 1)
    r.eqi("back: the windows are one unbroken run", up.breaks, 0)
    r.eqi("back: covering row 0", up.covers_low, 0)
    r.eqi("back: through the last row", up.covers_high, ROWS - 1)

    r.eqi("first 100 rows, every pixel: sound", head.unsound, 0)
    r.eqi("first 100 rows, every pixel: covered", head.uncovered, 0)
    r.eqi("first 100 rows, every pixel: no gap", head.gaps, 0)
    r.eqi("last 100 rows, every pixel: sound", tail.unsound, 0)
    r.eqi("last 100 rows, every pixel: covered", tail.uncovered, 0)
    r.eqi("last 100 rows, every pixel: no gap", tail.gaps, 0)
    r.eqi("past the end: sound", beyond.unsound, 0)
    r.eqi("past the end: no gap", beyond.gaps, 0)

    r.yes("the sweep is the whole table, one row at a time, both ways",
        down.positions == ROWS - VIEWPORT / ROW_HEIGHT + 1 &&
        up.positions == down.positions)
    r.yes("and it exercised six figures of positions", total > 100000)

    // The window at the two ends, printed, so the numbers are in the expected output
    // rather than only inside a counter.
    let at_top: Placement = g.window_at(0, VIEWPORT)
    let at_bottom: Placement = g.window_at(bottom_most, VIEWPORT)
    io.println("at the top:    {at_top.describe()}")
    io.println("at the bottom: {at_bottom.describe()}")
    r.eq("the top window", at_top.describe(), "start=0 shown=24 top=0 bottom=1599232")
    r.eq("the bottom window", at_bottom.describe(),
        "start=49976 shown=24 top=1599232 bottom=0")
    r.eqi("the list is the same height at both ends", at_top.height(), at_bottom.height())
}

// ============================================================== 2

fn section_two(r: Report) {
    let renderer: Renderer = new Renderer()
    var list: Virtual = mount_table(renderer)

    // The static first window: a page is complete and scrollable before any
    // circuit attaches.
    match renderer.buffer(list.id()) {
        none => { r.eq("the list mounted", "no buffer", "a buffer") }
        some(buffer) => {
            let keys: List<string> = keys_of(buffer)
            io.println("static window: {list.placement.describe()}")
            io.println("static keys:   {keys.len()} rows, {keys[0]}..{keys[keys.len() - 1]}")
            io.println("static spacers: {spacers_of(buffer)}")
            r.eqi("the static window is the initial row count", keys.len(), VIRTUAL_INITIAL_ROWS)
            r.eq("and it starts at the top", "{keys[0]}", "0")
            r.eq("and the spacers size the rest of the list",
                spacers_of(buffer), "height:0px/height:1599360px")
        }
    }

    // A render sweep over the whole table. Every 50 rows down and back, with
    // every render's keys read out of the frames and checked exactly.
    var renders: int = 0
    var wrong_keys: int = 0
    var wrong_spacers: int = 0
    var duplicates: int = 0
    var out_of_order: int = 0
    var rows_rendered: int = 0
    var previous_start: int = -1
    var wrong_window: int = 0
    var moved_too_far: int = 0

    var pass: int = 0
    for pass < 2 {
        var step: int = 0
        for step <= ROWS {
            var row: int = step
            if pass == 1 { row = ROWS - step }
            let offset: int = row * ROW_HEIGHT
            let moved: bool = list.apply_scroll(offset, VIEWPORT)
            let _: int = renderer.flush()
            renders += 1
            let where: Placement = list.placement
            if !where.sound() { wrong_keys += 1 }

            match renderer.buffer(list.id()) {
                none => { wrong_keys += 1 }
                some(buffer) => {
                    let keys: List<string> = keys_of(buffer)
                    rows_rendered += keys.len()
                    if keys.len() != where.shown { wrong_keys += 1 }
                    var seen: Map<string, bool> = {}
                    var index: int = 0
                    for index < keys.len() {
                        if seen.contains_key(keys[index]) { duplicates += 1 }
                        seen[keys[index]] = true
                        if keys[index] != "{where.start + index}" { out_of_order += 1 }
                        index += 1
                    }
                    let want: string = "height:{where.top}px/height:{where.bottom}px"
                    if spacers_of(buffer) != want { wrong_spacers += 1 }
                }
            }

            // The window this offset MUST produce, derived from the geometry
            // rather than from what the renderer said. At a row-aligned offset
            // the viewport shows rows `row .. row + VIEWPORT/ROW_HEIGHT - 1`,
            // the overscan widens that band by OVERSCAN each way, and both
            // ends clamp to the collection. An earlier draft of this suite
            // asserted only that consecutive starts differed by the 50 rows
            // the scroll moved, which is FALSE at row 0 — the window there is
            // pinned at 0 and moves by 46 — and which a geometry that ignored
            // the overscan entirely would still satisfy.
            if where.start != expected_start(row) { wrong_window += 1 }
            if where.shown != expected_shown(row) { wrong_window += 1 }

            if previous_start >= 0 {
                let low: int = if where.start < previous_start { where.start } else { previous_start }
                let high: int = if where.start < previous_start { previous_start } else { where.start }
                // The window never travels further than the scroll did.
                if high - low > 50 { moved_too_far += 1 }
            }
            previous_start = where.start
            step += 50
        }
        pass += 1
    }

    io.println("renders: {renders}, rows rendered: {rows_rendered}")
    r.eqi("every render's keys are exactly its window", wrong_keys, 0)
    r.eqi("no row is rendered twice in one window", duplicates, 0)
    r.eqi("and they are in index order", out_of_order, 0)
    r.eqi("the spacers match every window", wrong_spacers, 0)
    r.eqi("every window is the one the geometry requires", wrong_window, 0)
    r.eqi("and the window never travels further than the scroll", moved_too_far, 0)
    r.eqi("the sweep rendered both ways over the whole table", renders, 2 * (ROWS / 50 + 1))
    r.yes("and rendered five figures of rows", rows_rendered > 10000)

    // The HTML at one position, in full, so the shape is in the expected output.
    let _2: bool = list.apply_range(1000, 3)
    let _3: int = renderer.flush()
    let writer: Serializer = new Serializer()
    match renderer.buffer(list.id()) {
        none => { r.eq("the list still has a buffer", "no", "yes") }
        some(buffer) => {
            let html: string = writer.component(buffer)
            io.println("html at row 1000, three rows:")
            io.println("  {html}")
            r.eq("the html", html,
                "<div class=\"sheet\" data-latte-virtual=\"0\" data-latte-rows=\"50000\" data-latte-row-height=\"32\" data-latte-overscan=\"4\"><div data-latte-spacer=\"top\" style=\"height:32000px\"></div><div class=\"row\">row 1000</div><div class=\"row\">row 1001</div><div class=\"row\">row 1002</div><div data-latte-spacer=\"bottom\" style=\"height:1567904px\"></div></div>")
            r.eqi("and the serializer raised nothing", writer.faults.len(), 0)
        }
    }

    // A range that lands on the window already rendered marks nothing. Without
    // this a trackpad reporting sixty times a second re-renders the list sixty
    // times for no change, and every other check in this file still passes.
    let again: bool = list.apply_range(1000, 3)
    r.no("the same range again moves nothing", again)
    r.eqi("and marks nothing dirty", renderer.pending(), 0)
    let elsewhere: bool = list.apply_range(1001, 3)
    r.yes("a different range does move", elsewhere)
    r.eqi("and marks exactly one component", renderer.pending(), 1)
    let _4: int = renderer.flush()
}

// ============================================================== 3

fn section_three(r: Report) {
    let g: VirtualGeometry = table()

    // Every hostile shape, and the honest request beside it.
    io.println("-- a range is clamped, never trusted")
    let cases: List<string> = ["negative start", "negative count",
        "start past the end", "count past the cap", "count past the end",
        "the largest int as a start", "the largest int as a count",
        "both the largest int"]
    var shown: List<string> = []
    shown.push(g.window(-5, 10).describe())
    shown.push(g.window(10, -5).describe())
    shown.push(g.window(ROWS + 1000, 10).describe())
    shown.push(g.window(0, 50000).describe())
    shown.push(g.window(ROWS - 3, 100).describe())
    shown.push(g.window(9223372036854775807, 10).describe())
    shown.push(g.window(10, 9223372036854775807).describe())
    shown.push(g.window(9223372036854775807, 9223372036854775807).describe())
    var index: int = 0
    for index < cases.len() {
        io.println("   {cases[index]}: {shown[index]}")
        index += 1
    }
    r.eq("a negative start becomes 0", shown[0], "start=0 shown=10 top=0 bottom=1599680")
    r.eq("a negative count becomes 0", shown[1], "start=10 shown=0 top=320 bottom=1599680")
    r.eq("a start past the end lands on the end", shown[2], "start=50000 shown=0 top=1600000 bottom=0")
    r.eq("a count past the cap is capped", shown[3], "start=0 shown=200 top=0 bottom=1593600")
    r.eq("a count past the end is trimmed", shown[4], "start=49997 shown=3 top=1599904 bottom=0")
    r.eq("the largest int as a start lands on the end", shown[5], "start=50000 shown=0 top=1600000 bottom=0")
    r.eq("the largest int as a count is capped", shown[6], "start=10 shown=200 top=320 bottom=1593280")
    r.eq("and both together", shown[7], "start=50000 shown=0 top=1600000 bottom=0")

    var unsound: int = 0
    let hostile: List<Placement> = [g.window(-5, 10), g.window(10, -5),
        g.window(ROWS + 1000, 10), g.window(0, 50000), g.window(ROWS - 3, 100),
        g.window(9223372036854775807, 10), g.window(10, 9223372036854775807),
        g.window(9223372036854775807, 9223372036854775807)]
    for at: Placement in hostile { if !at.sound() { unsound += 1 } }
    r.eqi("every clamped window is still sound", unsound, 0)

    // The cap bounds a count the collection would happily have allowed. It is
    // NOT a statement about the order of the two count-clamps: both are a
    // `min`, so they commute, and swapping them in `virtual.b` turns nothing
    // here red — which is how the claim that they did not commute was found
    // to be false. The clamp whose ORDER matters is `start`, and the largest
    // int as a start, above, is what holds it: unclamped, `total - at` goes
    // hugely negative and the count follows it down.
    r.eqi("the cap bounds a count the collection would have allowed",
        g.window(0, ROWS).shown, VIRTUAL_MAX_WINDOW)
    r.eqi("and the collection bounds a count the cap would have allowed",
        g.window(ROWS - 3, VIRTUAL_MAX_WINDOW).shown, 3)

    // The positive control: an honest range is answered exactly.
    let honest: Placement = g.window(500, 30)
    io.println("   an honest range: {honest.describe()}")
    r.eq("an honest range is answered exactly", honest.describe(),
        "start=500 shown=30 top=16000 bottom=1583040")

    // An empty collection, and a collection of one.
    var none_at_all: VirtualGeometry = new VirtualGeometry()
    none_at_all.total = 0
    var one: VirtualGeometry = new VirtualGeometry()
    one.total = 1
    io.println("   an empty list: {none_at_all.window(0, 10).describe()}")
    io.println("   a list of one: {one.window(0, 10).describe()}")
    r.eq("an empty list", none_at_all.window(0, 10).describe(), "start=0 shown=0 top=0 bottom=0")
    r.eq("a list of one", one.window(0, 10).describe(), "start=0 shown=1 top=0 bottom=0")
    r.yes("an empty list is sound", none_at_all.window(0, 10).sound())
    r.yes("and so is a list of one", one.window(0, 10).sound())
    r.yes("an empty list at a hostile offset is sound",
        none_at_all.window_at(9223372036854775807 / 64, VIEWPORT).sound())

    // `sound()` is asserted true all over this file and NEVER ONCE asserted
    // false, which means a `sound()` that answered true unconditionally would
    // pass every check here. It does now: one placement per clause, built by
    // hand, each of which must be refused, with the sound one beside them.
    io.println("-- a placement the arithmetic does not close")
    r.yes("the control: a placement whose arithmetic closes",
        hand_made(10, 32, 2, 3, 64, 160).sound())
    var wrong: List<string> = []
    var refused: int = 0
    let names: List<string> = ["the spacers do not add up", "a negative start",
        "a negative count", "a window past the end of the collection",
        "a negative top spacer", "a negative bottom spacer"]
    var probes: List<Placement> = []
    probes.push(hand_made(10, 32, 0, 2, 0, 0))
    probes.push(hand_made(10, 32, -1, 3, -32, 192))
    probes.push(hand_made(10, 32, 2, -1, 64, 288))
    probes.push(hand_made(10, 32, 8, 5, 256, -96))
    probes.push(hand_made(10, 32, 2, 3, -64, 288))
    probes.push(hand_made(10, 32, 2, 3, 448, -224))
    var index2: int = 0
    for index2 < probes.len() {
        if probes[index2].sound() { wrong.push(names[index2]) }
        else { refused += 1 }
        index2 += 1
    }
    io.println("   unsound placements refused: {refused} of {probes.len()}")
    r.eqi("every broken placement is refused", refused, 6)
    r.eq("and none of them was let through", joined(wrong), "")

    // A hostile VIEWPORT is the second way to reach the cap, and it does not
    // go through `window` from the outside — `window_at` computes a row count
    // from the viewport and hands it on. A client that claims a window
    // 9 quintillion pixels tall must get 200 rows, not 50,000.
    let vast: Placement = g.window_at(0, 9223372036854775807)
    io.println("   a viewport of the largest int: {vast.describe()}")
    r.eqi("a hostile viewport is capped like a hostile count", vast.shown, VIRTUAL_MAX_WINDOW)
    r.yes("and the window it answers is still sound", vast.sound())
    // The control: an honest viewport is answered exactly, so the line above
    // is the cap doing the work and not `window_at` refusing everything.
    r.eqi("an honest viewport is not capped", g.window_at(0, VIEWPORT).shown, 24)

    // A hostile viewport at the BOTTOM of the list is a different failure from
    // a hostile viewport at the top, and only one line stands in front of it.
    // `window_at` computes `offset + height - 1`; with `offset` at the end of a
    // 1,600,000-pixel list and `height` the largest int, that add OVERFLOWS —
    // undefined, and free to answer differently in the two backends. The clamp
    // of `height` to the list's own span is what stops it, and nothing reached
    // it before: disabling that line left this suite at 140 checks, 0 bad,
    // because `window_at(0, ...)` above starts the add at zero.
    let far: Placement = g.window_at(ROWS * ROW_HEIGHT, 9223372036854775807)
    io.println("   the largest viewport at the end of the list: {far.describe()}")
    r.eq("a viewport that would overflow the add is bounded by the list",
         far.describe(), "start=49996 shown=4 top=1599872 bottom=0")
    r.yes("and the window it answers is sound", far.sound())
    // The control: an honest viewport at the same offset answers the same four
    // rows, so the line above is the clamp doing the work and not the end of
    // the list refusing everything.
    r.eq("an honest viewport at the same offset answers the same window",
         g.window_at(ROWS * ROW_HEIGHT, VIEWPORT).describe(), far.describe())

    // A geometry that cannot be laid out answers NO window rather than a wrong
    // one. A negative row height is the shape that used to escape: `place`
    // multiplied it out and produced negative spacers, which is a placement no
    // page can hold, from a public method, with nothing saying it had failed.
    var upside_down: VirtualGeometry = new VirtualGeometry()
    upside_down.total = 10
    upside_down.row_height = -1
    io.println("   a negative row height, window(5,3): {upside_down.window(5, 3).describe()}")
    io.println("   a negative row height, window_at:   {upside_down.window_at(500, VIEWPORT).describe()}")
    r.eq("a negative row height answers no window at all",
        upside_down.window(5, 3).describe(), "start=0 shown=0 top=0 bottom=0")
    r.eq("and no window from a scroll either",
        upside_down.window_at(500, VIEWPORT).describe(), "start=0 shown=0 top=0 bottom=0")
    r.yes("and what it answers is sound", upside_down.window(5, 3).sound())
    var over_scanned: VirtualGeometry = new VirtualGeometry()
    over_scanned.total = 10
    over_scanned.overscan = -1
    r.eq("so does a negative overscan", over_scanned.window(5, 3).describe(),
        "start=0 shown=0 top=0 bottom=320")
    r.yes("and it is sound too", over_scanned.window(5, 3).sound())
    // The positive control: one legal parameter apart, the same request is
    // answered exactly. Without it every line above would pass on a `window`
    // that had simply stopped answering anything.
    var upright: VirtualGeometry = new VirtualGeometry()
    upright.total = 10
    upright.row_height = 1
    r.eq("the control: a legal row height answers the range",
        upright.window(5, 3).describe(), "start=5 shown=3 top=5 bottom=2")

    // And a misconfigured COMPONENT accepts no range: it must not mark itself
    // dirty for a window it is not going to render.
    let broken_renderer: Renderer = new Renderer()
    var broken_list: Virtual = new Virtual()
    broken_list.count = 100
    broken_list.row_height = 0
    broken_list.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    broken_renderer.mount(broken_list)
    let _b1: int = broken_renderer.flush()
    r.no("a range on a misconfigured list moves nothing", broken_list.apply_range(10, 5))
    r.no("nor does a scroll", broken_list.apply_scroll(320, VIEWPORT))
    r.eqi("and it marks nothing dirty", broken_renderer.pending(), 0)
    // The control: the same list with a row height accepts the same range.
    let fixed_renderer: Renderer = new Renderer()
    var fixed_list: Virtual = new Virtual()
    fixed_list.count = 100
    fixed_list.row_height = 32
    fixed_list.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    fixed_renderer.mount(fixed_list)
    let _b2: int = fixed_renderer.flush()
    r.yes("the control: a configured list accepts it", fixed_list.apply_range(10, 5))
    r.eqi("and marks exactly itself", fixed_renderer.pending(), 1)

    // A collection that SHRANK under a window reported against the old length.
    // A filter that removed rows while the user was at the bottom is the
    // ordinary case; a window addressing rows that no longer exist is what
    // `on_params_set` re-clamps.
    let renderer: Renderer = new Renderer()
    var list: Virtual = mount_table(renderer)
    let _1: bool = list.apply_range(49900, 50)
    let _2: int = renderer.flush()
    io.println("   at the bottom of 50,000: {list.placement.describe()}")
    list.count = 100
    list.notify()
    let _3: int = renderer.flush()
    io.println("   after the list shrank to 100: {list.placement.describe()}")
    r.eq("a window is re-clamped when the collection shrinks",
        list.placement.describe(), "start=100 shown=0 top=3200 bottom=0")
    r.yes("and it is still sound", list.placement.sound())
    match renderer.buffer(list.id()) {
        none => { r.eq("it still renders", "no", "yes") }
        some(buffer) => {
            r.eqi("and renders no rows", keys_of(buffer).len(), 0)
            r.eq("with the spacers summing to the new height",
                spacers_of(buffer), "height:3200px/height:0px")
        }
    }
}

// ============================================================== 4

/// One report site or one configuration refusal, one trip, one control.
pub class VSite {
    pub site: string = ""
    pub name: string = ""
    pub trip: fn() -> string = fn() -> string { return "" }
    pub want: string = ""
    pub control: fn() -> string = fn() -> string { return "" }
    pub made: fn() -> string = fn() -> string { return "" }
    pub produced: string = ""

    pub fn init(site: string, name: string, trip: fn() -> string, want: string,
                control: fn() -> string, made: fn() -> string, produced: string) {
        self.site = site
        self.name = name
        self.trip = trip
        self.want = want
        self.control = control
        self.made = made
        self.produced = produced
    }
}

const V_RENDER: string = "render / a misconfigured list renders nothing and says why"

/// A `Virtual` with one parameter broken, rendered. Answers its faults.
fn broken(height: int, overscan: int, cap: int, count: int) -> string {
    let renderer: Renderer = new Renderer()
    var list: Virtual = new Virtual()
    list.count = count
    list.row_height = height
    list.overscan = overscan
    list.max_window = cap
    list.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    renderer.mount(list)
    return joined(list.faults)
}

/// The same, but answering the HTML it produced.
fn broken_html(height: int, overscan: int, cap: int, count: int) -> string {
    let renderer: Renderer = new Renderer()
    var list: Virtual = new Virtual()
    list.count = count
    list.row_height = height
    list.overscan = overscan
    list.max_window = cap
    list.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    renderer.mount(list)
    return renderer.html()
}

/// What a SOUND three-row list renders, for a given overscan.
///
/// It is a function of the overscan because the element carries it: the
/// browser reporter needs the author's number to compute the same band the
/// server would, and a positive control whose overscan differed from the case
/// beside it would be comparing two different pages.
fn sound_html(overscan: int) -> string {
    return "<div data-latte-virtual=\"0\" data-latte-rows=\"3\" data-latte-row-height=\"10\" data-latte-overscan=\"{overscan}\"><div data-latte-spacer=\"top\" style=\"height:0px\"></div>012<div data-latte-spacer=\"bottom\" style=\"height:0px\"></div></div>"
}

fn virtual_sites() -> List<VSite> {
    var out: List<VSite> = []

    out.push(new VSite(V_RENDER, "a row height of zero",
        fn() -> string { return broken(0, 4, 200, 3) },
        "a virtual list needs a positive row height, not 0",
        fn() -> string { return broken(10, 4, 200, 3) },
        fn() -> string { return broken_html(10, 4, 200, 3) }, sound_html(4)))

    out.push(new VSite(V_RENDER, "a negative row height",
        fn() -> string { return broken(-1, 4, 200, 3) },
        "a virtual list needs a positive row height, not -1",
        fn() -> string { return broken(10, 4, 200, 3) },
        fn() -> string { return broken_html(10, 4, 200, 3) }, sound_html(4)))

    out.push(new VSite(V_RENDER, "a negative overscan",
        fn() -> string { return broken(10, -1, 200, 3) },
        "a virtual list cannot overscan -1 rows",
        fn() -> string { return broken(10, 0, 200, 3) },
        fn() -> string { return broken_html(10, 0, 200, 3) }, sound_html(0)))

    out.push(new VSite(V_RENDER, "a window cap of zero",
        fn() -> string { return broken(10, 4, 0, 3) },
        "a virtual list needs a positive window cap, not 0",
        fn() -> string { return broken(10, 4, 1, 3) },
        fn() -> string { return broken_html(10, 4, 200, 3) }, sound_html(4)))

    out.push(new VSite(V_RENDER, "a negative row count",
        fn() -> string { return broken(10, 4, 200, -2) },
        "a virtual list cannot hold -2 rows",
        fn() -> string { return broken(10, 4, 200, 0) },
        fn() -> string { return broken_html(10, 4, 200, 3) }, sound_html(4)))

    out.push(new VSite(V_RENDER, "every parameter wrong at once",
        fn() -> string { return broken(0, -1, 0, -2) },
        "a virtual list needs a positive row height, not 0 | a virtual list cannot overscan -1 rows | a virtual list needs a positive window cap, not 0 | a virtual list cannot hold -2 rows",
        fn() -> string { return broken(10, 4, 200, 3) },
        fn() -> string { return broken_html(10, 4, 200, 3) }, sound_html(4)))

    return move out
}

fn section_four(r: Report) {
    var reached: Map<string, int> = {}
    for probe: VSite in virtual_sites() {
        let raised: string = probe.trip()
        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {raised}")
        r.eq("{probe.name}: the exact fault", raised, probe.want)
        r.eq("{probe.name}: the control raises nothing", probe.control(), "")
        r.eq("{probe.name}: and the control rendered a list", probe.made(), probe.produced)
        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    // A refused list renders an EMPTY marked element, not a wrong page. The
    // fault list alone cannot tell you that: a component that raised the right
    // fault and then laid out 50,000 rows at the wrong offset would read the
    // same here.
    let refused: string = broken_html(0, 4, 200, 3)
    io.println("a refused list renders: {refused}")
    r.eq("a refused list renders an empty marked element", refused,
        "<div class=\"latte-virtual latte-virtual-refused\"></div>")

    // And a refused list answers no window at all, rather than a wrong one.
    var bad: VirtualGeometry = new VirtualGeometry()
    bad.total = 10
    bad.row_height = 0
    r.eq("a zero row height answers an empty window",
        bad.window_at(500, VIEWPORT).describe(), "start=0 shown=0 top=0 bottom=0")
    r.no("and the geometry says it is not ok", bad.ok())

    // `ok()` and `problems()` are two spellings of one rule — `window` asks the
    // cheap one on every call and an author reads the sentences from the other.
    // Two spellings drift. This is the check that they have not: over a table
    // that turns each parameter good and bad in turn, the fast predicate must
    // answer exactly "problems() is empty".
    var disagreements: int = 0
    var tried: int = 0
    let heights: List<int> = [-1, 0, 1, 32]
    let scans: List<int> = [-1, 0, 4]
    let caps: List<int> = [-1, 0, 1, 200]
    let totals: List<int> = [-1, 0, 1, 50000]
    for height: int in heights {
        for scan: int in scans {
            for cap: int in caps {
                for rows: int in totals {
                    var probe: VirtualGeometry = new VirtualGeometry()
                    probe.row_height = height
                    probe.overscan = scan
                    probe.max_window = cap
                    probe.total = rows
                    tried += 1
                    if probe.ok() != (probe.problems().len() == 0) { disagreements += 1 }
                    // And whatever it answers for a hostile range is sound,
                    // whether the configuration is legal or not.
                    if !probe.window(9223372036854775807, 9223372036854775807).sound() {
                        disagreements += 1
                    }
                }
            }
        }
    }
    io.println("configurations tried: {tried}")
    r.eqi("ok() and problems() agree on every configuration", disagreements, 0)
    r.eqi("and the table turned each parameter good and bad", tried, 192)

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in virtual.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in virtual.b has a case", names.len(), 1)
}

// ============================================================== 5

fn section_five(r: Report) {
    // An honest range: the client says where it is looking and the list
    // renders that slice. This is the seam the first agent could not close —
    // `wire.b` decoded a range and `circuit.b` clamped it, and nothing
    // rendered anything.
    let c: Circuit = sheet_circuit(new Sheet())
    let vid: int = list_id(c)
    io.println("the list mounted at component {vid}")
    r.yes("the page mounted a virtual list", vid > 0)
    r.eq("and it starts on the static first window", placement_of(c),
        "start=0 shown=20 top=0 bottom=1599360")

    c.accept(range_message(vid, 1000, 30), 2)
    io.println("after a range of 1000+30: {placement_of(c)}")
    io.println("   the log says: {last_log(c)}")
    r.eq("an honest range moves the window", placement_of(c),
        "start=1000 shown=30 top=32000 bottom=1567040")
    r.eq("and the circuit says so", last_log(c),
        "range 1000+30 on list {vid} -> start=1000 shown=30 top=32000 bottom=1567040")
    r.eqi("and one batch went out", c.take_outbox().len(), 1)
    r.no("and the circuit is alive", c.ending())

    // The same range again renders nothing. A trackpad reports one range per
    // animation frame while a finger rests on it; without this the list
    // re-renders sixty times a second and every other check here still passes.
    c.accept(range_message(vid, 1000, 30), 3)
    r.eq("the same range again changes nothing", last_log(c),
        "range 1000+30 on list {vid} -> start=1000 shown=30 top=32000 bottom=1567040 (unchanged)")
    r.eqi("and sends no batch", c.take_outbox().len(), 0)

    // A range that runs off the end is TRIMMED, not refused: a list that
    // shrank under the user is ordinary, and ending the session for it would
    // be a framework killing connections over a race it caused.
    c.accept(range_message(vid, 49990, 200), 4)
    io.println("a range past the end: {placement_of(c)}")
    r.eq("a range past the end is trimmed to what is there", placement_of(c),
        "start=49990 shown=10 top=1599680 bottom=0")
    r.no("and the circuit is still alive", c.ending())
    r.eqi("and it rendered", c.take_outbox().len(), 1)

    // A range naming the PAGE, which is a component but not a list.
    c.accept(range_message(0, 0, 10), 5)
    io.println("   a range on the page: {last_log(c)}")
    r.eq("a range on a component that is not a list is logged, not obeyed",
        last_log(c), "range 0+10 on 0, which is not a virtual list")
    r.no("and the circuit survives it", c.ending())
    r.eqi("and nothing went out", c.take_outbox().len(), 0)
    r.eq("and the window did not move", placement_of(c),
        "start=49990 shown=10 top=1599680 bottom=0")

    // A range naming an id nothing mounted.
    c.accept(range_message(4242, 0, 10), 6)
    io.println("   a range on nothing: {last_log(c)}")
    r.eq("a range on an unmounted id is logged, not obeyed", last_log(c),
        "range 0+10 on 4242, which is not mounted")
    r.no("and the circuit survives that too", c.ending())
    r.eqi("and nothing went out either", c.take_outbox().len(), 0)

    // Over the WIRE cap, which is the other cap and the one that ends the
    // circuit. `CircuitOptions.max_window` is 200 and so is the renderer's, so
    // 201 is the first row over both.
    let over: Circuit = sheet_circuit(new Sheet())
    let over_id: int = list_id(over)
    over.accept(range_message(over_id, 0, 201), 2)
    io.println("   a range over the cap: {over.take_outbox().join("")}")
    r.yes("a range over the wire cap ends the circuit", over.ending())
    r.eq("with the reason on the wire", over.end_reason(), "limit")

    // The control beside it: one row under the cap is answered, so the line
    // above is the cap and not the circuit refusing every range.
    let under: Circuit = sheet_circuit(new Sheet())
    let under_id: int = list_id(under)
    under.accept(range_message(under_id, 0, 200), 2)
    r.no("the control: a range exactly at the cap is answered", under.ending())
    r.eq("and the renderer honoured all 200 rows", placement_of(under),
        "start=0 shown=200 top=0 bottom=1593600")

    // A hostile start, over the wire, through the whole path.
    let hostile: Circuit = sheet_circuit(new Sheet())
    let hostile_id: int = list_id(hostile)
    hostile.accept(range_message(hostile_id, 9223372036854775807, 10), 2)
    io.println("   a range starting at the largest int: {placement_of(hostile)}")
    r.eq("the largest int as a start is clamped to the end", placement_of(hostile),
        "start=50000 shown=0 top=1600000 bottom=0")
    r.no("and the circuit is alive", hostile.ending())
    r.yes("and the window it landed on is sound", hostile_placement_sound(hostile))
}

fn hostile_placement_sound(c: Circuit) -> bool {
    match list_of(c) {
        some(list) => { return list.placement.sound() }
        none => { return false }
    }
}

// ============================================================== 6
//
// The element is the whole contract between `virtual.b` and `js/latte.js`.
// The client cannot ask the server what the geometry is — there is no message
// for it and `hello` carries three fields — so every number `window_at` needs
// has to be readable off the DOM, and each has to be readable as ITSELF.
//
// Every number here is deliberately different from every other and from the
// defaults, so an attribute that carried the wrong one of the four would show
// up as a wrong value rather than as a coincidence. With rows=7,
// row_height=13, overscan=12 there is no pair that could be swapped without
// the string changing.

fn section_six(r: Report) {
    let renderer: Renderer = new Renderer()
    var list: Virtual = new Virtual()
    list.count = 7
    list.row_height = 13
    list.overscan = 12
    list.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    renderer.mount(list)
    let html: string = renderer.html()
    io.println("the reporter's element: {html}")
    r.eq("all four numbers are on the element", html,
        "<div data-latte-virtual=\"0\" data-latte-rows=\"7\" data-latte-row-height=\"13\" data-latte-overscan=\"12\"><div data-latte-spacer=\"top\" style=\"height:0px\"></div>0123456<div data-latte-spacer=\"bottom\" style=\"height:0px\"></div></div>")

    // The overscan is the author's and it MOVES. A list rendered with a
    // different one must say so, or a client reading the attribute would
    // compute the same band for two lists that are not the same list.
    var wider: Virtual = new Virtual()
    wider.count = 7
    wider.row_height = 13
    wider.overscan = 1
    wider.row = fn(b: Builder, index: int) { b.text(0, "{index}") }
    let second: Renderer = new Renderer()
    second.mount(wider)
    r.yes("a different overscan renders a different element",
          second.html().contains("data-latte-overscan=\"1\""))
    r.no("and not the first one's number",
         second.html().contains("data-latte-overscan=\"12\""))
}
