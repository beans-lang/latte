// `latte.Builder` — what generated markup calls, and the one component's
// frame buffer it fills.
//
// Every `.bx` file compiles to a sequence of calls against this class's
// public methods, so its public shape is the contract between markup and the
// code the compiler emits for it (see bx/emit.b).
//
// Nothing here imports std.io, std.fs or std.net: `test.sh --wasm` builds the
// core for wasm32-unknown-unknown, and one OS-bound import at this level
// would break that build.
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
/// a component tag opens no element. The compiler compiles it to an assignment
/// inside the setup closure instead — `b.component<Grid>(18, fn(c: Grid) {
/// self.grid = some(c) })` — which hands back the CONCRETE type rather than a
/// `Component` needing a downcast, and fills it at mount rather than after a
/// render. An element ref genuinely cannot be filled before the applier has
/// run, which is why that one stays a `fn(Reference)` sink.
pub class Reference {
    pub node: int = -1
    pub fn init() {}
}

// ---------------------------------------------------------------- component
/// What the framework writes into a component when it mounts it: which slot
/// the component lives at, and where to send "I changed".
///
/// It exists as ONE object rather than two fields on `Component` because of a
/// rule about inheritance, not about taste:
///
/// > `error: field 'id' redeclares a field 'Child' inherits from 'Base' — an
/// > inherited field name is a slot the base already owns, so a subclass
/// > cannot declare it again`
///
/// Every field name this base class takes is a name **no component an author
/// writes may ever use**, and making the base field non-`pub` does not help —
/// the error is about the slot, not the visibility. `id` is the most likely
/// field name in a page there is (`@param id`, a row's id, a record's id), so
/// the framework does not take it. A subclass field MAY share a name with a
/// base **method**, which is why `Component.id()` is a method and costs an
/// author nothing.
pub class MountHandle {
    /// The component's slot id: its mount key, its handler-id space and its
    /// wire id, all one int.
    ///
    /// `-1` until something mounts it, and deliberately **not** 0: 0 is the
    /// page root, so a component nothing has mounted would otherwise mark the
    /// whole page dirty the first time it called `notify()`.
    pub id: int = -1

    /// Where `notify()` goes. Weak for the same reason `Callback.owner` is:
    /// not to break a cycle — the renderer owns the component tree, so the
    /// back edge is the only one in the design with no reason to exist — but
    /// so that a `notify()` raised after the page has closed reads `none` and
    /// does nothing, instead of marking a renderer that is gone.
    pub weak sink: Option<DirtySink> = none

    /// The `@memo` snapshot of this component's parameters, or `none`.
    ///
    /// Framework-owned: a `@memo` component gets one at its first parameter
    /// pass and never sees it. A component without `@memo` never gets one, and
    /// `params_changed()` answers `true` — so nothing about rendering changes
    /// for a component that did not ask.
    pub memo: Option<ParamWatch> = none

    /// The page this component was mounted into, which is the object a
    /// `Signal` read has to reach to find the live expression currently being
    /// evaluated (`signal.b`, `Cell`). Weak for the same reason `sink` is: the
    /// page owns the Builder that owns this Registry, and this is the edge
    /// back.
    ///
    /// It is on the handle rather than on `Component` because every field name
    /// this base takes is a name no component an author writes may ever use —
    /// the reason `MountHandle` exists at all.
    pub weak page: Option<Registry> = none

    pub fn init() {}
}

pub class Component {
    /// The framework's own hook into this component, written at mount. An
    /// author reads `id()` and calls `notify()`; nothing else in here is
    /// theirs to touch.
    pub mount: MountHandle = new MountHandle()

    /// This component's slot id, or `-1` before anything has mounted it.
    ///
    /// A METHOD and not a field, so `id` stays a name a component may declare.
    /// It is needed at all because Beans has no reference equality: nothing
    /// outside can ask "which component is this `Component`", so a `Callback`
    /// could not name the component it has to mark without it.
    pub fn id() -> int { return self.mount.id }

    /// "My own state changed; render me."
    ///
    /// The ordinary event path does not need this — `Registry.fire_*` tells
    /// the renderer which component bound the id it just dispatched, so an
    /// author who forgets still gets the render they meant. This is for state
    /// that changes outside an event: a timer, a channel, a parent's
    /// `Callback`.
    ///
    /// It does nothing for a component nothing has mounted. Marking an id the
    /// renderer no longer holds is dropped there, and slot ids are never
    /// reused (`Registry.fresh` only counts up), so a stale id can never name
    /// a different live component.
    pub fn notify() {
        if self.mount.id < 0 { return }
        match self.mount.sink {
            some(sink) => { sink.mark(self.mount.id) }
            none => {}
        }
    }

    /// The one method the markup compiler writes. It takes the builder rather
    /// than returning a fragment, so a markup block is a plain statement.
    pub fn render(b: Builder) {}

    // Lifecycle. These are declared and called HERE because mounting happens
    // here — `component<T>` is the only place a child is activated, its
    // parameters are set, and its render is gated. Any subclass may override
    // them.
    //
    // `on_after_render` is deliberately absent: it would fire once a batch has
    // been applied to the real DOM, and only the renderer (render.b) knows
    // when that happens.

    /// Once, immediately after activation, before the first `on_params_set`.
    pub fn on_init() {}

    /// After the parent's setter has written this render's parameters, on
    /// every render including the first.
    pub fn on_params_set() {}

    /// Consulted before every render after the first. A component that
    /// answers false keeps the frames it already has.
    pub fn should_render() -> bool { return true }

    /// The framework's parameter pass: the author's `on_params_set`, and then
    /// the `@memo` snapshot if this type has one.
    ///
    /// One method and not two call sites, because the two must never drift:
    /// a component whose parameters were recorded without `on_params_set`
    /// having run would memoize against values its own code had not seen.
    pub fn params_arrived() {
        self.on_params_set()
        match self.mount.page {
            some(registry) => { registry.note_params(self) }
            none => {}
        }
    }

    /// Whether this component's parameters differ from the last render's.
    ///
    /// **`true` for a component with no `@memo`**, which is every component
    /// unless it asked. A memo is a component saying "skip me when nothing
    /// changed"; the absence of one cannot mean "skip me".
    pub fn params_changed() -> bool {
        match self.mount.memo {
            some(watch) => { return watch.differs() }
            none => { return true }
        }
    }

    /// When the slot that mounted this component is not reached by a render
    /// pass, so the component is dropped.
    pub fn dispose() {}
}

// ---------------------------------------------------------------- callback
/// The event-out type. It holds a **weak** owner — not to break a cycle (the
/// handler closure captures `self` on its own, and the cycle collector is
/// what kills that) but so a callback fired after its owner is gone reads
/// `none` and does nothing instead of marking a dead component dirty. The
/// weak read turns `none` before the referent's `deinit` body runs, so it can
/// never resurrect anything. `probes/p6_cycle` runs both properties.
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

    /// Run the handler, then mark the owner dirty.
    ///
    /// The `notify()` is what makes a callback worth having: a child hands its
    /// parent a `Callback`, the child fires it, and the code that runs is the
    /// PARENT's — so the component the renderer would otherwise mark (the one
    /// that bound the DOM handler, which is the child) is the wrong one.
    ///
    /// A disposed owner that something still holds a reference to does reach
    /// the renderer through here, and that is safe rather than accidental:
    /// `Renderer.mark` drops an id it no longer holds, and ids are never
    /// reused, so a stale id cannot name a different live component.
    pub fn call(value: T) {
        match self.owner {
            some(owner) => { self.handler(value); owner.notify() }
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
/// Where a component's `@inject` fields come from.
///
/// An interface over `reflect` and nothing else, so latte's core needs no
/// dependency on a container: `latte_app` implements it over barista, and a
/// host with some other idea implements it over that. The core never learns
/// what a service collection is.
pub interface ServiceSource {
    fn provide(described: reflect.Type) -> Result<reflect.Value, string>

    /// Whether this source could answer for `described` — without building
    /// anything.
    ///
    /// It is what makes `scan_injections` possible: a whole application's
    /// `@inject` fields can be checked at startup, once, instead of each one
    /// failing at the render that needed it. A question that has to construct
    /// the object to be asked is not a question you can ask about two hundred
    /// components.
    fn knows(described: reflect.Type) -> bool
}

/// What the framework does to one component type at mount, worked out once.
///
/// A class around the lists and not bare `List`s, because a list of these is
/// move-only: reading one out of the cache would take it out of the cache. A
/// class is a reference, so the map keeps it and every mount borrows the same
/// one.
pub class MountPlan {
    /// `@inject` fields, and what each needs.
    pub bindings: List<InjectBinding> = []
    /// `Signal` fields the framework owns against the component, so an author
    /// stops writing `self.x.own(self)` once per signal in `on_init` — and
    /// stops shipping a signal that records nothing because they forgot.
    pub signals: List<reflect.Field> = []
    /// `ViewModel` fields the framework attaches to the component, and whose
    /// own signals it owns.
    pub models: List<reflect.Field> = []
    /// What `@memo` compares on this type, if it carries one.
    pub memo: MemoPlan = new MemoPlan()
    fn init() {}
}

/// One `@inject` field, resolved to what it needs.
class InjectBinding {
    field: reflect.Field
    wanted: reflect.Type
    fault: string = ""

    fn init(field: reflect.Field, wanted: reflect.Type) {
        self.field = field
        self.wanted = wanted
    }
}

/// One scalar parameter, as text the memo can compare.
///
/// Interpolation and not a cast, because what is compared has to be one type,
/// and a `float` and an `int` that both read `2` are two different parameters
/// only if their fields are two different fields — which they are, and the
/// position in the list says so.
fn scalar_text(value: reflect.Value, kind: ParamKind) -> string {
    match kind {
        text => {
            match value as? string { some(held) => { return held } none => { return "?" } }
        }
        integer => {
            match value as? int { some(held) => { return "{held}" } none => { return "?" } }
        }
        boolean => {
            match value as? bool { some(held) => { return "{held}" } none => { return "?" } }
        }
        number => {
            match value as? float { some(held) => { return "{held}" } none => { return "?" } }
        }
        other => { return "?" }
    }
}

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

    /// The page's dirty sink, kept once here rather than copied into every
    /// Builder, so a component mounted anywhere in the tree can be handed it
    /// at mount. Weak: the renderer owns the root Builder, which owns this, so
    /// a strong edge back would be a cycle that lives for the whole page.
    weak sink: Option<DirtySink> = none

    /// The live expression being evaluated right now, or `none`.
    ///
    /// It lives here because it belongs to the PAGE: a `Signal` read records
    /// itself into whatever binding is open, and both the reader and the
    /// builder that opened it have to agree on one location. `signal.b`'s
    /// `Cell` says why this is not a module-level singleton or a static.
    ///
    /// Held strongly and only for the duration of one thunk — `Builder.watch`
    /// restores whatever it displaced — so it is never a cycle that outlives a
    /// statement.
    watched: Option<LiveBinding> = none

    /// Where `@inject` fields come from, or `none` for a page with no
    /// container. A component with no `@inject` field never asks.
    pub services: Option<ServiceSource> = none

    /// The `@inject` plan per component type, worked out on first mount of
    /// that type and kept for the life of the page. A type's fields and their
    /// annotations cannot change while a program runs, and a page that mounts
    /// two hundred rows of one component should reflect over it once.
    mount_plans: Map<string, MountPlan> = {}

    /// Live-binding ids, page-unique and separate from the slot counter so a
    /// binding never spends a wire id.
    next_binding: int = 1

    pub fn init() {}

    pub fn watching() -> Option<LiveBinding> { return self.watched }

    /// Everything the framework does to one type at mount.
    pub fn mount_plan(described: reflect.Type) -> MountPlan {
        let key: string = described.qualified_name()
        match self.mount_plans.get(key) {
            some(found) => { return found }
            none => {}
        }
        let model_name: string = type_of(ViewModel).qualified_name()
        var plan: MountPlan = new MountPlan()
        plan.memo = memo_plan_for(described)
        for field: reflect.Field in described.fields() {
            var wanted: bool = false
            for use: reflect.Annotation in field.annotations() {
                if use.qualified_name() == "latte.inject" { wanted = true }
            }
            if wanted {
                var binding: InjectBinding = new InjectBinding(field, field.type())
                if !field.is_public() {
                    binding.fault =
                        "{key}.{field.name()} is @inject but is not public, and reflection does not bypass visibility"
                }
                plan.bindings.push(binding)
            }
            // A Signal is generic, so nothing can downcast one — `as?` cannot
            // name an instantiation. The name is the test, and it is exact
            // enough: `latte.Signal<` cannot be any other declaration.
            if field.type().qualified_name().starts_with("latte.Signal<") {
                if field.is_public() { plan.signals.push(field) }
            }
            if type_of(ViewModel).is_assignable_from(field.type()) &&
               field.type().qualified_name() != model_name {
                if field.is_public() { plan.models.push(field) }
            }
        }
        self.mount_plans[key] = plan
        return plan
    }

    /// Record this render's parameters for a `@memo` component.
    ///
    /// Called after every `on_params_set`, at all three sites the framework
    /// runs one — a component's record of what its parameters were must not
    /// depend on who asked for the render.
    fn note_params(component: Component) {
        let boxed: reflect.Value = reflect.value(component)
        let plan: MountPlan = self.mount_plan(boxed.type())
        if !plan.memo.present { return }
        if plan.memo.faults.len() > 0 { return }
        match component.mount.memo {
            none => { component.mount.memo = some(new ParamWatch()) }
            some(_) => {}
        }
        var values: List<string> = []
        var index: int = 0
        for field: reflect.Field in plan.memo.params {
            match field.get(boxed.copy()) {
                err(problem) => { values.push("?") }
                ok(value) => { values.push(scalar_text(value, plan.memo.kinds[index])) }
            }
            index += 1
        }
        match component.mount.memo {
            some(watch) => { watch.record(values) }
            none => {}
        }
    }

    /// Own one `Signal` field against `owner`.
    ///
    /// `Signal<T>` is generic and cannot be downcast to, but `Cell` — the half
    /// that holds the subscribers and the owner link — is not. So the signal is
    /// read reflectively, its `cell` is read out of it, and THAT downcasts.
    /// `probes/p_signal_own` runs this shape on both backends; it is
    /// BLOCKERS.md B1a's exact case, and it only works on 0.1.41 or newer.
    fn own_signal(field: reflect.Field, receiver: reflect.Value,
                  owner: Component) -> string {
        match field.get(receiver.copy()) {
            err(problem) => {
                return "cannot read signal {field.name()}: {problem.message()}"
            }
            ok(signal) => {
                match signal.type().field("cell") {
                    none => { return "{field.name()} has no reflective cell" }
                    some(cell_field) => {
                        match cell_field.get(signal.copy()) {
                            err(problem) => {
                                return "cannot read {field.name()}.cell: {problem.message()}"
                            }
                            ok(cell_value) => {
                                match cell_value as? Cell {
                                    none => { return "{field.name()}.cell is not a Cell" }
                                    some(cell) => {
                                        cell.own(owner)
                                        return ""
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Everything the framework does to a freshly built component: fill its
    /// `@inject` fields, own its signals, attach its view-models.
    ///
    /// Answers what could not be done. An empty list is the ordinary case, and
    /// a component with none of the three never reaches the source at all.
    fn adopt(receiver: reflect.Value, described: reflect.Type,
             owner: Component) -> List<string> {
        var problems: List<string> = []
        let plan: MountPlan = self.mount_plan(described)
        for problem: string in self.inject(receiver.copy(), described) {
            problems.push(problem)
        }
        for field: reflect.Field in plan.signals {
            let problem: string = self.own_signal(field, receiver.copy(), owner)
            if problem != "" {
                problems.push("{described.qualified_name()}.{problem}")
            }
        }
        for field: reflect.Field in plan.models {
            match field.get(receiver.copy()) {
                err(problem) => {
                    problems.push(
                        "{described.qualified_name()}.{field.name()}: {problem.message()}")
                }
                ok(value) => {
                    match value as? ViewModel {
                        none => {}
                        some(model) => {
                            // The model's own signals belong to the same
                            // component: a signal on a view-model has to reach
                            // the page the view is on, and the model is not on
                            // a page.
                            let inner: MountPlan = self.mount_plan(value.type())
                            for signal: reflect.Field in inner.signals {
                                let problem: string =
                                    self.own_signal(signal, value.copy(), owner)
                                if problem != "" {
                                    problems.push("{value.type().qualified_name()}.{problem}")
                                }
                            }
                            model.attach(owner)
                        }
                    }
                }
            }
        }
        return move problems
    }

    /// Fill one freshly built component's `@inject` fields.
    fn inject(receiver: reflect.Value, described: reflect.Type) -> List<string> {
        var problems: List<string> = []
        let plan: MountPlan = self.mount_plan(described)
        if plan.bindings.len() == 0 { return move problems }
        match self.services {
            none => {
                for binding: InjectBinding in plan.bindings {
                    problems.push(
                        "{described.qualified_name()}.{binding.field.name()} is @inject, but this page has no service container to fill it from")
                }
                return move problems
            }
            some(source) => {
                for binding: InjectBinding in plan.bindings {
                    if binding.fault != "" {
                        problems.push(binding.fault)
                        continue
                    }
                    match source.provide(binding.wanted) {
                        err(problem) => {
                            problems.push(
                                "{described.qualified_name()}.{binding.field.name()}: {problem}")
                        }
                        ok(value) => {
                            match binding.field.set(receiver.copy(), value) {
                                ok(_) => {}
                                err(problem) => {
                                    problems.push(
                                        "{described.qualified_name()}.{binding.field.name()}: {problem.message()}")
                                }
                            }
                        }
                    }
                }
            }
        }
        return move problems
    }

    /// Open a live evaluation, answering what it displaced. Nesting is not
    /// something latte generates, but a thunk that writes a signal reaches
    /// another thunk through `Cell.fire`, so save-and-restore is the only
    /// correct spelling.
    fn watch_open(binding: LiveBinding) -> Option<LiveBinding> {
        let previous: Option<LiveBinding> = self.watched
        self.watched = some(binding)
        return previous
    }

    fn watch_close(previous: Option<LiveBinding>) { self.watched = previous }

    /// No live evaluation is open. Called when a pass is torn down or unwound,
    /// so a binding cannot survive as "currently evaluating" past the render
    /// that opened it.
    fn watch_clear() { self.watched = none }

    fn fresh_binding() -> int {
        let value: int = self.next_binding
        self.next_binding += 1
        return value
    }

    fn note_disposed(id: int) { self.disposed.push(id) }

    /// Called once, by the renderer, through `Builder.attach_sink`.
    fn attach(sink: DirtySink) { self.sink = some(sink) }

    /// The page's sink, or `none` for a Builder tree nothing is rendering —
    /// which is what a test that drives a Builder by hand looks like, and what
    /// makes `notify()` a no-op there rather than a crash.
    fn dirty_sink() -> Option<DirtySink> { return self.sink }

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
    /// How many slots the pass had reached when this boundary opened. Anything
    /// the body went on to reach dies with the body.
    pub touched: int = 0
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
    /// of stale or wrong content can be compared against the unfolded form
    /// directly by setting this to `false`.
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

    /// The live expressions this pass created, in document order. Retired and
    /// emptied by `reset`, so a binding never outlives the frame list it was
    /// measured against.
    pub bindings: List<LiveBinding> = []

    /// Edits a signal write produced since the last render, ready to send: no
    /// render ran and no diff ran, so nothing else in the pipeline knows about
    /// them. `Renderer.batch` is what drains this.
    pub pending: List<Edit> = []

    /// Signal edits that were queued BEFORE the render that is now waiting to
    /// be diffed, and that must therefore go out ahead of that render's edits.
    ///
    /// They cannot simply stay in `pending`, and they cannot be dropped
    /// either. Dropping them loses the write: `reset()` assigns
    /// `previous = frames`, and a signal write rewrote a body inside `frames`
    /// in place, so the mutation ends up on BOTH sides of the next diff and
    /// the differ is blind to it — the client is left holding the value from
    /// before the write. `tests/renders.b` has the regression case.
    ///
    /// The order is what makes them valid: a queued edit's child indices were
    /// measured against a frame list whose STRUCTURE is the one the client
    /// holds — a signal changes a text body and never the shape — so applying
    /// it first walks the client from what it has to `previous`, and the diff
    /// then walks it from `previous` to `frames`. That composition is only
    /// sound because a buffer is never rendered twice between two batches,
    /// which is `Renderer.flush` rule 1.
    pub carry: List<Edit> = []

    slots: Map<string, int> = {}
    live: Map<int, bool> = {}
    /// The slot keys this pass has resolved, in order. `fail_boundary` needs
    /// to know which ones the failed body reached, and a Map cannot say.
    touched: List<string> = []
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
        self.touched.push(key)
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

    /// Interpolated text inside a `live` subtree: a thunk instead of a value.
    ///
    /// It writes the same `Frame.text` `text` does — the serializer, the
    /// differ and the applier are told nothing new, and a page that never
    /// writes a signal behaves exactly as if `live` had not been written. What
    /// it adds is the binding: the thunk is evaluated with this expression
    /// open, so every `Signal.get()` inside it records itself, and a later
    /// write re-invokes THIS thunk and rewrites THIS frame.
    ///
    /// A live expression that recorded no signal is a fault, and it is the
    /// only new refusal this tier needs. Without it, `live` on a subtree with
    /// no signal in it — or a signal whose `own(self)` was forgotten — renders
    /// once, correctly, and then never moves again, and nothing anywhere says
    /// so. That is the exact failure RULES.md calls the fallback happy path,
    /// and it would be invisible in a green run.
    pub fn live_text(seq: int, body: fn() -> string) {
        self.note_sibling(seq, false)
        let binding: LiveBinding = new LiveBinding(
            self.registry.fresh_binding(), self, self.frames.len(), seq, body)
        self.bindings.push(binding)
        let rendered: string = self.watch(binding)
        if binding.dependencies() == 0 {
            self.faults.push("live expression {seq} read no signal")
        }
        self.frames.push(Frame.text(seq, rendered))
    }

    /// Evaluate a binding's thunk with that binding open, so reads record.
    fn watch(binding: LiveBinding) -> string {
        binding.unsubscribe()
        let displaced: Option<LiveBinding> = self.registry.watch_open(binding)
        let rendered: string = binding.body()
        self.registry.watch_close(displaced)
        return rendered
    }

    /// A signal one of this buffer's live expressions read has changed.
    ///
    /// Called from `LiveBinding.refresh`, which `Cell.fire` calls, which
    /// `Signal.set` calls. Nothing on this path touches the dirty set, so
    /// `Renderer.flush` has nothing to do and `render_count` cannot move: no
    /// code on this path ever calls `mark`.
    fn refresh_binding(binding: LiveBinding) {
        if binding.index < 0 || binding.index >= self.frames.len() {
            binding.retire()
            return
        }
        var was: string = ""
        var matched: bool = false
        match self.frames.at(binding.index) {
            text(seq, body) => {
                if seq == binding.seq { was = body; matched = true }
            }
            _ => {}
        }
        if !matched {
            // The frame this binding was measured against is not there any
            // more. Only an unbalanced hand-assembled buffer reaches this;
            // retiring is the answer that cannot write into someone else's
            // frame.
            binding.retire()
            return
        }
        let rendered: string = self.watch(binding)
        if rendered == was { return }
        self.frames.set(binding.index, Frame.text(binding.seq, rendered))
        if binding.pending_at >= 0 && binding.pending_at < self.pending.len() {
            self.pending[binding.pending_at] = Edit.set_text(
                self.live_index(binding), rendered)
            return
        }
        binding.pending_at = binding.emit(self.frames, rendered, self.pending)
    }

    /// The child index a binding's `set_text` names, for rewriting an edit
    /// that is already queued.
    fn live_index(binding: LiveBinding) -> int {
        match self.pending[binding.pending_at] {
            set_text(index, _) => { return index }
            _ => { return -1 }
        }
    }

    /// Take the signal edits queued before the pending render. They lead the
    /// batch; see `carry`.
    pub fn take_carry(out: List<Edit>) {
        for edit: Edit in self.carry { out.push(edit) }
        self.carry.clear()
    }

    /// Take the signal edits this buffer has queued since its last render. The
    /// renderer calls it once per batch, so a queued edit crosses the wire
    /// exactly once.
    pub fn take_pending(out: List<Edit>) {
        for edit: Edit in self.pending { out.push(edit) }
        self.drop_pending()
    }

    /// Forget the queue without sending it. `Renderer.batch` does this for a
    /// buffer that re-rendered AFTER the write: the mutation is in `frames`
    /// and `previous` is the list from before the render, so the diff carries
    /// it already — and the queued edit's child indices were measured against
    /// a frame list the client has not reached yet.
    pub fn drop_pending() {
        self.pending.clear()
        for binding: LiveBinding in self.bindings { binding.pending_at = -1 }
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
        let slot: int = self.open_slot(seq)
        if !self.children.contains_key(slot) { self.mount<T>(slot, type_of(T)) }
        self.fill_slot<T>(seq, slot, setup)
    }

    /// The same mount, from a factory closure the markup compiler emits
    /// instead of a reflective activation.
    ///
    /// It exists because reflection cannot construct every component and the
    /// way it fails is silent. A **closed generic** has no initializer
    /// descriptor at all (B1); a **non-generic subclass of a closed generic**
    /// has one that constructs under `beansc run` and answers `unsupported`
    /// natively (B7) — a page that works all through the edit loop and breaks
    /// when someone ships it. `make` is `fn() -> Grid<Order> { return new
    /// Grid<Order>() }` in the generated file, where the type is written out
    /// and no reflection is involved in building it.
    ///
    /// An INSTANCE method, like `component<T>`: a free generic function or a
    /// `static fn` taking a `fn(T)` type-checks, runs under `beansc run`, and
    /// cannot be built natively (B3). `probes/p10_factory_mount` runs this
    /// whole shape — including `as? T` back to a closed generic — on both
    /// backends, with a control that reproduces B7's split so a green run
    /// cannot be one that never reached the hazard.
    pub fn component_made<T>(seq: int, make: fn() -> T, setup: fn(T)) {
        let slot: int = self.open_slot(seq)
        if !self.children.contains_key(slot) { self.mount_made<T>(slot, make) }
        self.fill_slot<T>(seq, slot, setup)
    }

    /// A component tag's position in the frame list, resolved to its slot id.
    fn open_slot(seq: int) -> int {
        self.note_sibling(seq, false)
        return self.slot_for(seq)
    }

    /// Everything the two mount routes share: run the setter against the
    /// child's own type, write the leaf frame, render the child.
    ///
    /// One implementation and not two, because two would drift and only one of
    /// them would be the one the tests run — and the half that would drift is
    /// the half that decides what a re-render does.
    fn fill_slot<T>(seq: int, slot: int, setup: fn(T)) {
        let described: reflect.Type = type_of(T)
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
        child.params_arrived()
        if buffer.rendered && !child.should_render() { return }
        // The memo is asked SECOND and separately, so a component that has both
        // a `@memo` and a hand-written `should_render` needs both to agree
        // before it renders. Neither can quietly override the other.
        if buffer.rendered && !child.params_changed() { return }
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
                                self.wire(component, slot)
                                // Before `on_init`, so a component can use an
                                // injected service in the one place it is meant
                                // to set itself up.
                                for problem: string in self.registry.adopt(
                                        made.copy(), made.type(), component) {
                                    self.faults.push(problem)
                                }
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

    // First render at this slot, from a factory. Nothing reflective builds the
    // object; `reflect.value` still boxes it, and it boxes the STATIC type `T`
    // (B6) — which here IS the concrete one, because the caller wrote it out.
    fn mount_made<T>(slot: int, make: fn() -> T) {
        let fresh: T = make()
        let boxed: reflect.Value = reflect.value(fresh)
        match boxed.copy() as? Component {
            some(component) => {
                self.children[slot] = boxed.copy()
                self.wire(component, slot)
                // The same adopt pass `mount` runs, and it has to be here too:
                // a `@page` under a `@layout` is mounted through THIS route,
                // not that one — `LayoutLink.render_body` places the next link
                // with `component_made`. Without it a page with a layout got no
                // `@inject` fields, no owned signals and no attached
                // view-model, while the same page without a layout got all
                // three. The demo found it: a Command whose `on_attach` never
                // ran answered "cannot run" to every click, and the server
                // replied "your message changed nothing".
                //
                // `boxed.type()` and not `type_of(T)`: T here is whatever the
                // caller wrote, and the layout chain writes `Component`.
                // `reflect.value` boxes the runtime type (beans #163), so this
                // is the concrete class.
                for problem: string in self.registry.adopt(
                        boxed.copy(), boxed.type(), component) {
                    self.faults.push(problem)
                }
                component.on_init()
            }
            none => { self.faults.push("{type_of(T).name()} is not a Component") }
        }
    }

    /// Hand a freshly mounted component its identity: the slot it lives at,
    /// and the page's dirty sink.
    ///
    /// Before `on_init`, because a component that subscribes to something in
    /// `on_init` may call `notify()` from the callback that subscription
    /// installs, and a component whose handle is still empty would mark
    /// nothing.
    fn wire(component: Component, slot: int) {
        component.mount.id = slot
        component.mount.sink = self.registry.dirty_sink()
        component.mount.page = some(self.registry)
    }

    /// Wire this page to its dirty sink.
    ///
    /// The Registry keeps it, so every component mounted from here on is handed
    /// it at mount without any Builder carrying a copy. `page` is the root
    /// component, which nothing mounts, so it is wired here — with this
    /// buffer's own id, which for the root buffer is 0.
    pub fn attach_sink(sink: DirtySink, page: Component) {
        self.registry.attach(sink)
        page.mount.id = self.id
        page.mount.sink = some(sink)
        page.mount.page = some(self.registry)
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
        // The body can close this fragment's own scope out from under it, and
        // exactly one call does: `end_boundary()` from inside the body unwinds
        // every scope above the boundary's, which includes this one — it
        // raises "a fragment was left open" and writes the closing frame
        // itself. Closing again below would write a SECOND `fragment_close`,
        // and an unmatched close is not a cosmetic problem: the serializer,
        // the differ and the applier all read it as this fragment's, so every
        // sibling after it lands inside a container that has already ended and
        // is silently dropped — no fault on any of the three.
        //
        // `fragment` is the only scope-owning call that needs this test,
        // because it is the only one that is a single call. `close`,
        // `end_region` and `end_boundary` are each the second half of a pair
        // and already refuse when the scope they were going to close is not
        // the one on top.
        if self.scopes.len() <= mark { return }
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
    // catches the panic lives in `latte.boundary` instead, because `contained`
    // is refused at check time on wasm targets and this file has to keep
    // building for one.

    pub fn boundary(seq: int) {
        self.note_sibling(seq, false)
        let mark: BoundaryMark = new BoundaryMark()
        mark.frame = self.frames.len()
        mark.seq = seq
        mark.depth = self.depth
        mark.regions = self.regions
        mark.scopes = self.scopes.len()
        mark.paths = self.path.len()
        mark.touched = self.touched.len()
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
        // The body's frames are gone, so the live expressions that wrote them
        // are measured against indices this list no longer has. They unwind
        // with the slots, for the same reason and one line further down.
        self.drop_bindings_since(mark.frame)
        // Slots are the sixth thing the body wrote, and they unwind like the
        // other five. A component mounted inside the failed body is no longer
        // on the page, so leaving it mounted would keep its `dispose` from ever
        // running and leave its handlers reachable by a wire id for content
        // nobody can see. It would also hand the differ a buffer with unsent
        // frames whose mount frame the truncation removed, which reaches the
        // applier as "update for component N arrived before its mount".
        //
        // Dropping them is also what lets the fallback number itself from 0
        // again — which it does, because the scope restarts — without landing
        // on the slot ids the truncated body had already taken at those very
        // numbers.
        self.drop_touched_since(mark.touched)
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

    /// Retire every live binding whose frame the truncation removed, and stop
    /// any evaluation that was open when the body panicked.
    fn drop_bindings_since(frame: int) {
        var kept: List<LiveBinding> = []
        for binding: LiveBinding in self.bindings {
            if binding.index > frame { binding.retire() } else { kept.push(binding) }
        }
        self.bindings.clear()
        for binding: LiveBinding in kept { self.bindings.push(binding) }
        self.registry.watch_clear()
    }

    /// Drop every slot the pass reached after `mark`, disposing what they held.
    /// Used by `fail_boundary`: the body's frames are gone, so its mounts, its
    /// handlers and its references are gone with them.
    fn drop_touched_since(mark: int) {
        for self.touched.len() > mark {
            let key: string = self.touched.remove(self.touched.len() - 1)
            match self.slots.get(key) {
                some(slot) => {
                    self.drop_slot(slot)
                    let _: bool = self.slots.remove(key)
                    let _: bool = self.live.remove(slot)
                }
                none => {}
            }
        }
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
        self.touched.clear()
        // Signal edits queued against the list that is about to become
        // `previous` still have to be sent, and now have to be sent FIRST.
        for edit: Edit in self.pending { self.carry.push(edit) }
        self.drop_pending()
        // Every binding measured itself against the frame list that just
        // became `previous`. Retiring them here — rather than letting the
        // render replace them — is what stops a signal write between two
        // renders from rewriting a frame in a list nothing holds any more, and
        // it is also the unsubscribe: a component that stopped reading a
        // signal stops being woken by it.
        for binding: LiveBinding in self.bindings { binding.retire() }
        self.bindings.clear()
        self.registry.watch_clear()
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
        // A component rendered by this buffer belongs to this buffer's page,
        // whatever else has or has not wired it. `wire` covers every child and
        // `attach_sink` covers the root of a rendered page; this covers the
        // root of a Builder tree nobody is rendering — a hand-driven buffer in
        // a suite — so the live tier does not quietly need a Renderer to work.
        // It does not touch `id` or `sink`: a component nothing mounted still
        // must not be able to mark a dirty set it is not in.
        component.mount.page = some(self.registry)
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
        //
        // EVERY component disposal is reported, including one for a component
        // whose mount frame never reached the client — which is what a failed
        // error boundary does to everything its body mounted in the same pass.
        // The builder cannot tell those apart: whether a mount frame was
        // announced is a fact about which batches have been sent, not about
        // this buffer, and a nested buffer that did not re-render this pass
        // cannot even say which of ITS slots are new. Over-reporting is free —
        // the applier drops what it holds and ignores the rest — while
        // under-reporting leaves a root node in the applier for a component
        // that has left the page, forever, with nothing rendering it and
        // nothing able to see it.
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
        for binding: LiveBinding in self.bindings { binding.retire() }
        self.bindings.clear()
        // A queued signal edit for a component that has left the page is an
        // edit addressed to a node the applier is about to drop. The disposal
        // is what the client is told; the edit would arrive after it.
        self.pending.clear()
        self.carry.clear()
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
