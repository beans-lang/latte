// `Signal<T>` and the `live` subtree — PLAN.md's third render tier.
//
// The first two tiers both end in a render: a field changes and `notify()`
// runs one component's `render(b)`; a parameter changes and the child's
// `render(b)` runs if `should_render` agrees. This tier does not.
//
// > | a `Signal` the markup marked `live` | the one bound expression. No
// > render pass, no diff. | one edit |
//
// Both halves of that sentence are load-bearing and they are what this file
// costs its complexity for:
//
// * **No render pass.** A signal write never calls `Renderer.mark`, so the
//   dirty set does not grow, `flush()` has nothing to do, and `render_count`
//   — which `Renderer.finish()` derives from `Builder.diffed`, and which only
//   `flush()` and `mount()` can move — cannot go up. That is the row gate 6
//   was missing.
// * **No diff.** Re-diffing the component would be O(its frames), which is
//   what the second tier already costs; a third tier that costs the same as
//   the second is a tier worth not having (PLAN.md D2). So a live binding
//   records WHERE its text node sits — the same child indices the differ
//   would have computed, from the same span walker — and a write emits the
//   `step_in … set_text … step_out` for that one node directly.
//
// Nothing here imports std.io, std.fs, std.net, std.time or std.random. See
// beans.pot and `test.sh --wasm`.
package latte

// ---------------------------------------------------------------- the cell
//
// `Cell` is the non-generic half of a signal: the subscriber set, the owner
// link, and the read/write protocol. `Signal<T>` holds one rather than
// extending it, so nothing here depends on how a generic class inherits.

/// One signal's subscribers, and the link back to the page that lets a read
/// know which binding is asking.
///
/// **Why the owner is needed at all.** A read has to record itself into "the
/// binding currently being evaluated", and that value belongs to the PAGE —
/// one per `Registry`, which every `Builder` in a page shares. A module-level
/// singleton would have been the usual place for it and Beans does not have
/// one: a `const` is folded into its uses and "there is no composite constant:
/// with no storage there is nothing for a list or an object to live in"
/// (spec/SYNTAX.md, *Module constants*). A `static` field on a class would
/// have storage — and would be one location shared by every page in the
/// process, which is a data race the moment two circuits run on two threads,
/// and a wrong answer (a read on one page attaching to a binding on another)
/// before it is ever a crash. So the scope is per page, and a cell reaches its
/// page through the component that owns it.
///
/// Both links are `weak` and for the same reason `MountHandle.sink` is: the
/// page owns the component, which owns the signal, so the edges back are the
/// only ones in the design with no reason to exist. The zeroing read is what
/// makes a signal written after its component was disposed a no-op instead of
/// a write into a dead page.
pub class Cell {
    weak owner: Option<Component> = none
    /// Bindings by binding id. A Map and not a List because Beans has no
    /// reference equality (see `Component.id()`), so "have I already recorded
    /// this binding" cannot be asked of two references — only of two ints.
    subs: Map<int, LiveBinding> = {}

    pub fn init() {}

    /// Give this cell the component that holds it. Called through
    /// `Signal.own`, which is the one line an author writes.
    pub fn own(owner: Component) { self.owner = some(owner) }

    /// Whether this cell can reach a page at all. A cell nobody owned records
    /// nothing, which is why `Builder.live_text` refuses a live expression
    /// that recorded nothing rather than rendering it once and never again.
    pub fn attached() -> bool {
        match self.page() {
            some(_) => { return true }
            none => { return false }
        }
    }

    pub fn subscribers() -> int { return self.subs.len() }

    fn page() -> Option<Registry> {
        match self.owner {
            some(component) => { return component.mount.page }
            none => { return none }
        }
    }

    /// A read. If a live expression is being evaluated right now, this cell
    /// becomes one of its dependencies — in both directions, so the binding
    /// can drop itself again when its dependencies change.
    pub fn record() {
        match self.page() {
            some(registry) => {
                match registry.watching() {
                    some(binding) => {
                        if !self.subs.contains_key(binding.id) {
                            self.subs[binding.id] = binding
                            binding.note(self)
                        }
                    }
                    none => {}
                }
            }
            none => {}
        }
    }

    fn drop_sub(id: int) { let _: bool = self.subs.remove(id) }

    /// A write. Every binding that read this cell is re-evaluated, in binding
    /// order, which is the order they were created in and therefore document
    /// order within a component.
    ///
    /// The list is SNAPSHOT first: `refresh` re-collects a binding's
    /// dependencies, which removes it from this very map when the new
    /// evaluation no longer reads this cell.
    pub fn fire() {
        var ids: List<int> = self.subs.keys()
        ids.sort()
        var wake: List<LiveBinding> = []
        for id: int in ids {
            match self.subs.get(id) {
                some(binding) => { wake.push(binding) }
                none => {}
            }
        }
        for binding: LiveBinding in wake { binding.refresh() }
    }
}

// ---------------------------------------------------------------- signal
/// A value cell whose reads are recorded and whose writes update exactly the
/// live expressions that read it.
///
/// ```
/// class Clock extends Component {
///     pub ticks: Signal<int> = new Signal<int>(0)
///     pub override fn on_init() { self.ticks.own(self) }
/// }
/// ```
///
/// **Why `own` is a separate line.** `new Signal<int>(self, 0)` in the field
/// initializer, or in `init`, is refused by the compiler — *"self is used here
/// before the object is fully built — a method call on self, passing self on,
/// returning self, or interpolating self is allowed only once every field is
/// assigned"* — and a component's signals are exactly the fields that are not
/// assigned yet. `on_init` runs after activation and after the framework has
/// wired the component, so `self` is whole and the page is reachable.
///
/// Forgetting it is not silent: a signal nobody owns records no binding, and a
/// live expression that recorded no binding is a fault at the builder, not a
/// value that renders once and then never moves again.
pub class Signal<T> {
    pub cell: Cell = new Cell()
    value: T

    pub fn init(value: T) { self.value = value }

    /// Attach this signal to the component that holds it. Call it from
    /// `on_init`.
    pub fn own(owner: Component) { self.cell.own(owner) }

    /// Read, and record the read if a live expression is being evaluated.
    pub fn get() -> T {
        self.cell.record()
        return self.value
    }

    /// Read without recording. For code that is not a live expression and does
    /// not want to become a dependency — a handler reading the current value
    /// to compute the next one is the ordinary case.
    pub fn peek() -> T { return self.value }

    /// Write, and re-evaluate every live expression that read this signal.
    ///
    /// It does NOT compare the new value with the old one and skip: `T` is
    /// unconstrained here, so there is no equality to call. The comparison
    /// that matters happens one level down and is a comparison of the
    /// rendered TEXT, which is what the client actually holds — so a write of
    /// a value that formats the same emits nothing either way, and a write of
    /// a genuinely equal value costs one thunk and no edit.
    pub fn set(value: T) {
        self.value = value
        self.cell.fire()
    }
}

// ---------------------------------------------------------------- binding
/// One live expression: the thunk, the frame it fills, and where that frame
/// sits in the applier's logical tree.
pub class LiveBinding {
    /// Page-unique, from `Registry.fresh_binding`. It is what a `Cell` keys
    /// its subscriber map on.
    pub id: int = 0

    /// The frame index this binding owns in its buffer's CURRENT frame list,
    /// and the seq that frame carries. `Builder.reset` builds a new `Frames`
    /// and retires every binding with the old one, so an index here is never
    /// read against a list it was not measured in.
    pub index: int = 0
    pub seq: int = 0

    pub body: fn() -> string = fn() -> string { return "" }

    /// The buffer holding the frame. Weak: the buffer owns this binding.
    pub weak buffer: Option<Builder> = none

    /// The cells this binding read on its last evaluation.
    cells: List<Cell> = []

    /// Retired by `reset`, by `tear_down`, or by a failed boundary that threw
    /// away the frames this binding was measured against.
    pub dead: bool = false

    /// The child-index path to this binding's text node, computed once per
    /// render — lazily, so a page whose signals never fire never pays for it.
    /// `path_ok` false means there is no addressable place for an edit; see
    /// `resolve`.
    path: List<int> = []
    path_ready: bool = false
    path_ok: bool = false

    /// Where this binding's `set_text` sits in `Builder.pending`, or -1. A
    /// second write before the next batch REWRITES that edit rather than
    /// appending another, so N writes between two batches are one edit and not
    /// N — the wire carries what the client needs, not a history of it.
    pub pending_at: int = -1

    pub fn init(id: int, buffer: Builder, index: int, seq: int, body: fn() -> string) {
        self.id = id
        self.buffer = some(buffer)
        self.index = index
        self.seq = seq
        self.body = body
    }

    fn note(cell: Cell) { self.cells.push(cell) }

    /// Drop every subscription this binding holds. Called before each
    /// evaluation, so a binding that stops reading a signal stops being woken
    /// by it — the dependency set is what the LAST evaluation read, not the
    /// union of everything it has ever read.
    pub fn unsubscribe() {
        for cell: Cell in self.cells { cell.drop_sub(self.id) }
        self.cells.clear()
    }

    pub fn dependencies() -> int { return self.cells.len() }

    pub fn retire() {
        self.dead = true
        self.unsubscribe()
        self.buffer = none
    }

    /// A signal this binding read has changed.
    ///
    /// Re-evaluates the expression, and if the TEXT changed, rewrites the
    /// frame in place and queues the one edit that carries it. No render runs
    /// and no diff runs, which is the whole point of the tier.
    pub fn refresh() {
        if self.dead { return }
        match self.buffer {
            some(buffer) => { buffer.refresh_binding(self) }
            none => {}
        }
    }

    /// The path to this binding's text node, as child indices from the
    /// component root: every entry but the last is a `step_in`, and the last
    /// is the index `set_text` names.
    ///
    /// `false` means no edit can be addressed to it, and there is exactly one
    /// way that happens on a well-formed buffer: an ancestor element carries
    /// `preserve`, and the differ emits nothing under a preserved element
    /// either (`Differ.pair`, D6) because something else owns what is under
    /// there now. The frame is still rewritten, so the serializer and the next
    /// real render both see the new value; only the wire is silent, which is
    /// what `preserve` asks for.
    fn resolve(frames: Frames) -> bool {
        if self.path_ready { return self.path_ok }
        self.path_ready = true
        self.path.clear()
        self.path_ok = live_path(frames, 0, frames.len(), self.index, self.path)
        return self.path_ok
    }

    fn forget_path() {
        self.path_ready = false
        self.path_ok = false
        self.path.clear()
    }

    /// The edits for this binding's node, appended to `out`. Answers the index
    /// of the `set_text` so a later write can rewrite it in place.
    fn emit(frames: Frames, body: string, out: List<Edit>) -> int {
        if !self.resolve(frames) { return -1 }
        var step: int = 0
        for step < self.path.len() - 1 {
            out.push(Edit.step_in(self.path[step]))
            step += 1
        }
        let at: int = out.len()
        out.push(Edit.set_text(self.path[self.path.len() - 1], body))
        step = 0
        for step < self.path.len() - 1 {
            out.push(Edit.step_out)
            step += 1
        }
        return at
    }
}

// ---------------------------------------------------------------- the path
//
// The differ's addressing, computed forwards instead of by comparison.
//
// `Differ.merge` walks a parent's `scan_spans` list and advances its index by
// one per span — one per REGION as well, since `keyed` returns
// `base + n.spans.len()`. So the child index of a span IS its position in its
// parent's span list, and this walk answers the same number by construction
// rather than by agreement. It uses `scan_spans` and `read_head` from `diff.b`
// for the same reason `serialize.b` and `diff.b` step over a stray attribute
// frame the same way: two walkers that answer differently are two bugs waiting
// to be compared for equality.

fn live_path(frames: Frames, start: int, stop: int, target: int,
             out: List<int>) -> bool {
    let spans: List<Span> = scan_spans(frames, start, stop)
    var position: int = 0
    for position < spans.len() {
        let span: Span = spans[position]
        if span.start == target {
            out.push(position)
            return true
        }
        if target > span.start && target < span.next {
            if span.kind == SPAN_ELEMENT {
                let head: Head = read_head(frames, span)
                if head.preserved { return false }
            } else if span.kind != SPAN_REGION && span.kind != SPAN_FRAGMENT &&
                      span.kind != SPAN_BOUNDARY {
                // A text, a markup blob or a mounted child has no interior the
                // applier can address; a frame inside one is not a child of it.
                return false
            }
            out.push(position)
            return live_path(frames, span.body, span.stop, target, out)
        }
        position += 1
    }
    return false
}
