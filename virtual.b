// Virtualised lists: a `Virtual` component that renders a window of rows
// instead of the whole collection, plus the geometry that keeps the window
// honest.
//
// The parent gives `count` and a `row(b, index)` closure instead of the
// collection itself, so the cost is the same for 50 rows or 50,000.
// `latte.js` reports which rows are visible, at most once per animation
// frame, and the server always re-clamps that range rather than trusting
// it. A static render still emits the first window and both spacers, so the
// page is complete and scrollable before any client script runs.
//
// The invariant every clamp here exists to hold:
//
//     top + shown * row_height + bottom == total * row_height
//
// A window that satisfies it has no gap and no overlap in the page — the
// scrollbar is the height of the whole list, and the rendered rows sit at
// exactly the offset their indices say. `Placement.sound()` is that
// assertion; `tests/w6_virtual.b` checks it at every scroll position of a
// 50,000-row table, down and back.
//
// No I/O here: this is geometry and clamping only.
package latte

import std.fmt

/// The default cap on a window, matching `CircuitOptions.max_window`.
///
/// It is repeated rather than shared because `circuit.b` is the wire's cap —
/// it ends the circuit for a range that asks for more — and this is the
/// renderer's, which silently trims. Two different jobs: one refuses a
/// hostile message, the other bounds what any message can cost. A single
/// constant would make one of them wrong the first time somebody tuned the
/// other.
pub const VIRTUAL_MAX_WINDOW: int = 200

/// How many rows a page renders before a client has reported anything.
pub const VIRTUAL_INITIAL_ROWS: int = 20

// ============================================================== placement

/// Where a window sits: which rows, and how tall the space above and below is.
pub class Placement {
    /// The first row index rendered.
    pub start: int = 0
    /// How many rows are rendered.
    pub shown: int = 0
    /// The spacer above, in pixels.
    pub top: int = 0
    /// The spacer below, in pixels.
    pub bottom: int = 0
    /// The rows in the collection.
    pub total: int = 0
    /// Pixels per row.
    pub row_height: int = 0

    pub fn init() {}

    /// The last row index rendered, or `start - 1` for an empty window.
    pub fn last() -> int { return self.start + self.shown - 1 }

    /// The whole list's height in pixels.
    pub fn height() -> int { return self.total * self.row_height }

    /// The invariant, as a question.
    ///
    /// Every clamp in this file has to keep this true, so it is written once
    /// and asserted rather than re-derived at each call site. A `Placement`
    /// that answers false is a page whose scrollbar and whose rows disagree.
    pub fn sound() -> bool {
        if self.start < 0 || self.shown < 0 { return false }
        if self.start + self.shown > self.total { return false }
        if self.top < 0 || self.bottom < 0 { return false }
        // An EMPTY window is sound wherever it sits. `window(10, 0)` — a client
        // reporting that nothing is visible while the user is at row 10 — is an
        // ordinary message, and the placement it produces (top = 320,
        // bottom = the rest) sizes the scrollbar correctly and renders no rows.
        // An empty window's `start` does not have to be 0 or `total`.
        return self.top + self.shown * self.row_height + self.bottom == self.height()
    }

    /// Whether row `index` is inside this window.
    pub fn holds(index: int) -> bool {
        return index >= self.start && index < self.start + self.shown
    }

    pub fn describe() -> string {
        return "start={self.start} shown={self.shown} top={self.top} bottom={self.bottom}"
    }
}

// ============================================================== the geometry

/// The fixed-height window arithmetic, with every input treated as hostile.
///
/// Separate from the component because it is the half a test can sweep a
/// million times, and because the circuit needs to clamp a range before it has
/// anything to render it into.
pub class VirtualGeometry {
    /// Rows in the collection.
    pub total: int = 0
    /// Pixels per row. Must be positive; `problems()` says so.
    pub row_height: int = 32
    /// Extra rows rendered above and below the visible band.
    pub overscan: int = 4
    /// The hard cap on a window.
    pub max_window: int = VIRTUAL_MAX_WINDOW

    pub fn init() {}

    /// Everything wrong with this configuration, by name.
    ///
    /// These are the AUTHOR's numbers, not the client's, which is why they are
    /// refused rather than clamped: a row height of zero is a page that cannot
    /// be laid out, and quietly substituting 32 would hide the mistake in a
    /// list that scrolls almost right.
    pub fn problems() -> List<string> {
        var out: List<string> = []
        if self.row_height <= 0 {
            out.push("a virtual list needs a positive row height, not {self.row_height}")
        }
        if self.overscan < 0 {
            out.push("a virtual list cannot overscan {self.overscan} rows")
        }
        if self.max_window <= 0 {
            out.push("a virtual list needs a positive window cap, not {self.max_window}")
        }
        if self.total < 0 {
            out.push("a virtual list cannot hold {self.total} rows")
        }
        return move out
    }

    /// Whether this configuration can be laid out at all.
    ///
    /// The same conditions `problems()` names, without building the sentences —
    /// `window()` asks this on every call and the sweep in `tests/w6_virtual.b`
    /// makes ~113,000 of them. Two spellings of one rule can drift, so § 4 of
    /// that suite asserts `ok() == (problems().len() == 0)` over a table of
    /// configurations rather than trusting that they were kept in step.
    pub fn ok() -> bool {
        return self.row_height > 0 && self.overscan >= 0 &&
               self.max_window > 0 && self.total >= 0
    }

    /// A window from an UNTRUSTED `(start, count)`.
    ///
    /// Only one of the three clamps below is order-dependent:
    ///
    ///   1. `start` into `[0, total]` **first, and this is the load-bearing
    ///      one**. Everything after it computes `total - at`, so an unclamped
    ///      `start = 9223372036854775807` makes `room` hugely negative, the
    ///      count clamps down to it, and `place` multiplies a nonsense size by
    ///      the row height. `tests/w6_virtual.b` § 3 pins that with the
    ///      largest int as a start.
    ///   2. `count` into `[0, max_window]`;
    ///   3. `count` into what is left of the collection.
    ///
    /// **2 and 3 commute.** Both are a `min`, so the result is
    /// `min(count, max_window, room)` whichever runs first. They are written
    /// cap-first because the cheap bound reads better before the derived one,
    /// and that is taste, not a rule.
    pub fn window(start: int, count: int) -> Placement {
        // A configuration that cannot be laid out has no correct window, and
        // the arithmetic below would answer a wrong one rather than none: a
        // row height of -1 makes `top` and `bottom` negative, which is a
        // placement no page can hold. `problems()` is where an author reads
        // WHY; this is the guard that stops a broken geometry answering
        // numbers to a caller who never asked.
        if !self.ok() { return self.nothing() }

        var at: int = start
        if at < 0 { at = 0 }
        if at > self.total { at = self.total }

        var size: int = count
        if size < 0 { size = 0 }
        if size > self.max_window { size = self.max_window }
        let room: int = self.total - at
        if size > room { size = room }

        return self.place(at, size)
    }

    /// A window from a scroll offset and a viewport height, both untrusted.
    ///
    /// This is what the client's reporter computes and what the server
    /// recomputes rather than trusting: `latte.js` sends the range it worked
    /// out, and a range is only ever a hint about where the user is looking.
    pub fn window_at(scroll_top: int, viewport: int) -> Placement {
        if !self.ok() { return self.nothing() }
        var offset: int = scroll_top
        if offset < 0 { offset = 0 }
        let span: int = self.total * self.row_height
        if offset > span { offset = span }
        var height: int = viewport
        if height < 0 { height = 0 }
        // A viewport taller than the whole list is not a hostile number, it is
        // a short list in a tall window; it is bounded here so the row count
        // below cannot be, and the window cap catches the hostile case.
        if height > span { height = span }

        let first: int = offset / self.row_height
        var last: int = first
        if height > 0 { last = (offset + height - 1) / self.row_height }

        var at: int = first - self.overscan
        if at < 0 { at = 0 }
        var stop: int = last + 1 + self.overscan
        if stop > self.total { stop = self.total }
        var size: int = stop - at
        if size < 0 { size = 0 }
        return self.window(at, size)
    }

    /// The window a page renders before any client has said anything.
    pub fn first_window(rows: int) -> Placement {
        return self.window(0, rows)
    }

    /// The placement of a geometry that cannot be laid out: no rows, and a
    /// list whose height is the best statement still available. Clamped to
    /// non-negative so it satisfies `Placement.sound()` — an answer that is
    /// itself unsound would fail the caller twice.
    fn nothing() -> Placement {
        var rows: int = self.total
        if rows < 0 { rows = 0 }
        var height: int = self.row_height
        if height < 0 { height = 0 }
        var out: Placement = new Placement()
        out.total = rows
        out.row_height = height
        out.bottom = rows * height
        return out
    }

    fn place(at: int, size: int) -> Placement {
        var out: Placement = new Placement()
        out.total = self.total
        out.row_height = self.row_height
        out.start = at
        out.shown = size
        out.top = at * self.row_height
        out.bottom = (self.total - at - size) * self.row_height
        return out
    }
}

// ============================================================== the component

/// A list that renders a window of its rows.
///
/// The row markup is child content — `row(b, index)` — so a `<Virtual>` in
/// markup compiles to the same `fn(Builder)` shape every other child-content
/// component uses. The rows go in a KEYED region, keyed by index, so scrolling
/// moves the rows the applier already has instead of rebuilding them.
///
/// It carries no items. A collection of 50,000 rows would be copied into this
/// component's parameters on every parent render; instead the parent supplies
/// `count` and a closure that renders row `i`, which is the only shape that
/// costs the same for 50 rows and 50,000.
pub class Virtual extends Component {
    /// How many rows the collection holds.
    pub count: int = 0
    /// Pixels per row. Fixed in v1.
    pub row_height: int = 32
    /// Extra rows above and below the visible band.
    pub overscan: int = 4
    /// The cap on one window.
    pub max_window: int = VIRTUAL_MAX_WINDOW
    /// How many rows to render before a client has reported a range.
    pub initial_rows: int = VIRTUAL_INITIAL_ROWS
    /// Renders one row. The second argument is the row's index.
    pub row: fn(Builder, int) = fn(b: Builder, index: int) {}
    /// A class for the scrolling element, so an application can size it.
    pub class_name: string = ""

    /// The window on the page right now.
    pub placement: Placement = new Placement()
    /// Configuration refused at render time, by name.
    pub faults: List<string> = []
    /// Whether a client has reported a range yet.
    pub attached: bool = false

    pub fn init() {}

    /// The geometry this component's parameters describe.
    pub fn geometry() -> VirtualGeometry {
        var out: VirtualGeometry = new VirtualGeometry()
        out.total = self.count
        out.row_height = self.row_height
        out.overscan = self.overscan
        out.max_window = self.max_window
        return out
    }

    /// A range reported by a client. Untrusted, clamped, and it marks this
    /// component — and only this component — for re-render.
    ///
    /// Answers whether the window MOVED. A range that lands on the window
    /// already rendered marks nothing, because a client that reports a range
    /// every animation frame while a finger rests on a trackpad would
    /// otherwise re-render the list sixty times a second for no change.
    pub fn apply_range(start: int, count: int) -> bool {
        let geometry: VirtualGeometry = self.geometry()
        if !geometry.ok() { return false }
        let next: Placement = geometry.window(start, count)
        self.attached = true
        if next.start == self.placement.start && next.shown == self.placement.shown {
            return false
        }
        self.placement = next
        self.notify()
        return true
    }

    /// The same, from a scroll offset and a viewport height.
    pub fn apply_scroll(scroll_top: int, viewport: int) -> bool {
        let geometry: VirtualGeometry = self.geometry()
        if !geometry.ok() { return false }
        let next: Placement = geometry.window_at(scroll_top, viewport)
        return self.apply_range(next.start, next.shown)
    }

    pub override fn on_params_set() {
        // The collection can shrink under a window that was reported against
        // the old length — a filter that removed rows while the user was at
        // the bottom is the ordinary case, not an attack. Re-clamping here is
        // what stops the next render addressing rows that no longer exist.
        let geometry: VirtualGeometry = self.geometry()
        // A misconfigured list KEEPS the window it had rather than losing it.
        // The placement is not rendered while the configuration is broken —
        // `render` refuses on the same condition, `problems()` non-empty,
        // which § 4 of the suite asserts is exactly `!ok()` — so nothing wrong
        // reaches the page, and the user's scroll position survives a
        // parameter that was briefly wrong.
        if !geometry.ok() { return }
        if self.attached {
            self.placement = geometry.window(self.placement.start, self.placement.shown)
        } else {
            self.placement = geometry.first_window(self.initial_rows)
        }
    }

    pub override fn render(b: Builder) {
        self.faults.clear()
        let geometry: VirtualGeometry = self.geometry()
        let problems: List<string> = geometry.problems()
        if problems.len() > 0 {
            for problem: string in problems { self.faults.push(problem) }
            // A misconfigured list renders NOTHING rather than a wrong page.
            // The faults are on the component, where a host reads them; an
            // empty element is what the reader sees, and an empty element is
            // honest about a list that could not be laid out.
            b.open(0, "div")
            b.attr(1, "class", "latte-virtual latte-virtual-refused")
            b.close()
            return
        }
        // The window is NOT re-clamped here. `on_params_set` is the single
        // place that settles it, and it runs before every render on every
        // path: `Renderer.mount` (render.b), `Renderer.render_now` (the dirty
        // pass) and `Builder.render_child` (a parent rendering this child) all
        // call it immediately before `render_root`. A second clamp here would
        // be a line no input could reach, which is worse than none — a reader
        // would believe the case was handled twice.
        let where: Placement = self.placement

        b.open(0, "div")
        if self.class_name != "" { b.attr(1, "class", self.class_name) }
        // The four attributes the browser reporter reads. They are DATA and
        // never a name: the client sends the id back and latte looks it up, so
        // nothing on the wire is ever interpreted as a name.
        b.attr(2, "data-latte-virtual", "{self.id()}")
        b.attr(3, "data-latte-rows", "{self.count}")
        b.attr(4, "data-latte-row-height", "{self.row_height}")
        // The FOURTH number the reporter needs, and it has to be on the
        // element because the client cannot derive it. `window_at` adds the
        // overscan on both sides of the visible band, and the client is the
        // end that computes the band — so a client that guessed 4 while the
        // author configured 12 would report a window three times too small
        // and the list would render blank rows on every fast scroll, with
        // nothing anywhere saying why. It is the author's number, so it
        // travels with the element rather than being duplicated in latte.js.
        b.attr(5, "data-latte-overscan", "{self.overscan}")

        b.open(6, "div")
        b.attr(7, "data-latte-spacer", "top")
        b.attr(8, "style", "height:{where.top}px")
        b.close()

        var index: int = where.start
        for index < where.start + where.shown {
            b.region(9, "{index}")
            self.row(b, index)
            b.end_region()
            index += 1
        }

        b.open(10, "div")
        b.attr(11, "data-latte-spacer", "bottom")
        b.attr(12, "style", "height:{where.bottom}px")
        b.close()
        b.close()
    }
}
