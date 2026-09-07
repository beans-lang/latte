// `latte.Builder` — what generated markup calls, and the one component's
// frame buffer it fills.
//
// The signature is `probes/BUILDER.md`, which W2 and W4 also compile against.
// Nothing here imports std.io, std.fs or std.net: `test.sh --wasm` builds the
// core for wasm32-unknown-unknown and that is the check (PLAN.md, D4).
package latte

import std.reflect

// ---------------------------------------------------------------- events
//
// One class per DOM event family. The markup compiler's event table decides
// which family an `on:` attribute belongs to, and the Builder has one named
// method per event typed to its family — so a handler's parameter type is
// fixed by the event name and the author never writes it.
pub class MouseEvent {
    pub button: int = 0
    pub x: int = 0
    pub y: int = 0
    pub fn init() {}
}

pub class InputEvent {
    pub value: string = ""
    pub checked: bool = false
    pub fn init() {}
}

pub class KeyboardEvent {
    pub key: string = ""
    pub repeated: bool = false
    pub fn init() {}
}

pub class SubmitEvent {
    pub fields: Map<string, string> = {}
    pub fn init() {}
}

pub class FocusEvent {
    pub fn init() {}
}

/// A handle to a rendered ELEMENT: `node` is the element's slot id — stable for
/// a source position within a component, and the id the wire uses.
///
/// It carries nothing else, and in particular no handle to a mounted child.
/// `ref` on a component tag is not an attribute-position call at all: every
/// attribute-position call needs `in_attributes`, which only `open()` sets, and
/// a component tag opens no element. W2 compiles it to an assignment inside the
/// setup closure instead — `b.component<Grid>(18, fn(c: Grid) { self.grid =
/// some(c) })` — which hands back the CONCRETE type rather than a `Component`
/// needing a downcast, and fills it at mount rather than after a render.
/// An element ref genuinely cannot be filled before the applier has run, which
/// is why that one stays a `fn(Reference)` sink. See probes/BUILDER.md.
pub class Reference {
    pub node: int = -1
    pub fn init() {}
}

// ---------------------------------------------------------------- component
pub class Component {
    /// The one method the markup compiler writes. It takes the builder rather
    /// than returning a fragment, so a markup block is a plain statement.
    pub fn render(b: Builder) {}

    // Lifecycle. These are declared and called HERE because mounting happens
    // here — `component<T>` is the only place a child is activated, its
    // parameters are set, and its render is gated. W4 overrides them.
    //
    // `on_after_render` is deliberately absent: it fires once the batch has
    // been applied, which only the renderer knows, and the renderer is W5's.

    /// Once, immediately after activation, before the first `on_params_set`.
    pub fn on_init() {}

    /// After the parent's setter has written this render's parameters, on
    /// every render including the first.
    pub fn on_params_set() {}

    /// Consulted before every render after the first. A component that
    /// answers false keeps the frames it already has.
    pub fn should_render() -> bool { return true }

    /// When the slot that mounted this component is not reached by a render
    /// pass, so the component is dropped.
    pub fn dispose() {}
}

// ---------------------------------------------------------------- callback
/// The event-out type. It holds a **weak** owner, and probe 6 says why: not to
/// break a cycle — the handler closure captures `self` on its own and the
/// cycle collector is what kills that — but so a callback fired after its
/// owner is gone reads `none` and does nothing instead of marking a dead
/// component dirty. The weak read turns `none` before the referent's `deinit`
/// body runs, so it can never resurrect anything.
pub class Callback<T> {
    pub weak owner: Option<Component> = none
    pub handler: fn(T) = fn(value: T) {}

    /// `new Callback<int>(self, fn(id: int) { self.select(id) })`.
    ///
    /// NOT a static factory. A `static fn` on a generic class can never bind
    /// the class's type parameter (BLOCKERS.md B5), and a static taking a
    /// `fn(T)` cannot be emitted natively either (B3).
    pub fn init(owner: Component, handler: fn(T)) {
        self.owner = some(owner)
        self.handler = handler
    }

    pub fn call(value: T) {
        match self.owner {
            some(_) => { self.handler(value) }
            none => {}
        }
    }

    /// Whether the owner is still alive. A dead callback is not an error; it
    /// is a component that was disposed between the render that produced the
    /// handler and the event that reached it.
    pub fn alive() -> bool {
        match self.owner {
            some(_) => { return true }
            none => { return false }
        }
    }
}

// ---------------------------------------------------------------- registry
//
// One per page, shared by every Builder in it. It owns the id counter and the
// handler tables, so dispatching `ev {h: 41}` is one map lookup rather than a
// walk of the component tree.
pub class Registry {
    next: int = 1
    pub mouse: Map<int, fn(MouseEvent)> = {}
    pub input: Map<int, fn(InputEvent)> = {}
    pub keyboard: Map<int, fn(KeyboardEvent)> = {}
    pub submit: Map<int, fn(SubmitEvent)> = {}
    pub focus: Map<int, fn(FocusEvent)> = {}

    /// Component ids the sweep dropped since the last batch. The applier holds
    /// one root node per mounted component and would otherwise keep the entry
    /// for a component that has left the page — and a later update addressed to
    /// a stale id would land on a node nothing renders.
    ///
    /// It lives on the Registry rather than on a Builder because a torn-down
    /// buffer takes its own record with it: `tear_down` drops a whole subtree,
    /// and by the time the differ runs, those buffers are unreachable.
    pub disposed: List<int> = []
    pub fn init() {}

    fn note_disposed(id: int) { self.disposed.push(id) }

    /// Read the disposals and forget them. The differ calls this once per
    /// batch, so a disposal is reported exactly once.
    pub fn drain_disposed() -> List<int> {
        var out: List<int> = []
        for id: int in self.disposed { out.push(id) }
        self.disposed.clear()
        return move out
    }

    /// Slot ids are page-unique, which is what lets one of them be a mount
    /// key, a component id and a wire handler id at once.
    fn fresh() -> int {
        let value: int = self.next
        self.next += 1
        return value
    }

    fn forget(id: int) {
        let _: bool = self.mouse.remove(id)
        let _: bool = self.input.remove(id)
        let _: bool = self.keyboard.remove(id)
        let _: bool = self.submit.remove(id)
        let _: bool = self.focus.remove(id)
    }

    pub fn fire_mouse(id: int, event: MouseEvent) -> bool {
        match self.mouse.get(id) {
            some(handler) => { handler(event); return true }
            none => { return false }
        }
    }

    pub fn fire_input(id: int, event: InputEvent) -> bool {
        match self.input.get(id) {
            some(handler) => { handler(event); return true }
            none => { return false }
        }
    }

    pub fn fire_keyboard(id: int, event: KeyboardEvent) -> bool {
        match self.keyboard.get(id) {
            some(handler) => { handler(event); return true }
            none => { return false }
        }
    }

    pub fn fire_submit(id: int, event: SubmitEvent) -> bool {
        match self.submit.get(id) {
            some(handler) => { handler(event); return true }
            none => { return false }
        }
    }

    pub fn fire_focus(id: int, event: FocusEvent) -> bool {
        match self.focus.get(id) {
            some(handler) => { handler(event); return true }
            none => { return false }
        }
    }
}

// ---------------------------------------------------------------- scopes
//
// A numbering scope. Sequence numbers restart inside a region, a fragment and
// a boundary, so "seq 1" means one thing per scope and the differ compares
// siblings within a scope and never across one.
const SCOPE_ROOT: int = 0
const SCOPE_ELEMENT: int = 1
const SCOPE_REGION: int = 2
const SCOPE_FRAGMENT: int = 3
const SCOPE_BOUNDARY: int = 4

class Scope {
    pub last: int = -1
    pub region_run: int = -1
    pub kind: int = 0
    pub keys: Map<string, int> = {}
    pub fn init(kind: int) { self.kind = kind }
}

class BoundaryMark {
    pub frame: int = 0
    pub seq: int = 0
    pub depth: int = 0
    pub regions: int = 0
    pub scopes: int = 0
    pub paths: int = 0
    pub fn init() {}
}

// ---------------------------------------------------------------- builder
pub class Builder {
    /// This pass's frames, and the pass before it — the differ's two sides.
    pub frames: Frames = new Frames()
    pub previous: Frames = new Frames()

    /// Anything the builder refused or could not make sense of. Generated code
    /// is machine-written, so a fault here is a compiler bug and must be loud
    /// rather than tolerated.
    pub faults: List<string> = []

    /// Error-boundary failures recorded during this pass, in order.
    pub failures: List<string> = []

    /// Mounted children, keyed by SLOT id, held as the `reflect.Value` the
    /// activation produced and never as `Component`: `reflect.value(x)` boxes
    /// the STATIC type of `x` (BLOCKERS.md B6), so a child stored as a
    /// `Component` and re-boxed comes back as a `Component` Value and `as? T`
    /// answers `none`.
    pub children: Map<int, reflect.Value> = {}

    /// One frame buffer per mounted child, same slot key. A child is a LEAF in
    /// this component's frame list, so re-rendering one component resets and
    /// refills exactly one of these.
    pub nested: Map<int, Builder> = {}

    /// The page-wide handler tables and id counter.
    pub registry: Registry = new Registry()

    /// Constant folding, on by default. Generated code emits both arms —
    /// `if b.fold { b.constant(…) } else { …the walk… }` — so a page suspected
    /// of stale content can be compared against the unfolded form directly.
    /// PLAN.md names this as the mitigation for the one folding bug that still
    /// compiles.
    pub fold: bool = true

    /// This component's id, which is its slot id in its parent. The root is 0.
    pub id: int = 0

    /// Whether this buffer has ever been filled. `should_render` is consulted
    /// only after the first render; a component that has never rendered has
    /// nothing to keep.
    pub rendered: bool = false

    /// Whether the differ has already turned this buffer's frames into edits.
    ///
    /// This is what stops a component that answered `should_render() == false`
    /// from being diffed twice. Such a component is never `reset`, so its
    /// `previous` and `frames` still hold the pair the LAST batch was built
    /// from — diffing them again would re-send that batch's inserts, removes
    /// and moves, and those are not idempotent. `reset` clears it; the differ
    /// sets it. A buffer that has never rendered starts settled, because an
    /// empty buffer has nothing anybody is waiting for.
    pub diffed: bool = true

    slots: Map<string, int> = {}
    live: Map<int, bool> = {}
    path: List<string> = [""]
    scopes: List<Scope> = []
    boundaries: List<BoundaryMark> = []
    depth: int = 0
    regions: int = 0
    in_attributes: bool = false
    last_attribute_seq: int = -1
    last_attribute_name: string = ""
    pass_open: bool = false

    pub fn init() {
        self.scopes.push(new Scope(SCOPE_ROOT))
    }

    fn adopt(shared: Registry, component_id: int) {
        self.registry = shared
        self.id = component_id
    }

    // ---- scope bookkeeping ------------------------------------------------

    fn top() -> Scope { return self.scopes[self.scopes.len() - 1] }

    fn enter_scope(kind: int) { self.scopes.push(new Scope(kind)) }

    fn leave_scope() {
        if self.scopes.len() <= 1 { return }
        let _: Scope = self.scopes.remove(self.scopes.len() - 1)
    }

    fn push_path(step: string) {
        self.path.push("{self.path[self.path.len() - 1]}{step}")
    }

    fn pop_path() {
        if self.path.len() <= 1 { return }
        let _: string = self.path.remove(self.path.len() - 1)
    }

    /// A slot id is `(this component, the region path, seq)` resolved to an int
    /// once and cached. It is NOT the seq: a `component<T>` or an `on_click`
    /// inside a `$for` has the same seq on every row, so a table keyed by seq
    /// hands all N rows one shared child and one shared handler.
    fn slot_for(seq: int) -> int {
        let key: string = "{self.path[self.path.len() - 1]}{seq}"
        match self.slots.get(key) {
            some(existing) => { self.live[existing] = true; return existing }
            none => {
                let made: int = self.registry.fresh()
                self.slots[key] = made
                self.live[made] = true
                return made
            }
        }
    }

    /// Every sibling in a scope must carry a seq after the one before it,
    /// because branch arms get disjoint ranges. The one exception is a run of
    /// regions from one loop, which all carry the loop's seq.
    fn note_sibling(seq: int, is_region: bool) {
        let scope: Scope = self.top()
        if is_region && seq == scope.region_run {
            // another row of the same loop
        } else if seq <= scope.last {
            self.faults.push(
                "sequence {seq} does not follow {scope.last} in this scope")
        }
        scope.last = seq
        if is_region {
            if seq != scope.region_run { scope.keys.clear() }
            scope.region_run = seq
        } else {
            scope.region_run = -1
        }
        self.in_attributes = false
    }

    /// Take the next slot in this element's attribute run, or refuse it.
    ///
    /// Within one element, `(seq, name)` must STRICTLY increase — and that is
    /// a stronger rule than "seq must not go backwards", which is all this
    /// checked before the differ existed. The differ merges the old and new
    /// attribute runs on exactly this key, and the applier keeps its slots in
    /// exactly this order, so a run that is not ordered is a run the applier
    /// cannot reproduce, and a key that repeats is a merge with no answer.
    ///
    /// A frame that fails is DROPPED rather than written, the same way an
    /// unsafe attribute name is. A malformed frame list is a list the
    /// serializer, the differ and the applier each have to guess at, and the
    /// guessing is worth doing once, here, loudly.
    ///
    /// Slots with no name — a handler, a `ref`, a `preserve`, and the marker
    /// frame of an `attrs` splat — take the key `(seq, "")`, which sorts
    /// before every real name at that seq. That is what makes an attribute and
    /// an event handler unable to share a sequence number, which they never
    /// should: they are two source positions.
    fn take_attribute_slot(seq: int, name: string, what: string) -> bool {
        if !self.in_attributes {
            self.faults.push("{what} {seq}:\"{name}\" is outside an element's attribute run")
            return false
        }
        if seq < self.last_attribute_seq ||
           (seq == self.last_attribute_seq && name <= self.last_attribute_name) {
            self.faults.push(
                "{what} {seq}:\"{name}\" does not follow {self.last_attribute_seq}:\"{self.last_attribute_name}\" in this element's attribute run")
            return false
        }
        self.last_attribute_seq = seq
        self.last_attribute_name = name
        return true
    }

    // ---- elements ---------------------------------------------------------

    pub fn open(seq: int, tag: string) {
        self.note_sibling(seq, false)
        var name: string = tag
        if !tag_name_is_safe(tag) {
            self.faults.push("refused tag name \"{tag}\"")
            name = "span"
        }
        self.frames.push(Frame.open(seq, name))
        self.depth += 1
        self.in_attributes = true
        self.last_attribute_seq = -1
        self.last_attribute_name = ""
        self.enter_scope(SCOPE_ELEMENT)
    }

    pub fn close() {
        if self.top().kind != SCOPE_ELEMENT {
            self.faults.push("close with no open element")
            return
        }
        self.depth -= 1
        self.leave_scope()
        self.in_attributes = false
        self.frames.push(Frame.close)
    }

    // ---- attributes -------------------------------------------------------
    //
    // Escaping is the serializer's job; every value here is the raw text. The
    // URL scheme allowlist is applied HERE, by attribute name, so a call that
    // forgets it cannot exist.

    pub fn attr(seq: int, name: string, value: string) {
        if !self.name_is_writable(name) { return }
        if !self.take_attribute_slot(seq, name, "attribute") { return }
        var safe: string = value
        if is_url_attribute(name) && !scheme_is_allowed(value) {
            safe = INERT_URL
            self.faults.push("attribute {name} carried a refused scheme")
        }
        self.frames.push(Frame.attribute(seq, name, safe))
    }

    /// Name safety, applied before the slot is taken so a refused name does not
    /// consume this element's ordering state.
    fn name_is_writable(name: string) -> bool {
        if !attribute_name_is_safe(name) {
            self.faults.push("refused attribute name \"{name}\"")
            return false
        }
        if attribute_is_inline_handler(name) {
            self.faults.push("refused inline handler attribute \"{name}\"")
            return false
        }
        return true
    }

    /// A boolean attribute: present or absent, never `="false"`. An absent flag
    /// is not nothing — it is a slot that shadows an earlier attribute of the
    /// same name, which is what `emit_attributes` implements and what the
    /// differ has to be able to say.
    pub fn flag(seq: int, name: string, present: bool) {
        if !self.name_is_writable(name) { return }
        if !self.take_attribute_slot(seq, name, "flag") { return }
        self.frames.push(Frame.flag(seq, name, present))
    }

    /// `attrs={self.extra}`. Sorted by name: a `Map` promises no iteration
    /// order, so an unsorted splat would let one render's HTML differ from the
    /// next's for no reason a person could see.
    pub fn attrs(seq: int, extra: Map<string, string>) {
        // The marker takes `(seq, "")`, so it sorts before every name it
        // introduces at the same seq and after everything before it.
        if !self.take_attribute_slot(seq, "", "attrs") { return }
        var names: List<string> = extra.keys()
        names.sort()
        var kept: List<string> = []
        for name: string in names {
            if !attribute_name_is_safe(name) {
                self.faults.push("refused splatted attribute name \"{name}\"")
            } else if attribute_is_inline_handler(name) {
                self.faults.push("refused splatted inline handler \"{name}\"")
            } else if self.take_attribute_slot(seq, name, "attrs entry") {
                kept.push(name)
            }
        }
        self.frames.push(Frame.splat(seq, kept.len()))
        for name: string in kept {
            match extra.get(name) {
                some(value) => {
                    var safe: string = value
                    if is_url_attribute(name) && !scheme_is_allowed(value) {
                        safe = INERT_URL
                        self.faults.push("attribute {name} carried a refused scheme")
                    }
                    self.frames.push(Frame.attribute(seq, name, safe))
                }
                none => {}
            }
        }
    }

    // ---- content ----------------------------------------------------------

    pub fn text(seq: int, body: string) {
        self.note_sibling(seq, false)
        self.frames.push(Frame.text(seq, body))
    }

    /// `$html(expr)` — unescaped, and the only bypass there is.
    pub fn raw(seq: int, html: string) {
        self.note_sibling(seq, false)
        self.frames.push(Frame.raw(seq, html))
    }

    /// A subtree with no expression anywhere inside it, serialized at build
    /// time. `html` is compiler output and trusted; `raw` is not. Two methods
    /// and not one with a flag, so the trusted path cannot be reached by
    /// accident and `$html` stays greppable.
    pub fn constant(seq: int, html: string) {
        self.note_sibling(seq, false)
        self.frames.push(Frame.constant(seq, html))
    }

    // ---- children ---------------------------------------------------------
    //
    // `component<T>` MUST be a method. A free generic function or a static with
    // a `fn(T)` parameter type-checks, runs under `beansc run`, and cannot be
    // built natively — BLOCKERS.md B3.

    pub fn component<T>(seq: int, setup: fn(T)) {
        self.note_sibling(seq, false)
        let described: reflect.Type = type_of(T)
        let slot: int = self.slot_for(seq)
        if !self.children.contains_key(slot) { self.mount<T>(slot, described) }
        match self.children.get(slot) {
            some(stored) => {
                // Two views of one mounted child: `T` for the setter the markup
                // compiler wrote, `Component` for the render call.
                match stored.copy() as? T {
                    some(typed) => { setup(typed) }
                    none => {
                        self.faults.push(
                            "slot {slot} holds a {stored.type().name()}, not a {described.name()}")
                    }
                }
                self.frames.push(Frame.child(seq, described.name(), slot))
                match stored.copy() as? Component {
                    some(child) => { self.render_child(slot, child) }
                    none => {}
                }
            }
            none => { self.frames.push(Frame.child(seq, described.name(), slot)) }
        }
    }

    fn render_child(slot: int, child: Component) {
        let buffer: Builder = self.buffer_for(slot)
        child.on_params_set()
        if buffer.rendered && !child.should_render() { return }
        buffer.render_root(child)
    }

    fn buffer_for(slot: int) -> Builder {
        match self.nested.get(slot) {
            some(existing) => { return existing }
            none => {
                let made: Builder = new Builder()
                made.adopt(self.registry, slot)
                made.fold = self.fold
                self.nested[slot] = made
                return made
            }
        }
    }

    // First render at this slot: activate, and keep the Value the activation
    // produced, whose type is the concrete one.
    fn mount<T>(slot: int, described: reflect.Type) {
        match described.initializer() {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => {
                        match made.copy() as? Component {
                            some(component) => {
                                self.children[slot] = made.copy()
                                component.on_init()
                            }
                            none => {
                                self.faults.push("{described.name()} is not a Component")
                            }
                        }
                    }
                    err(problem) => {
                        self.faults.push(
                            "cannot activate {described.name()}: {problem.message()}")
                    }
                }
            }
            none => {
                self.faults.push("{described.name()} has no zero-argument initializer")
            }
        }
    }

    /// `$slot` and `$slot(expr)`: child content, or any `fn(Builder)`. The body
    /// is numbered in the PARENT's space, so it gets its own scope; and if it
    /// leaves an element open, the builder closes it with a fault rather than
    /// letting it swallow the rest of the child's markup.
    pub fn fragment(seq: int, body: fn(Builder)) {
        self.note_sibling(seq, false)
        self.frames.push(Frame.fragment_open(seq))
        let mark: int = self.scopes.len()
        self.push_path("f{seq}|")
        self.enter_scope(SCOPE_FRAGMENT)
        body(self)
        self.unwind_to(mark + 1)
        self.leave_scope()
        self.pop_path()
        self.frames.push(Frame.fragment_close)
    }

    // ---- keyed lists ------------------------------------------------------
    //
    // `seq` names the LOOP and is the same for every row; `key` names the row.
    // Sequence numbers inside a region start again at 0, so the body of a loop
    // is numbered once no matter how many rows it produces.

    pub fn region(seq: int, key: string) {
        self.note_sibling(seq, true)
        let scope: Scope = self.top()
        var effective: string = key
        match scope.keys.get(key) {
            some(seen) => {
                self.faults.push("duplicate key \"{key}\" in the loop at {seq}")
                effective = "{key}#dup{seen}"
                scope.keys[key] = seen + 1
            }
            none => { scope.keys[key] = 1 }
        }
        self.frames.push(Frame.region_open(seq, effective))
        self.regions += 1
        self.push_path("r{seq}/{effective}|")
        self.enter_scope(SCOPE_REGION)
    }

    pub fn end_region() {
        if self.top().kind != SCOPE_REGION {
            self.faults.push("end_region with no open region")
            return
        }
        self.regions -= 1
        self.leave_scope()
        self.pop_path()
        self.frames.push(Frame.region_close)
    }

    // ---- error boundaries -------------------------------------------------
    //
    // The frames and the substitution live here; the `contained` call that
    // catches the panic lives in `latte.boundary`, because `contained` is
    // refused at check time on wasm targets and the core must keep building
    // for one (PLAN.md, D4).

    pub fn boundary(seq: int) {
        self.note_sibling(seq, false)
        let mark: BoundaryMark = new BoundaryMark()
        mark.frame = self.frames.len()
        mark.seq = seq
        mark.depth = self.depth
        mark.regions = self.regions
        mark.scopes = self.scopes.len()
        mark.paths = self.path.len()
        self.boundaries.push(mark)
        self.frames.push(Frame.boundary_open(seq, false))
        self.push_path("b{seq}|")
        self.enter_scope(SCOPE_BOUNDARY)
    }

    /// The body panicked. Everything it wrote is dropped, the boundary frame is
    /// rewritten as failed — so old-ok against new-failed is a replacement to
    /// the differ and not a silent match — and the caller renders fallback
    /// content in its place before `end_boundary`.
    pub fn fail_boundary(message: string) {
        if self.boundaries.len() == 0 {
            self.faults.push("fail_boundary with no open boundary")
            return
        }
        let mark: BoundaryMark = self.boundaries[self.boundaries.len() - 1]
        for self.frames.len() > mark.frame + 1 {
            let _: Frame = self.frames.items.remove(self.frames.len() - 1)
        }
        self.frames.items[mark.frame] = Frame.boundary_open(mark.seq, true)
        self.depth = mark.depth
        self.regions = mark.regions
        for self.scopes.len() > mark.scopes {
            let _: Scope = self.scopes.remove(self.scopes.len() - 1)
        }
        for self.path.len() > mark.paths {
            let _: string = self.path.remove(self.path.len() - 1)
        }
        self.push_path("b{mark.seq}|")
        self.enter_scope(SCOPE_BOUNDARY)
        self.in_attributes = false
        self.failures.push(message)
    }

    pub fn end_boundary() {
        if self.boundaries.len() == 0 {
            self.faults.push("end_boundary with no open boundary")
            return
        }
        let mark: BoundaryMark = self.boundaries[self.boundaries.len() - 1]
        self.unwind_to(mark.scopes + 1)
        let _: BoundaryMark = self.boundaries.remove(self.boundaries.len() - 1)
        self.leave_scope()
        self.pop_path()
        self.frames.push(Frame.boundary_close)
    }

    /// Close whatever a body left open, loudly. A frame list that is not
    /// balanced is a frame list the serializer, the differ and the applier all
    /// have to guess at, so the guessing happens once, here, with a fault.
    fn unwind_to(target: int) {
        for self.scopes.len() > target {
            let kind: int = self.top().kind
            if kind == SCOPE_ELEMENT {
                self.faults.push("an element was left open")
                self.close()
            } else if kind == SCOPE_REGION {
                self.faults.push("a region was left open")
                self.end_region()
            } else if kind == SCOPE_FRAGMENT {
                self.faults.push("a fragment was left open")
                self.leave_scope()
                self.pop_path()
                self.frames.push(Frame.fragment_close)
            } else if kind == SCOPE_BOUNDARY {
                self.faults.push("a boundary was left open")
                self.end_boundary()
            } else {
                return
            }
        }
    }

    // ---- events -----------------------------------------------------------
    //
    // One named method per event, typed to its family. The handler is stored
    // under its SLOT id, which is the id the wire carries — no name ever
    // crosses, which is what removes mass assignment and reflective invocation
    // from the threat table by construction.

    fn bind_mouse(seq: int, event: string, handler: fn(MouseEvent)) {
        // A refused slot binds nothing: an id registered for a frame that was
        // never written is a live handler the page has no way to reach, and the
        // sweep would keep it alive because slot_for marked it reached.
        if !self.take_attribute_slot(seq, "", "on:{event}") { return }
        let id: int = self.slot_for(seq)
        self.registry.mouse[id] = handler
        self.frames.push(Frame.handler(seq, event, id))
    }

    fn bind_input(seq: int, event: string, handler: fn(InputEvent)) {
        // A refused slot binds nothing: an id registered for a frame that was
        // never written is a live handler the page has no way to reach, and the
        // sweep would keep it alive because slot_for marked it reached.
        if !self.take_attribute_slot(seq, "", "on:{event}") { return }
        let id: int = self.slot_for(seq)
        self.registry.input[id] = handler
        self.frames.push(Frame.handler(seq, event, id))
    }

    fn bind_keyboard(seq: int, event: string, handler: fn(KeyboardEvent)) {
        // A refused slot binds nothing: an id registered for a frame that was
        // never written is a live handler the page has no way to reach, and the
        // sweep would keep it alive because slot_for marked it reached.
        if !self.take_attribute_slot(seq, "", "on:{event}") { return }
        let id: int = self.slot_for(seq)
        self.registry.keyboard[id] = handler
        self.frames.push(Frame.handler(seq, event, id))
    }

    fn bind_submit(seq: int, event: string, handler: fn(SubmitEvent)) {
        // A refused slot binds nothing: an id registered for a frame that was
        // never written is a live handler the page has no way to reach, and the
        // sweep would keep it alive because slot_for marked it reached.
        if !self.take_attribute_slot(seq, "", "on:{event}") { return }
        let id: int = self.slot_for(seq)
        self.registry.submit[id] = handler
        self.frames.push(Frame.handler(seq, event, id))
    }

    fn bind_focus(seq: int, event: string, handler: fn(FocusEvent)) {
        // A refused slot binds nothing: an id registered for a frame that was
        // never written is a live handler the page has no way to reach, and the
        // sweep would keep it alive because slot_for marked it reached.
        if !self.take_attribute_slot(seq, "", "on:{event}") { return }
        let id: int = self.slot_for(seq)
        self.registry.focus[id] = handler
        self.frames.push(Frame.handler(seq, event, id))
    }

    pub fn on_click(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "click", handler) }
    pub fn on_dblclick(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "dblclick", handler) }
    pub fn on_mousedown(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mousedown", handler) }
    pub fn on_mouseup(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mouseup", handler) }
    pub fn on_mouseenter(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mouseenter", handler) }
    pub fn on_mouseleave(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mouseleave", handler) }
    pub fn on_mouseover(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mouseover", handler) }
    pub fn on_mouseout(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mouseout", handler) }
    pub fn on_mousemove(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "mousemove", handler) }
    pub fn on_contextmenu(seq: int, handler: fn(MouseEvent)) { self.bind_mouse(seq, "contextmenu", handler) }

    pub fn on_input(seq: int, handler: fn(InputEvent)) { self.bind_input(seq, "input", handler) }
    pub fn on_change(seq: int, handler: fn(InputEvent)) { self.bind_input(seq, "change", handler) }

    pub fn on_keydown(seq: int, handler: fn(KeyboardEvent)) { self.bind_keyboard(seq, "keydown", handler) }
    pub fn on_keyup(seq: int, handler: fn(KeyboardEvent)) { self.bind_keyboard(seq, "keyup", handler) }
    pub fn on_keypress(seq: int, handler: fn(KeyboardEvent)) { self.bind_keyboard(seq, "keypress", handler) }

    pub fn on_submit(seq: int, handler: fn(SubmitEvent)) { self.bind_submit(seq, "submit", handler) }
    pub fn on_reset(seq: int, handler: fn(SubmitEvent)) { self.bind_submit(seq, "reset", handler) }

    pub fn on_focus(seq: int, handler: fn(FocusEvent)) { self.bind_focus(seq, "focus", handler) }
    pub fn on_blur(seq: int, handler: fn(FocusEvent)) { self.bind_focus(seq, "blur", handler) }
    pub fn on_focusin(seq: int, handler: fn(FocusEvent)) { self.bind_focus(seq, "focusin", handler) }
    pub fn on_focusout(seq: int, handler: fn(FocusEvent)) { self.bind_focus(seq, "focusout", handler) }

    // ---- handles ----------------------------------------------------------

    /// `ref={self.input}`.
    pub fn reference(seq: int, sink: fn(Reference)) {
        if !self.take_attribute_slot(seq, "", "ref") { return }
        let id: int = self.slot_for(seq)
        self.frames.push(Frame.reference(seq))
        let handle: Reference = new Reference()
        handle.node = id
        sink(handle)
    }

    /// `preserve`: render this subtree once and never diff into it. The differ
    /// emits nothing at all for a preserved element — not its attributes and
    /// not its children — because the point is that a third-party library owns
    /// what is under there now.
    pub fn preserve(seq: int) {
        if !self.take_attribute_slot(seq, "", "preserve") { return }
        self.frames.push(Frame.preserve(seq))
    }

    // ---- the render cycle -------------------------------------------------

    /// Starts a new render pass, and ends the one before it.
    ///
    /// The pass that just ended is what decides which mount slots survive: a
    /// slot the pass did not reach — a branch that flipped away, a row that
    /// left a keyed list — is dropped here, its component disposed and its
    /// handlers forgotten, BEFORE the next render can reach that sequence
    /// number again. Frames and faults are per pass; `children`, `nested` and
    /// the handler tables are not.
    pub fn reset() {
        if self.pass_open { self.settle() }
        self.previous = self.frames
        self.frames = new Frames()
        self.diffed = false
        self.faults.clear()
        self.failures.clear()
        self.live.clear()
        self.depth = 0
        self.regions = 0
        self.in_attributes = false
        self.last_attribute_seq = -1
        self.last_attribute_name = ""
        self.boundaries.clear()
        self.scopes.clear()
        self.scopes.push(new Scope(SCOPE_ROOT))
        self.path.clear()
        self.path.push("")
        self.pass_open = true
    }

    /// Ends the pass: closes anything the render left open, loudly, and then
    /// drops every mount slot the pass did not reach — the branch that flipped
    /// away, the row that left a keyed list. Each dropped component is
    /// disposed and its handlers forgotten, so a stale wire id finds nothing
    /// rather than a component that is no longer on the page.
    ///
    /// It has to be a separate call from `reset`: liveness is only known when
    /// the render has finished, so sweeping at the start of the next pass
    /// would leave a removed row mounted for one whole pass. `reset` calls it
    /// for a caller who forgot, but then the faults it raises are cleared with
    /// the pass they belong to.
    pub fn settle() {
        if !self.pass_open { return }
        self.unwind_to(1)
        self.sweep()
        self.pass_open = false
    }

    /// The whole render cycle for one component, so it cannot be got wrong.
    pub fn render_root(component: Component) {
        self.reset()
        component.render(self)
        self.settle()
        self.rendered = true
    }

    fn sweep() {
        var dead: List<string> = []
        var keys: List<string> = self.slots.keys()
        keys.sort()
        for key: string in keys {
            match self.slots.get(key) {
                some(slot) => { if !self.live.contains_key(slot) { dead.push(key) } }
                none => {}
            }
        }
        for key: string in dead {
            match self.slots.get(key) {
                some(slot) => { self.drop_slot(slot) }
                none => {}
            }
            let _: bool = self.slots.remove(key)
        }
    }

    fn drop_slot(slot: int) {
        // Only a slot that actually held a component is a disposal the applier
        // has to hear about. A handler slot leaves with the frame that named
        // it, carried out by the parent's `remove` edit.
        if self.children.contains_key(slot) { self.registry.note_disposed(slot) }
        match self.nested.get(slot) {
            some(buffer) => { buffer.tear_down() }
            none => {}
        }
        let _: bool = self.nested.remove(slot)
        match self.children.get(slot) {
            some(stored) => {
                match stored.copy() as? Component {
                    some(component) => { component.dispose() }
                    none => {}
                }
            }
            none => {}
        }
        let _: bool = self.children.remove(slot)
        self.registry.forget(slot)
    }

    /// Drop this whole buffer and everything under it — the parent's slot for
    /// it went away, so nothing below can be reached again.
    fn tear_down() {
        var slots: List<int> = self.children.keys()
        slots.sort()
        for slot: int in slots { self.drop_slot(slot) }
        var rest: List<int> = self.nested.keys()
        rest.sort()
        for slot: int in rest { self.drop_slot(slot) }
        var handlers: List<string> = self.slots.keys()
        handlers.sort()
        for key: string in handlers {
            match self.slots.get(key) {
                some(slot) => { self.registry.forget(slot) }
                none => {}
            }
        }
        self.slots.clear()
        self.live.clear()
        self.frames.clear()
        self.previous.clear()
        self.rendered = false
    }

    // ---- what the renderer asks afterwards --------------------------------

    pub fn balanced() -> bool {
        return self.depth == 0 && self.regions == 0 &&
               self.boundaries.len() == 0 && self.scopes.len() == 1
    }

    /// This component's frames, one per line. The whole tree is `dump_tree`.
    pub fn dump() -> string { return self.frames.dump() }

    /// Every buffer in the tree, parent first, each headed by its component id.
    pub fn dump_tree() -> string {
        var out: string = "component {self.id}\n{self.frames.dump()}"
        var slots: List<int> = self.nested.keys()
        slots.sort()
        for slot: int in slots {
            match self.nested.get(slot) {
                some(buffer) => { out = "{out}{buffer.dump_tree()}" }
                none => {}
            }
        }
        return out
    }

    /// Faults from this buffer and every buffer under it, so a test asserts one
    /// number rather than walking the tree itself.
    pub fn all_faults() -> List<string> {
        var out: List<string> = []
        for fault: string in self.faults { out.push("{self.id}: {fault}") }
        var slots: List<int> = self.nested.keys()
        slots.sort()
        for slot: int in slots {
            match self.nested.get(slot) {
                some(buffer) => {
                    for fault: string in buffer.all_faults() { out.push(fault) }
                }
                none => {}
            }
        }
        return move out
    }

    /// The buffer holding a mounted child's frames.
    pub fn child_buffer(slot: int) -> Option<Builder> { return self.nested.get(slot) }
}
