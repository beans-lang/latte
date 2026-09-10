// tests/components.b — the half of component behavior `tests/pages.b` does not cover.
//
// pages.b owns parameters and required parameters, because both are decided by
// the startup scan. Everything else in gate 5's row happens at a **mount**:
// child content, templated content, a callback marking the component that
// supplied it, `ref`, `attrs=` splat, `preserve`, and a component three levels
// down. Those are this file's.
//
// Each section mounts its own small root into its own `Renderer`, so a section
// cannot pass because of something another section left behind. Every claim
// that is a refusal or a suppression has a **positive control** beside it — an
// input that must do the thing — because "nothing happened" is what a broken
// mechanism and a working one both look like from the outside.
//
// The numbers are exact on purpose. A framework that quietly re-renders the
// world serializes the same HTML, so HTML alone cannot tell you it is working;
// only the render counts can.
package main

import std.io
import {Builder, Component, Callback, Reference, Renderer, ParamWatch,
        Frame, Batch, ComponentUpdate, Edit, MouseEvent} from latte

// ============================================================== fixtures

/// Child content. `body` is a `fn(Builder)` the caller supplies and this
/// component places. `$slot` in markup compiles to exactly the `b.fragment`
/// call below.
pub class Card extends Component {
    pub title: string = ""
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "card")
        b.open(2, "h3")
        b.text(3, "{self.title}")
        b.close()
        b.fragment(4, self.body)
        b.close()
    }
}

pub class Line {
    pub id: int = 0
    pub total: int = 0
    pub fn init(id: int, total: int) {
        self.id = id
        self.total = total
    }
}

/// Templated content. `row` is a `fn(Builder, Line)` — the caller writes the
/// markup and this component decides what to pass it and how many times. In
/// `.bx` the caller writes `$slot:row as o: Line { … }` and the component
/// writes `$slot:row as order`, which is the `b.fragment(0, fn(inner) {
/// self.row(inner, order) })` below.
pub class Grid extends Component {
    pub orders: List<Line> = []
    pub row: fn(Builder, Line) = fn(b: Builder, o: Line) {}
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "table")
        for order: Line in self.orders {
            b.region(1, "{order.id}")
            b.fragment(0, fn(inner: Builder) { self.row(inner, order) })
            b.end_region()
        }
        b.close()
    }
}

/// A child that fires an event out and never marks itself.
///
/// It carries a `ParamWatch` so the numbers below can say something: without
/// one, `should_render` is true and every parent pass re-renders it, which
/// would make "the callback marked the parent" and "the callback marked
/// everything" produce the same count.
pub class Picker extends Component {
    pub label: string = ""
    pub on_pick: Option<Callback<int>> = none
    /// NOT a parameter — the child owns it. A parent holding a `ref` reaches
    /// it through `set_badge`, which is what a handle is for: `ref={self.grid}`
    /// then `self.grid.reload()`. Writing a *parameter* through a ref would be
    /// undone by the parent's next render, which sets parameters itself.
    pub badge: string = ""
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}
    pub override fn on_params_set() { self.watch.record([self.label]) }
    pub override fn should_render() -> bool { return self.watch.differs() }
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) { self.pick(1) })
        b.text(2, "{self.label}{self.badge}")
        b.close()
    }
    pub fn set_badge(text: string) {
        self.badge = text
        self.notify()
    }
    /// What the child's own button calls — and what a test calls **directly**,
    /// which is the only way to see the callback's marking on its own. Through
    /// the button, the renderer also marks the component that bound the
    /// handler, and that is this child.
    pub fn pick(id: int) {
        match self.on_pick {
            some(out) => { out.call(id) }
            none => {}
        }
    }
}

// ---- §1 child content ---------------------------------------------------

pub class CardHost extends Component {
    pub note: string = "one"
    pub empty: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.component<Card>(1, fn(card: Card) {
            card.title = "titled"
            if self.empty { card.body = fn(inner: Builder) {} }
            else { card.body = fn(inner: Builder) { self.inside(inner) } }
        })
        b.close()
    }
    fn inside(b: Builder) {
        b.open(0, "p")
        b.text(1, "{self.note}")
        b.close()
    }
}

// ---- §2 templated content -----------------------------------------------

pub class GridHost extends Component {
    pub orders: List<Line> = []
    pub calls: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.component<Grid>(1, fn(grid: Grid) {
            grid.orders = self.orders.clone()
            grid.row = fn(inner: Builder, order: Line) { self.cell(inner, order) }
        })
        b.close()
    }
    /// The caller's template. It counts its own calls, because "the component
    /// placed the template once per item" is a claim about how many times this
    /// ran, not about what came out.
    fn cell(b: Builder, order: Line) {
        self.calls += 1
        b.open(0, "td")
        b.text(1, "{order.total}")
        b.close()
    }
}

// ---- §3 callbacks, §4 ref, §8 depth --------------------------------------

pub class PickHost extends Component {
    pub picked: int = -1
    pub label: string = "pick"
    /// `ref={self.picker}` on a component tag: an assignment inside the setup
    /// closure, so the parent holds the concrete child and no downcast is
    /// needed at the use site.
    pub picker: Option<Picker> = none
    /// `ref={self.handle}` on an element: a `Reference` the builder fills.
    pub handle: Reference = new Reference()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.open(1, "input")
        b.reference(2, fn(handle: Reference) { self.handle = handle })
        b.close()
        b.component<Card>(3, fn(card: Card) {
            card.title = "wrapper"
            card.body = fn(inner: Builder) { self.deep(inner) }
        })
        b.close()
    }
    /// Three levels: this component, the `Card` it mounts, and the `Picker`
    /// the card's child content mounts. The picker's frames are the card's
    /// buffer's, not this one's.
    fn deep(b: Builder) {
        b.component<Picker>(0, fn(child: Picker) {
            child.label = self.label
            child.on_pick = some(new Callback<int>(self, fn(id: int) { self.received(id) }))
            self.picker = some(child)
        })
    }
    fn received(id: int) { self.picked = id }
}

/// The control for `ref`: the same shape with no `reference` call and no
/// assignment, so "the handle was filled" is distinguishable from "a
/// `Reference` is filled by default".
pub class NoRefHost extends Component {
    pub handle: Reference = new Reference()
    pub picker: Option<Picker> = none
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.open(1, "input")
        b.close()
        b.component<Picker>(2, fn(child: Picker) { child.label = "unheld" })
        b.close()
    }
}

// ---- §5 splat -------------------------------------------------------------

pub class SplatHost extends Component {
    pub extra: Map<string, string> = {}
    pub splat: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "base")
        if self.splat { b.attrs(2, self.extra) }
        b.text(3, "splatted")
        b.close()
    }
}

// ---- §6 preserve ----------------------------------------------------------

/// `preserve` on an element: render this subtree once and never diff into it,
/// because a third-party widget owns what is under there now.
pub class PreserveHost extends Component {
    pub body: string = "a"
    pub guard: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.open(1, "div")
        b.attr(2, "class", "owned")
        if self.guard { b.preserve(3) }
        b.open(4, "span")
        b.text(5, "{self.body}")
        b.close()
        b.close()
        b.open(6, "p")
        b.text(7, "{self.body}")
        b.close()
        b.close()
    }
}

// ============================================================== reporting

class Report {
    pub failures: int = 0
    pub fn init() {}

    pub fn check(label: string, got: int, want: int) {
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got {got}, want {want}") ; self.failures += 1 }
    }

    pub fn check_text(label: string, got: string, want: string) {
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got \"{got}\", want \"{want}\"") ; self.failures += 1 }
    }

    pub fn check_true(label: string, got: bool) {
        if got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got false, want true") ; self.failures += 1 }
    }

    pub fn check_false(label: string, got: bool) {
        if !got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got true, want false") ; self.failures += 1 }
    }
}

/// The first handler slot in a component's own buffer.
fn handler_in(r: Renderer, id: int) -> int {
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

/// A callback whose owner is created here and released when this returns.
/// `owner` is `weak`, so the field reads `none` before the referent's `deinit`
/// runs and a callback fired after teardown does nothing.
fn orphan() -> Callback<int> {
    let gone: Picker = new Picker()
    return new Callback<int>(gone, fn(id: int) {})
}

// ============================================================== the gate

fn main() {
    let report: Report = new Report()

    // ---------------------------------------------------------------- §1
    io.println("== 1. child content ==")
    let host1: CardHost = new CardHost()
    let r1: Renderer = new Renderer()
    r1.mount(host1)
    report.check("the host, the card: two components", r1.ids().len(), 2)
    report.check_text("the caller's markup is inside the card", r1.html(),
                      "<section><div class=\"card\"><h3>titled</h3><p>one</p></div></section>")

    // The caller's frames belong to the CARD's buffer, not the host's. If a
    // fragment body were numbered in the host's buffer, the `<p>` would move
    // out of the card's subtree the first time the card alone re-rendered.
    var card_id: int = -1
    for id: int in r1.ids() {
        if id != host1.id() { card_id = id }
    }
    report.check_true("the card has its own buffer", r1.buffer(card_id).is_some())
    report.check_true("and the caller's <p> is in it", buffer_has(r1, card_id, "open p"))
    report.check_false("and NOT in the host's", buffer_has(r1, host1.id(), "open p"))

    // The body is PLACED, not called. `self.body(b)` from inside `Card.render`
    // puts the same frames in the same buffer and serializes the same HTML —
    // it fails none of the checks above — and it is still wrong, because the
    // body is then numbered in the card's own sequence space. `self.inside`
    // opens at seq 0 and the card is already at seq 2, so the frames come out
    // of order; and there is no `fragment` pair for the differ to treat the
    // caller's content as one replaceable unit. Both are asserted here,
    // because neither shows up in the HTML.
    report.check_true("the body is placed as a fragment",
                      buffer_has(r1, card_id, "4 fragment"))
    report.check_true("and the fragment is closed",
                      buffer_has(r1, card_id, "/fragment"))
    report.check("placing it raised no fault", r1.all_faults().len(), 0)

    // The control: the same card with an empty body. Without it, "the child
    // content rendered" cannot be told from "a card always prints a <p>".
    host1.empty = true
    r1.mark(host1.id())
    let _: int = r1.flush()
    report.check_text("an empty body places nothing", r1.html(),
                      "<section><div class=\"card\"><h3>titled</h3></div></section>")
    report.check("and still no faults", r1.all_faults().len(), 0)

    // ---------------------------------------------------------------- §2
    io.println("")
    io.println("== 2. templated content ==")
    let host2: GridHost = new GridHost()
    host2.orders = [new Line(1, 10), new Line(2, 20), new Line(3, 30)]
    let r2: Renderer = new Renderer()
    r2.mount(host2)
    report.check("the template ran once per item", host2.calls, 3)
    report.check_text("with each item's own data", r2.html(),
                      "<section><table><td>10</td><td>20</td><td>30</td></table></section>")

    // The control: no items, no calls. A template that ran on an empty list
    // would be a component placing content the caller never asked for.
    let host2b: GridHost = new GridHost()
    let r2b: Renderer = new Renderer()
    r2b.mount(host2b)
    report.check("the placement raised no fault", r2.all_faults().len(), 0)
    report.check("no items, no template calls", host2b.calls, 0)
    report.check_text("and an empty table", r2b.html(), "<section><table></table></section>")

    // ---------------------------------------------------------------- §3
    io.println("")
    io.println("== 3. a callback marks the component that SUPPLIED it ==")
    let host3: PickHost = new PickHost()
    let r3: Renderer = new Renderer()
    r3.mount(host3)
    report.check("host, card, picker: three levels", r3.ids().len(), 3)

    let picker: Picker = match host3.picker { some(p) => p none => new Picker() }
    report.check_true("the ref holds a mounted picker", picker.id() >= 0)
    report.check_true("and the renderer knows it", r3.mounted(picker.id()))

    // The isolated claim. Calling `pick` directly runs the callback and
    // nothing else — no dispatch, so nothing marks the child.
    report.check("nothing is dirty yet", r3.pending(), 0)
    picker.pick(7)
    report.check("the callback ran the parent's code", host3.picked, 7)
    report.check_true("the SUPPLIER is dirty", r3.is_dirty(host3.id()))
    report.check_false("the child that fired it is NOT", r3.is_dirty(picker.id()))
    report.check("exactly one component is dirty", r3.pending(), 1)

    // And what that costs: the host re-renders, the card re-renders because
    // its `body` closure is new every pass, and the picker runs ZERO because
    // its one parameter did not change.
    let host_before: int = r3.render_count(host3.id())
    let picker_before: int = r3.render_count(picker.id())
    report.check("the flush ran two renders, not three", r3.flush(), 2)
    report.check("the host rendered again", r3.render_count(host3.id()), host_before + 1)
    report.check("the picker did not", r3.render_count(picker.id()), picker_before)

    // The control for "marks the supplier": `notify()` marks the caller, so a
    // picker that changes its own state marks itself and not the host.
    picker.notify()
    report.check_true("notify marks the component that called it", r3.is_dirty(picker.id()))
    report.check_false("and not its parent", r3.is_dirty(host3.id()))
    let _: int = r3.flush()

    // Through the button, BOTH are marked, and that is not a contradiction:
    // the renderer marks whoever bound the handler and the callback marks
    // whoever supplied it. A parent that changes what the child renders needs
    // the first; a child that only reports needs the second.
    let slot: int = handler_in(r3, picker.id())
    report.check_true("the picker bound a handler", slot >= 0)
    report.check("and the renderer knows who owns it", r3.owner_of(slot), picker.id())
    let click: MouseEvent = new MouseEvent()
    report.check_true("the click dispatched", r3.fire_mouse(slot, click))
    report.check_true("the child is dirty, by dispatch", r3.is_dirty(picker.id()))
    report.check_true("the host is dirty, by callback", r3.is_dirty(host3.id()))
    report.check("the callback carried the child's id", host3.picked, 1)
    let _: int = r3.flush()

    // An unknown id marks nothing: a client cannot dirty a component by
    // guessing a number.
    let stray: MouseEvent = new MouseEvent()
    report.check_false("an unknown handler id dispatches nothing",
                       r3.fire_mouse(987654, stray))
    report.check("and marks nothing", r3.pending(), 0)

    // A callback whose owner is gone does nothing. The owner is weak so the
    // read is `none` before any teardown body runs.
    let dead: Callback<int> = orphan()
    report.check_false("a callback with no owner is not alive", dead.alive())
    dead.call(5)
    report.check("and calling it changes nothing", r3.pending(), 0)

    // ---------------------------------------------------------------- §4
    io.println("")
    io.println("== 4. ref, on an element and on a component tag ==")
    report.check_true("the element ref was filled", host3.handle.node >= 0)
    let node_first: int = host3.handle.node
    r3.mark(host3.id())
    let _: int = r3.flush()
    report.check("and it is the same node after a re-render",
                 host3.handle.node, node_first)
    // A handle is worth having only if you can drive it. The parent reaches
    // into the child it holds; the child marks ITSELF, so exactly one
    // component re-renders and the parent is not touched.
    report.check("nothing is dirty before the call", r3.pending(), 0)
    picker.set_badge("!")
    report.check_true("the held child is dirty", r3.is_dirty(picker.id()))
    report.check_false("and its parent is not", r3.is_dirty(host3.id()))
    report.check("driving it re-renders one component", r3.flush(), 1)
    report.check_true("and the new state is in the HTML", r3.html().contains("pick!"))

    // The parameter half of the same rule, which is the trap: a parameter
    // written through a ref is the PARENT's to set, so the parent's next
    // render puts it back. This is not a bug to fix; it is what "the parent
    // owns its child's parameters" means, and a test that wrote a parameter
    // through a ref would be asserting the opposite by accident.
    picker.label = "written behind the parent's back"
    r3.mark(host3.id())
    let _: int = r3.flush()
    report.check_text("a parameter written through a ref is reset by the parent",
                      picker.label, "pick")

    let host4: NoRefHost = new NoRefHost()
    let r4: Renderer = new Renderer()
    r4.mount(host4)
    report.check("the control: no ref, no node", host4.handle.node, -1)
    report.check_false("and no component handle", host4.picker.is_some())

    // ---------------------------------------------------------------- §5
    io.println("")
    io.println("== 5. attrs= splat ==")
    let host5: SplatHost = new SplatHost()
    host5.extra = {"data-kind": "b", "aria-label": "a", "title": "c"}
    let r5: Renderer = new Renderer()
    r5.mount(host5)
    // Sorted by name, always. A Map promises no iteration order, so an
    // unsorted splat would let one render's HTML differ from the next's for no
    // reason a reader could see — and the differ would report edits for it.
    report.check_text("splatted attributes, sorted, after the literal one",
                      r5.html(),
                      "<div class=\"base\" aria-label=\"a\" data-kind=\"b\" title=\"c\">splatted</div>")
    report.check("the splat introduced no faults", r5.all_faults().len(), 0)

    // The control: the same element with no splat call. Without it, "the
    // attributes came from the map" cannot be told from "the element always
    // has them".
    host5.splat = false
    r5.mark(host5.id())
    let _: int = r5.flush()
    report.check_text("no splat, no extra attributes", r5.html(),
                      "<div class=\"base\">splatted</div>")

    // An empty map is not an error and is not a no-op to the differ either:
    // the marker slot is taken, so a later splat of the same seq lands in the
    // same place.
    host5.splat = true
    host5.extra = {}
    r5.mark(host5.id())
    let _: int = r5.flush()
    report.check_text("an empty map splats nothing", r5.html(),
                      "<div class=\"base\">splatted</div>")
    report.check("and still no faults", r5.all_faults().len(), 0)

    // ---------------------------------------------------------------- §6
    io.println("")
    io.println("== 6. preserve ==")
    let host6: PreserveHost = new PreserveHost()
    let r6: Renderer = new Renderer()
    r6.mount(host6)
    let _: Batch = r6.batch()
    host6.body = "b"
    r6.mark(host6.id())
    let _: int = r6.flush()
    let guarded: Batch = r6.batch()
    // `edit_count` counts navigation (`step_in`/`step_out`) too, so the claim
    // is about the text edits: one, for the sibling outside the preserved
    // element. The dump is printed because a number alone cannot say WHICH
    // text was edited.
    report.check("a preserved subtree sends one text edit, for the sibling",
                 text_edits(guarded), 1)
    io.println("the batch:")
    io.println(guarded.dump())

    // The control: the same tree with the `preserve` call switched off. Two
    // texts changed, so two edits — and without this number, "one edit" could
    // equally mean the differ found nothing at all.
    let host6b: PreserveHost = new PreserveHost()
    host6b.guard = false
    let r6b: Renderer = new Renderer()
    r6b.mount(host6b)
    let _: Batch = r6b.batch()
    host6b.body = "b"
    r6b.mark(host6b.id())
    let _: int = r6b.flush()
    let plain: Batch = r6b.batch()
    report.check("not preserved: both texts are edited", text_edits(plain), 2)
    io.println("the batch:")
    io.println(plain.dump())

    // ---------------------------------------------------------------- §7
    io.println("")
    io.println("== 7. what gate 5 asks for and latte does not check ==")
    // `@param(required: true)` on a PAGE is a startup refusal — tests/pages.b
    // owns it, because the scan can compare the field against the route's
    // placeholders. On a CHILD component there is nothing to compare it
    // against: the parameters are written by a setup closure, which is opaque
    // (latte sees a `fn(T)`, not which fields it assigns), and the markup
    // compiler cannot help because it does not resolve types and so does not
    // know what fields the tag's component has.
    //
    // This is a deferral with an exit, not a shrug. It closes when a component
    // tag carries the names it wrote: `b.component_named<T>(seq, ["title",
    // "id"], setup)`, emitted by latte-bx, checked at mount against the
    // `@param(required: true)` fields reflection already reports. That is one
    // Builder method and one emitter line, in W1's and W2's files.
    io.println("a required parameter on a CHILD component is NOT checked; see the comment here")

    // ---------------------------------------------------------------- §8
    io.println("")
    io.println("== 8. three levels, each with its own buffer ==")
    report.check_text("the whole tree", r3.html(),
                      "<section><input><div class=\"card\"><h3>wrapper</h3><button>pick!</button></div></section>")
    report.check("three components, three buffers", r3.ids().len(), 3)
    report.check_true("the picker's button is in the PICKER's buffer",
                      buffer_has(r3, picker.id(), "open button"))
    report.check_false("and not in the host's",
                       buffer_has(r3, host3.id(), "open button"))
    report.check("no faults anywhere in the tree", r3.all_faults().len(), 0)

    io.println("")
    io.println("checks failed: {report.failures}")
}

/// How many text edits a batch carries. `Batch.edit_count` counts the
/// `step_in`/`step_out` navigation as well, which is right for "how big is
/// this message" and wrong for "how much of the page changed".
fn text_edits(batch: Batch) -> int {
    var n: int = 0
    for update: ComponentUpdate in batch.updates {
        for edit: Edit in update.edits {
            match edit {
                set_text(_, _) => { n += 1 }
                _ => {}
            }
        }
    }
    return n
}

fn buffer_has(r: Renderer, id: int, text: string) -> bool {
    match r.buffer(id) {
        some(buffer) => { return buffer.dump().contains(text) }
        none => { return false }
    }
}
