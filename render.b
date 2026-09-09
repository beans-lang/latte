// `latte.Renderer` — the dirty set the framework renders from.
//
// The page is never re-rendered top down: the renderer holds a set of dirty
// component ids and `flush()` renders exactly those. It also counts each
// component's renders (`renders`), so a test can assert an exact count.
//
// Nothing here imports std.io, std.fs, std.net, std.time or std.random:
// `test.sh --wasm` builds this package for wasm32-unknown-unknown.
package latte

import std.reflect

/// Where `Component.notify()` sends its "I changed".
///
/// Declared here rather than in `builder.b` because the renderer is what
/// implements it, and a component holding one is holding the renderer that
/// mounted it. It is `weak` on the component's side: the renderer owns the
/// tree, so a strong link back would be the one cycle in the design that has
/// no reason to exist.
///
/// A **class** and not an interface, and that is forced by the language rather
/// than chosen. `MountHandle.sink` holds it `weak`, and a weak field's type
/// "must be `Option<C>` for a non-`unique` class `C`" (spec/SYNTAX.md, "weak
/// fields (zeroing references)"). An interface there is
/// `error: a weak field needs type Option<C> for a non-unique class C`. A
/// subclass is what a test uses to watch marks without standing up a renderer.
pub class DirtySink {
    pub fn init() {}
    pub fn mark(id: int) {}
}

// ---------------------------------------------------------------- the mount
//
// One entry per mounted component. It is not the Builder: a Builder holds the
// component's frames, and this holds where the component *is* — its buffer, the
// buffer that owns its slot, and its parent's id. Those three are what let the
// renderer render one component without walking the tree to find it.
class Mount {
    pub id: int = 0
    pub parent: int = -1
    pub depth: int = 0
    pub buffer: Builder = new Builder()
    /// The buffer whose `children` map holds this component's `reflect.Value`.
    /// `none` for the root, which nothing mounts.
    pub owner: Option<Builder> = none
    pub fn init(id: int) { self.id = id }
}

// ---------------------------------------------------------------- renderer
pub class Renderer extends DirtySink {
    /// The root component's frame buffer. Every other buffer hangs off it
    /// through `Builder.nested`.
    pub root: Builder = new Builder()

    /// The root component. `none` until `mount` is called.
    pub page: Option<Component> = none

    /// How many times each component's `render` has run, by component id. It
    /// is counted here, in the framework, and not by a component incrementing
    /// a field of its own, because a counter a test component keeps only
    /// counts the components the test remembered to instrument.
    pub renders: Map<int, int> = {}

    /// How many `flush` calls have happened. A flush that renders nothing
    /// still counts, because "an event that changed nothing renders nothing"
    /// is a claim about a flush that happened.
    pub flushes: int = 0

    /// Faults the renderer itself raised — a dirty id with no component, a
    /// mount that is not a `Component`. Builder faults stay on the Builder.
    pub faults: List<string> = []

    dirty: Map<int, bool> = {}
    mounts: Map<int, Mount> = {}
    /// handler slot id -> the id of the component that bound it.
    owners: Map<int, int> = {}
    /// component id -> the handler slot ids it bound on its last render, so a
    /// re-render can drop them before it adds the new ones and the index does
    /// not grow for the life of a circuit.
    bound: Map<int, List<int>> = {}

    pub fn init() { super.init() }

    // ---- the dirty set ----------------------------------------------------

    /// `Component.notify()` lands here, and so does every event dispatch.
    ///
    /// Marking an id that is not mounted is not an error: a component can be
    /// disposed between the render that produced a handler and the event that
    /// reaches it, which is exactly what a stale wire id looks like. It is
    /// dropped, and `pending()` is what says whether anything will run.
    pub override fn mark(id: int) {
        if !self.mounts.contains_key(id) { return }
        self.dirty[id] = true
    }

    /// Whether the next `flush` has anything to do.
    pub fn pending() -> int { return self.dirty.len() }

    pub fn is_dirty(id: int) -> bool { return self.dirty.contains_key(id) }

    /// The render count for one component. Zero for a component that has never
    /// rendered, and for one that does not exist — a test asserting "this ran
    /// zero times" wants the same answer either way, and `mounted()` is how it
    /// asks whether the component is there at all.
    pub fn render_count(id: int) -> int {
        match self.renders.get(id) {
            some(n) => { return n }
            none => { return 0 }
        }
    }

    pub fn mounted(id: int) -> bool { return self.mounts.contains_key(id) }

    /// Every mounted component id, parents before children.
    pub fn ids() -> List<int> {
        var out: List<int> = []
        self.collect_ids(0, out)
        return move out
    }

    fn collect_ids(id: int, out: List<int>) {
        match self.mounts.get(id) {
            some(mount) => {
                out.push(id)
                var slots: List<int> = mount.buffer.nested.keys()
                slots.sort()
                for slot: int in slots { self.collect_ids(slot, out) }
            }
            none => {}
        }
    }

    /// The buffer holding one component's frames.
    pub fn buffer(id: int) -> Option<Builder> {
        match self.mounts.get(id) {
            some(mount) => { return some(mount.buffer) }
            none => { return none }
        }
    }

    /// The component itself, recovered from the `reflect.Value` its activation
    /// produced — never re-boxed from a `Component` binding, which would lose
    /// the concrete type (BLOCKERS.md B6).
    pub fn component(id: int) -> Option<Component> {
        match self.mounts.get(id) {
            some(mount) => {
                match mount.owner {
                    some(holder) => {
                        match holder.children.get(id) {
                            some(stored) => { return stored.copy() as? Component }
                            none => { return none }
                        }
                    }
                    none => { return self.page }
                }
            }
            none => { return none }
        }
    }

    // ---- mounting ---------------------------------------------------------

    /// Render the page for the first time. Everything below it mounts with it,
    /// because `component<T>` activates and renders a child in the same call.
    /// Where every component in this page gets its `@inject` fields. `none`
    /// for a page with no container; a component with no `@inject` field never
    /// reaches it either way.
    pub services: Option<ServiceSource> = none

    pub fn mount(component: Component) {
        self.page = some(component)
        self.root.id = 0
        // Where every child component's `@inject` fields will come from. It is
        // handed to the Registry rather than carried by each Builder, the same
        // way the dirty sink is, so a component mounted anywhere in the tree
        // reaches it without anything threading it down.
        self.root.registry.services = self.services
        // The ROOT component is not mounted by a Builder — nothing called
        // `Builder.mount` for it — so the adopt pass that owns signals,
        // attaches view-models and fills `@inject` fields has to happen here
        // too, or a page's own signals would be the only ones nobody owned.
        //
        // `reflect.value` boxes the RUNTIME type, not the binding's static one
        // — that was BLOCKERS.md B6 and beans #163 fixed it, and
        // `probes/p_boxed_type` re-checks it on both backends. Without that
        // this would see `Component` and find none of the page's own fields.
        let boxed: reflect.Value = reflect.value(component)
        for problem: string in self.root.registry.adopt(
                boxed.copy(), boxed.type(), component) {
            self.faults.push(problem)
        }
        // Before `on_init` and before the first render. A component may call
        // `notify()` from either — a subscription taken in `on_init` is the
        // ordinary reason — and every child the first render mounts is handed
        // the sink at its own mount, by the Builder, from the Registry.
        self.root.attach_sink(self, component)
        component.on_init()
        component.on_params_set()
        self.begin()
        self.root.render_root(component)
        self.finish()
    }

    // ---- the render pass --------------------------------------------------

    /// Render exactly the dirty components, and nothing else.
    ///
    /// The three rules, in the order they matter:
    ///
    /// 1. **An ancestor swallows its descendants.** Rendering a parent runs
    ///    `component<T>` for every child it still has, which renders those
    ///    children through `Builder.render_child`. A child that is also in the
    ///    dirty set must therefore be dropped from it, and not for speed: a
    ///    buffer rendered twice before a diff has a `previous` that is the
    ///    middle pass, so the batch would re-send the last batch's inserts,
    ///    removes and moves, and those are not idempotent.
    /// 2. **Parents first.** A dirty parent may drop a dirty child entirely;
    ///    rendering the child first would render a component that is about to
    ///    leave the page.
    /// 3. **A dirty id that is no longer mounted is dropped**, silently. That
    ///    is what a stale wire id looks like after a keyed row went away.
    /// 4. **A marked component renders whatever `should_render` says.**
    ///    `should_render` answers one question — "your parent re-rendered and
    ///    re-supplied your parameters; do you need to render again?" — and a
    ///    component that marked *itself* has already answered a different one.
    ///    Consulting it here is how a framework quietly breaks its own
    ///    `notify`: a component that compares its parameters, which is what
    ///    `should_render` is for, would answer "nothing changed" and never
    ///    re-render for its own state at all. `tests/renders.b` § 2 caught
    ///    exactly that, reporting zero renders for a row whose own counter had
    ///    just gone up.
    ///
    ///    That is also why a marked component under a dirty ancestor gets a
    ///    second look: the ancestor renders it through `Builder.render_child`,
    ///    which *does* consult `should_render`, so a row whose own state
    ///    changed while its parameters did not would be skipped there.
    pub fn flush() -> int {
        self.flushes += 1
        if self.dirty.len() == 0 { return 0 }

        var wanted: List<int> = self.dirty.keys()
        self.dirty.clear()

        var roots: List<int> = []
        for id: int in wanted {
            if self.mounts.contains_key(id) && !self.covered(id, wanted) {
                roots.push(id)
            }
        }
        roots.sort()                       // ids increase with mount order, and
        self.sort_by_depth(roots)          // depth is what rule 2 needs

        self.begin()
        for id: int in roots { self.render_now(id) }

        // The second look. A marked component that a dirty ancestor's pass
        // skipped is rendered on its own — see rule 4.
        for id: int in wanted {
            if self.mounts.contains_key(id) && self.covered(id, roots) {
                match self.buffer(id) {
                    some(buffer) => { if buffer.diffed { self.render_now(id) } }
                    none => {}
                }
            }
        }
        return self.finish()
    }

    /// Render one component now, without consulting `should_render` — rule 4.
    /// `on_params_set` still runs, because a component's own record of what its
    /// parameters were should not depend on who asked for the render.
    fn render_now(id: int) {
        match self.component(id) {
            some(component) => {
                match self.buffer(id) {
                    some(buffer) => {
                        component.on_params_set()
                        buffer.render_root(component)
                    }
                    none => { self.faults.push("dirty component {id} has no buffer") }
                }
            }
            none => { self.faults.push("dirty component {id} has no instance") }
        }
    }

    /// Whether some other member of the dirty set is an ancestor of `id`.
    fn covered(id: int, others: List<int>) -> bool {
        var walk: int = id
        for true {
            match self.mounts.get(walk) {
                some(mount) => {
                    if mount.parent < 0 { return false }
                    walk = mount.parent
                }
                none => { return false }
            }
            for other: int in others {
                if other == walk && self.mounts.contains_key(other) { return true }
            }
        }
        return false
    }

    fn sort_by_depth(ids: List<int>) {
        // Insertion sort on depth. A dirty set is small — it is the components
        // one event touched — and a stable sort keeps the id order inside a
        // depth, which is what makes the render order reproducible.
        var i: int = 1
        for i < ids.len() {
            let value: int = ids[i]
            let key: int = self.depth_of(value)
            var j: int = i - 1
            for j >= 0 && self.depth_of(ids[j]) > key {
                ids[j + 1] = ids[j]
                j -= 1
            }
            ids[j + 1] = value
            i += 1
        }
    }

    fn depth_of(id: int) -> int {
        match self.mounts.get(id) {
            some(mount) => { return mount.depth }
            none => { return 0 }
        }
    }

    // ---- the bookkeeping either side of a pass ----------------------------
    //
    // `Builder.diffed` is what says a buffer rendered: `reset()` clears it and
    // the differ sets it, so a buffer that is `false` at the end of a pass and
    // was `true` at the start ran exactly once. That is why the render counter
    // needs no hook inside `Builder` and cannot be forgotten by a component.

    fn begin() {
        var ids: List<int> = self.ids()
        for id: int in ids {
            match self.mounts.get(id) {
                some(mount) => { mount.buffer.diffed = true }
                none => {}
            }
        }
        self.root.diffed = true
    }

    fn finish() -> int {
        var ran: int = 0
        self.reindex()
        var ids: List<int> = self.ids()
        for id: int in ids {
            match self.mounts.get(id) {
                some(mount) => {
                    if !mount.buffer.diffed {
                        ran += 1
                        self.renders[id] = self.render_count(id) + 1
                        self.reown(id, mount.buffer)
                    }
                }
                none => {}
            }
        }
        return ran
    }

    /// Rebuild the mount index from the Builder tree. It is O(components), not
    /// O(frames): a mounted child is an entry in `Builder.nested`, and the walk
    /// stops there.
    fn reindex() {
        var live: Map<int, bool> = {}
        self.visit(self.root, -1, 0, none, live)
        var known: List<int> = self.mounts.keys()
        for id: int in known {
            if !live.contains_key(id) {
                let _: bool = self.mounts.remove(id)
                let _: bool = self.dirty.remove(id)
                self.forget_bindings(id)
            }
        }
    }

    fn visit(buffer: Builder, parent: int, depth: int,
             owner: Option<Builder>, live: Map<int, bool>) {
        let id: int = buffer.id
        live[id] = true
        var mount: Mount = new Mount(id)
        match self.mounts.get(id) {
            some(existing) => { mount = existing }
            none => { self.mounts[id] = mount }
        }
        mount.parent = parent
        mount.depth = depth
        mount.buffer = buffer
        mount.owner = owner
        var slots: List<int> = buffer.nested.keys()
        slots.sort()
        for slot: int in slots {
            match buffer.nested.get(slot) {
                some(child) => {
                    self.visit(child, id, depth + 1, some(buffer), live)
                }
                none => {}
            }
        }
    }

    /// Re-read one component's handler frames into the dispatch index.
    ///
    /// Only the component that rendered is re-read, so an event is one map
    /// lookup and a render is one walk of the frames it just produced — never
    /// a walk of the page. The old ids are dropped first, so a circuit that
    /// runs for a day does not accumulate an entry per handler per render.
    fn reown(id: int, buffer: Builder) {
        self.forget_bindings(id)
        var ids: List<int> = []
        for frame: Frame in buffer.frames.items {
            match frame {
                handler(_, _, slot) => {
                    self.owners[slot] = id
                    ids.push(slot)
                }
                _ => {}
            }
        }
        self.bound[id] = move ids
    }

    fn forget_bindings(id: int) {
        match self.bound.get(id) {
            some(previous) => {
                for slot: int in previous { let _: bool = self.owners.remove(slot) }
            }
            none => {}
        }
        let _: bool = self.bound.remove(id)
    }

    /// Which component bound a handler slot. `-1` when nothing did, which is
    /// what a stale id off the wire looks like.
    pub fn owner_of(handler: int) -> int {
        match self.owners.get(handler) {
            some(id) => { return id }
            none => { return -1 }
        }
    }

    // ---- dispatch ---------------------------------------------------------
    //
    // A handler runs and the component that bound it is marked dirty
    // automatically. That is why a page needs no `notify()` on the ordinary
    // path: the framework knows which component owns the id it just
    // dispatched, so an author who forgets to say "I changed" still gets the
    // render they meant.
    //
    // The registry answers first. `false` means the id is unknown — a stale id
    // from a reconnecting client, or a row that left the page — and nothing is
    // marked, because marking on an unknown id would let a client dirty a
    // component by guessing a number.

    pub fn fire_mouse(handler: int, event: MouseEvent) -> bool {
        if !self.root.registry.fire_mouse(handler, event) { return false }
        self.mark(self.owner_of(handler))
        return true
    }

    pub fn fire_input(handler: int, event: InputEvent) -> bool {
        if !self.root.registry.fire_input(handler, event) { return false }
        self.mark(self.owner_of(handler))
        return true
    }

    pub fn fire_keyboard(handler: int, event: KeyboardEvent) -> bool {
        if !self.root.registry.fire_keyboard(handler, event) { return false }
        self.mark(self.owner_of(handler))
        return true
    }

    pub fn fire_submit(handler: int, event: SubmitEvent) -> bool {
        if !self.root.registry.fire_submit(handler, event) { return false }
        self.mark(self.owner_of(handler))
        return true
    }

    pub fn fire_focus(handler: int, event: FocusEvent) -> bool {
        if !self.root.registry.fire_focus(handler, event) { return false }
        self.mark(self.owner_of(handler))
        return true
    }

    // ---- what comes out ---------------------------------------------------

    /// The whole page as HTML — what static server rendering sends.
    pub fn html() -> string {
        let writer: Serializer = new Serializer()
        return writer.page(self.root)
    }

    /// The edits since the last batch: what the components that re-rendered
    /// diffed to, plus what the live tier queued without rendering at all.
    ///
    /// The two are merged rather than concatenated, because a component can
    /// have both and the answer is not "send both".
    ///
    /// * Edits queued BEFORE the render that is now waiting to be diffed lead
    ///   the update. The render turned those frames into `previous`, mutation
    ///   and all, so the differ cannot see them and dropping them loses the
    ///   write — `Builder.carry` carries the whole argument.
    /// * A buffer that did NOT re-render (`diffed` is still true) has no diff
    ///   edits, and its queued signal edits are the only thing carrying the
    ///   rewrite. They are sent.
    /// * A buffer that DID re-render drops what was queued AFTER that render:
    ///   the mutation is inside `frames`, `previous` predates it, so the diff
    ///   carries it already — and the queued edit's child index was measured
    ///   against a frame list the client has not reached yet.
    ///
    /// The walk is the same pre-order over `Builder.nested` the differ uses, so
    /// `updates` stays parent-before-child: a child's edits are addressed to a
    /// mount node its parent's edits create.
    pub fn batch() -> Batch {
        // BEFORE the differ, because the differ SETS `diffed` on every buffer
        // it visits — so asking afterwards answers true for all of them and
        // the distinction this merge turns on would be gone.
        var settled: Map<int, bool> = {}
        self.note_settled(self.root, settled)
        let differ: Differ = new Differ()
        let out: Batch = differ.batch(self.root)
        var by_id: Map<int, ComponentUpdate> = {}
        for update: ComponentUpdate in out.updates { by_id[update.component] = update }
        var merged: List<ComponentUpdate> = []
        self.merge_live(self.root, settled, by_id, merged)
        out.updates = move merged
        return out
    }

    fn note_settled(buffer: Builder, settled: Map<int, bool>) {
        settled[buffer.id] = buffer.diffed
        var slots: List<int> = buffer.nested.keys()
        slots.sort()
        for slot: int in slots {
            match buffer.nested.get(slot) {
                some(child) => { self.note_settled(child, settled) }
                none => {}
            }
        }
    }

    fn merge_live(buffer: Builder, settled: Map<int, bool>,
                  by_id: Map<int, ComponentUpdate>,
                  out: List<ComponentUpdate>) {
        let update: ComponentUpdate = new ComponentUpdate(buffer.id)
        var was_settled: bool = true
        match settled.get(buffer.id) {
            some(value) => { was_settled = value }
            none => {}
        }
        buffer.take_carry(update.edits)
        if was_settled { buffer.take_pending(update.edits) }
        else { buffer.drop_pending() }
        match by_id.get(buffer.id) {
            some(diffed) => {
                for edit: Edit in diffed.edits { update.edits.push(edit) }
            }
            none => {}
        }
        if update.edits.len() > 0 { out.push(update) }
        var slots: List<int> = buffer.nested.keys()
        slots.sort()
        for slot: int in slots {
            match buffer.nested.get(slot) {
                some(child) => { self.merge_live(child, settled, by_id, out) }
                none => {}
            }
        }
    }

    /// Every fault anywhere: the renderer's own, and every Builder's.
    pub fn all_faults() -> List<string> {
        var out: List<string> = []
        for fault: string in self.faults { out.push("renderer: {fault}") }
        for fault: string in self.root.all_faults() { out.push(fault) }
        return move out
    }
}
