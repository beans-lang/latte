// A component tree, alive on a surface.
package compose

import latte.platform
import latte.controls
import latte.input
import latte.layout
import latte.geometry
import std.reflect

/// Owns a root component, the controls it produced, and everything needed to
/// keep the two in step.
///
/// This is the class an application actually holds. Give it a container to
/// fill and a component to show; call `refresh()` whenever something changed.
/// Each refresh renders, diffs against the last render, applies only the
/// difference, and lays the result out.
///
/// ```beans
/// var mount: component.Mount = new component.Mount(root, app.router)
/// mount.use_services(container)          // optional
/// mount.show(new OrderScreen())?
/// mount.set_bounds(window.content_size()?)
/// mount.refresh()?
/// ```
///
/// ### Why the mount holds the components and not the other way round
///
/// A component never points back here. `request_render` sets a flag on the
/// component and the mount asks; a back-reference would make a cycle, and an
/// object that dies inside a reference cycle never runs its `deinit` — which
/// for a tree holding native controls is exactly the leak nobody notices. The
/// mount visits every component it owns on every refresh anyway, so asking
/// costs nothing that being told would have saved.
pub class Mount implements Composer {
    root: controls.Widget
    router: input.EventRouter
    sheet: controls.WidgetLayout
    solver: layout.Solver

    top: Option<Component> = none
    shown: Option<Element> = none
    services: Option<ServiceSource> = none
    builder_of_types: Option<Activator> = none

    /// The plan per component type, worked out on that type's first mount and
    /// kept for the life of the application.
    plans: Map<string, MountPlan> = {}

    /// Child components this mount has already prepared, by the key their
    /// parent gave them.
    prepared: Map<string, Component> = {}
    /// What each child rendered last time, so a child that says it has nothing
    /// new can be spliced back in without running its render at all.
    cached: Map<string, Element> = {}
    /// Which keys this render has used, so a duplicate is reported rather than
    /// silently making two components share one identity.
    used: Map<string, bool> = {}
    /// The scoped key of the component whose `render` is running, "" at the
    /// top. Every key asked for while it runs is qualified by it.
    rendering: string = ""

    /// Which element each live control stands for. Rebuilt after every apply.
    by_handle: Map<u64, Element> = {}

    /// The control the element tree's root became — the single child of the
    /// box this mount was given to fill.
    face: Option<controls.Widget> = none

    bounds: geometry.Size = geometry.Size.zero()
    renders: int = 0

    /// The surface this mount fills, once it has one, so the layout can follow
    /// it. `Handle.none()` for a mount on a container that is in no surface —
    /// a headless test measuring a tree, which has nothing to follow.
    surface: platform.Handle = platform.Handle.none()

    /// The two settings the solver takes, kept here rather than only on the
    /// solver. A solve rebuilds the solver, and a setting that lived only on
    /// the solver was therefore back at its default on the very next refresh:
    /// `scale` and `reading` did nothing at all after the first one.
    scaling: f64 = 1.0
    reading_order: layout.TextDirection = layout.TextDirection.ltr

    pub fn init(root: controls.Widget, router: input.EventRouter) {
        self.root = root
        self.router = router
        self.sheet = new controls.WidgetLayout()
        self.solver = new layout.Solver(self.sheet)
    }

    /// Where `@inject` fields come from. Without one, a component that has any
    /// is refused at mount rather than mounted with them empty.
    pub fn use_services(source: ServiceSource) {
        self.services = some(source)
    }

    /// Who builds a component type named only in markup.
    ///
    /// Optional. Without one, such a type is built through its own
    /// zero-argument initializer, which is every component that takes nothing
    /// through its constructor. With one — `cortado_app.Container` — the
    /// initializer's parameters are resolved from the container, so a
    /// component with constructor dependencies works from markup too.
    pub fn use_activator(who: Activator) {
        self.builder_of_types = some(who)
    }

    /// The room the tree is laid out in.
    ///
    /// Set once before `show`. After that the mount follows its own surface —
    /// see `follow` — so a program does not have to notice a resize to stay
    /// laid out correctly.
    pub fn set_bounds(size: geometry.Size) {
        self.bounds = size
    }

    /// The room changed. Lays the tree out again at the new size.
    ///
    /// `follow` calls this for a window the user dragged. It is public because
    /// a surface latte does not own — a view embedded in a host application,
    /// a phone rotating under a platform latte has no window notification
    /// for — has to be able to say so.
    pub fn resized(size: geometry.Size) -> Result<bool> {
        if size.width == self.bounds.width && size.height == self.bounds.height {
            return ok(false)
        }
        self.bounds = size
        self.lay_out()?
        self.note_boxes()
        // A render that decides by the room is stale now. It is asked for,
        // not done here: the next `refresh_if_needed` renders it, once.
        match self.top {
            none => {}
            some(component) => { self.wake_for_room(component) }
        }
        for key: string in self.prepared.keys() {
            match self.prepared.get(key) {
                some(child) => { self.wake_for_room(child) }
                none => {}
            }
        }
        return ok(true)
    }

    /// Re-measure retained controls after shared font metrics or control state
    /// changes. This preserves component identity and the existing solver.
    pub fn remeasure() -> Result<bool> {
        self.lay_out()?
        self.note_boxes()
        return ok(true)
    }

    /// Tells `component` the new room, and asks it to render if it follows it.
    fn wake_for_room(component: Component) {
        component.note_viewport(self.bounds)
        if component.follows_viewport() {
            component.request_render()
        }
    }

    pub fn reading(direction: layout.TextDirection) {
        self.reading_order = direction
    }

    pub fn scale(value: f64) {
        self.scaling = value
    }

    /// The backing scale frames snap to: the surface's, once one is followed.
    pub fn scale_in_use() -> f64 {
        return self.scaling
    }

    /// How many renders have happened. A test's cheapest proof that a
    /// `should_render` really pruned something.
    pub fn render_count() -> int {
        return self.renders
    }

    /// How many controls the last layout pass wrote a frame to, how many it
    /// left where they already were, and how many containers it had to ask the
    /// platform about.
    ///
    /// The three numbers a test needs to see that a pass which changed nothing
    /// cost nothing. A layout that wrote every frame and asked every container
    /// on every pass looked identical from the outside — the frames were
    /// right — which is why it went unnoticed for as long as it did.
    pub fn frames_written() -> int {
        return self.sheet.written()
    }

    pub fn frames_kept() -> int {
        return self.sheet.unchanged()
    }

    pub fn chrome_asked() -> int {
        return self.sheet.chrome_asked()
    }

    /// How many runs on the screen have children past their box, as of the
    /// last layout pass. A screen that fits answers zero at every size.
    pub fn overflows() -> int {
        return self.sheet.overflowing()
    }

    /// Puts a component on this surface and renders it for the first time.
    pub fn show(component: Component) -> Result<bool> {
        self.top = some(component)
        self.prepare(component)?
        self.follow()
        return self.refresh()
    }

    /// Keeps the layout in step with the surface the tree is in.
    ///
    /// **A window that resizes and a tree that does not follow it is the
    /// default a framework must not have.** Before this, `set_bounds` was
    /// called once at startup and never again, so every latte program —
    /// `examples/gallery` included — opened at one size and stayed laid out
    /// for that size for ever: the window grew, the controls did not move, and
    /// nothing anywhere said so. Making it the application's job to notice was
    /// the bug, not the application's mistake; not one program in this
    /// repository remembered to do it.
    ///
    /// Two things are followed, and they are the two that change the room or
    /// the grid it is measured on:
    ///
    ///   * `surface_resized` — the user dragged a corner. The event carries
    ///     the new **content** size, which is what `set_bounds` wants, so
    ///     nothing has to ask the platform again.
    ///   * `scale_changed` — the window moved to a display with a different
    ///     backing scale. Frames snap to that grid, so the tree has to be
    ///     solved again or every edge lands half a pixel out.
    ///
    /// Through `EventRouter.watch` rather than `on`: an application is free to
    /// handle either event as well, and neither subscription can switch the
    /// other off. A mount on a container that is in no surface follows
    /// nothing, which is the headless case and not an error.
    fn follow() {
        return
    }

    /// The display's grid changed. Lays the tree out again on the new one.
    pub fn rescaled(value: f64) -> Result<bool> {
        if value == self.scaling {
            return ok(false)
        }
        self.scaling = value
        self.lay_out()?
        return ok(true)
    }

    /// The surface this mount follows, or `Handle.none()` if it is in none.
    pub fn following() -> platform.Handle {
        return self.surface
    }

    /// Renders, applies the difference, and lays the result out.
    ///
    /// Safe to call when nothing changed: the differ answers an empty list and
    /// no platform call happens at all.
    pub fn refresh() -> Result<bool> {
        self.render_round()?
        var round: int = 0
        for round: int in 0..Mount.settle_rounds() {
            let again: string = self.note_boxes()
            if again == "" { return ok(true) }
            if round + 1 == Mount.settle_rounds() {
                return err("{again} is sized from the box it is laid out in, and that box is still moving after {Mount.settle_rounds()} passes — a component whose own content decides its box cannot also be sized from it",
                           "unsettled_layout")
            }
            self.render_round()?
        }
        return ok(true)
    }

    /// How many times one refresh will lay out and render again for the
    /// components sized from their own box.
    ///
    /// A chain of them settles one link a pass, so the bound is on how deep
    /// that chain may be rather than on anything about time. Past it the
    /// layout is circular, and saying so beats laying out for ever.
    static fn settle_rounds() -> int {
        return 4
    }

    /// Tells every component the box it was laid out in, and answers the path
    /// of one that asked to render again because that box moved.
    fn note_boxes() -> string {
        var again: string = ""
        match self.top {
            none => {}
            some(component) => {
                match self.shown {
                    none => {}
                    some(element) => {
                        if self.note_box_of(component, element) { again = "the screen" }
                    }
                }
            }
        }
        for key: string in self.prepared.keys() {
            match self.prepared.get(key) {
                none => {}
                some(child) => {
                    match self.cached.get(key) {
                        none => {}
                        some(element) => {
                            if self.note_box_of(child, element) { again = key }
                        }
                    }
                }
            }
        }
        return again
    }

    /// One component's own box, and whether it asked to render over it.
    fn note_box_of(component: Component, element: Element) -> bool {
        let slot: u64 = element.control.raw
        if slot == 0 { return false }
        match self.sheet.frame_of(slot) {
            none => { return false }
            some(frame) => {
                let before: geometry.Rect = component.box()
                let moved: bool = before.x != frame.x || before.y != frame.y ||
                                  before.width != frame.width || before.height != frame.height
                component.note_box(frame)
                if !moved { return false }
                component.on_layout(frame)
                if component.follows_box() {
                    component.request_render()
                    return true
                }
                return false
            }
        }
    }

    /// One render, applied and laid out. The half of `refresh` that runs again
    /// when a component's own box moved under it.
    fn render_round() -> Result<bool> {
        match self.top {
            none => { return err("this mount has nothing to show", "not_mounted") }
            some(component) => {
                self.used = {}
                let next: Element = self.render_one(component, "")?
                // Nothing contains a screen's root, so a coordinate or a share
                // of leftover space written on it can never be answered.
                if next.pending != "" {
                    return err(Builder.wrong_parent(next.tag, next.pending_name, next.pending),
                               "bad_render")
                }
                // Nor can anything judge the room a root would hide in.
                if next.spec.hidden || next.spec.hide_below >= 0.0 || next.spec.hide_above >= 0.0 {
                    return err("<{next.tag}> is the screen's root, and nothing contains it to hide it — hide what is inside it instead",
                               "bad_render")
                }
                var differ: Differ = new Differ()
                let changes: List<Change> = differ.diff(self.shown, next)
                var applier: Applier = new Applier(self.root, self.router, self)
                applier.apply(changes)?
                applier.index(next)?
                self.face = some(applier.face()?)
                self.shown = some(next)
                self.settle_all()
                self.lay_out()?
                return ok(true)
            }
        }
    }

    /// Takes everything down: unsubscribes, unmounts, and empties the
    /// container.
    ///
    /// A step the platform refuses does not stop the rest. A teardown that
    /// returned at the first refusal left the mount still holding its component
    /// tree, its layout sheet and every control after the one that failed —
    /// so the refusal is remembered, everything else is torn down, and the
    /// first refusal is what this answers.
    pub fn close() -> Result<bool> {
        var refused: string = ""
        var refused_kind: string = ""
        // The surface first. A mount that let go of its component tree and
        // left its surface watched keeps the host delivering a resize on every
        // frame of a drag to a closure that will never lay anything out again
        // — and keeps the closure, and through it this mount, alive.
        if self.surface.raw != 0 {
            self.router.unwatch(self.surface, input.EventKind.surface_resized)
            self.router.unwatch(self.surface, input.EventKind.scale_changed)
            self.surface = platform.Handle.none()
        }
        match self.top {
            none => {}
            some(component) => {
                component.on_unmount()
                component.note_mounted(false)
            }
        }
        for key: string in self.prepared.keys() {
            match self.prepared.get(key) {
                some(child) => {
                    child.on_unmount()
                    child.note_mounted(false)
                }
                none => {}
            }
        }
        match self.root as? controls.ChildHolder {
            none => {}
            some(box) => {
                var back: int = box.count() - 1
                for back >= 0 {
                    match box.child_at(back) {
                        // The whole subtree, not just the child: a
                        // registration is per control, and forgetting only the
                        // top of a tree leaves one dead closure per descendant
                        // holding this mount alive for the life of the process.
                        some(child) => { self.forget_all(child) }
                        none => {}
                    }
                    let leaving: Option<controls.Widget> = box.child_at(back)
                    var detached: bool = false
                    match box.remove(back) {
                        ok(done) => { detached = true }
                        err(problem) => {
                            if refused == "" {
                                refused = problem.msg
                                refused_kind = problem.kind
                            }
                        }
                    }
                    // And the controls themselves. Until this was here, `close`
                    // let go of the component tree and the router table and
                    // left every native control alive — because the layout
                    // sheet below holds a Widget per node, so the last Beans
                    // reference did not go until the whole Mount did. A screen
                    // closed and reopened twenty times held twenty screens'
                    // worth of AppKit objects, and `tests/leaks.b` is the gate
                    // that says so.
                    //
                    // Only what really came out. Releasing a control still
                    // parented leaves the parent holding a handle already gone.
                    if detached {
                        match leaving {
                            some(gone) => { self.let_go(gone) }
                            none => {}
                        }
                    }
                    back = back - 1
                }
            }
        }
        self.prepared = {}
        self.cached = {}
        self.by_handle = {}
        self.shown = none
        self.top = none
        self.face = none
        // The layout sheet keeps a control per node, so a mount that let go of
        // its component tree and kept its sheet would keep every control in
        // it. This is the reference that made the leak invisible: everything
        // named in `close` was already being cleared.
        self.sheet = new controls.WidgetLayout()
        self.solver = new layout.Solver(self.sheet)
        if refused != "" { return err(refused, refused_kind) }
        return ok(true)
    }

    /// Releases a subtree's controls, depth first.
    fn let_go(control: controls.Widget) {
        for child: controls.Widget in control.children() {
            self.let_go(child)
        }
        control.release()
    }

    fn forget_all(control: controls.Widget) {
        self.router.forget(control.handle())
        self.by_handle.remove(control.handle().raw)
        for child: controls.Widget in control.children() {
            self.forget_all(child)
        }
    }

    // ---- rendering ----

    fn render_one(component: Component, path: string) -> Result<Element> {
        var into: Builder = new Builder()
        into.set_composer(self)
        // Whose render this is, so the keys it asks for are scoped to it. Saved
        // and restored rather than cleared: a child renders inside its
        // parent's render, and the parent has more children to compose after
        // this one comes back.
        let outer: string = self.rendering
        self.rendering = path
        component.note_viewport(self.bounds)
        component.note_rendering(true)
        component.render(into)
        component.note_rendering(false)
        self.rendering = outer
        self.renders = self.renders + 1
        return into.finish()
    }

    /// A child's key, qualified by the component that asked for it.
    ///
    /// **The keys a markup file generates are per render, and this map is per
    /// mount.** `latte-bx` numbers component tags from zero in every
    /// `render` it writes, so the first component tag in *any* `.bx` file is
    /// `c0`. Without this, a screen whose component contains a component — a
    /// `<Card>` with a `<Badge>` in it — had both asking for `c0`, and
    /// `obtain` handed the inner one the outer one's instance. It did not even
    /// reach the duplicate-key refusal below: the downcast failed first, and
    /// the author was told `<Badge> came back as something else`.
    ///
    /// Nothing in this repository nested two component tags, which is the only
    /// reason it went unseen — `checkout.bx` has two component tags as
    /// siblings, where the numbering already differs.
    ///
    /// The rule is the one `stage_for` already states for a `Stage`: two
    /// components may both use the key "plot" and neither finds the other's.
    /// This is the composer finally saying the same thing.
    fn scoped_key(key: string) -> string {
        if self.rendering == "" {
            return key
        }
        return "{self.rendering}/{key}"
    }

    /// `Composer`: renders a child on its parent's behalf.
    ///
    /// Three things happen here that the parent should not have to think
    /// about. A child seen for the first time is prepared — injected, its
    /// parameters announced, `on_init` run — before anything asks it to
    /// render. A child that says `should_render` is false is not rendered at
    /// all, and the subtree it produced last time is handed back untouched.
    /// And a key used twice in one render is refused, because two components
    /// sharing an identity would take each other's state.
    pub fn compose(key: string, child: Component) -> Result<Element> {
        let scoped: string = self.scoped_key(key)
        match self.used.get(scoped) {
            some(already) => {
                // The key is not quoted here, and that is deliberate: since
                // `Builder.fragment` landed, the key this is handed may carry a
                // placement prefix the author never wrote. Every caller already
                // knows the key it passed — `Builder.show` puts it in front of
                // this sentence — so naming it here could only ever name it
                // twice, once in a spelling nobody typed.
                return err("this key is already taken by another child of the same render",
                           "duplicate_key")
            }
            none => {}
        }
        self.used[scoped] = true

        var first: bool = false
        match self.prepared.get(scoped) {
            none => {
                self.prepare(child)?
                self.prepared[scoped] = child
                first = true
            }
            some(held) => {}
        }

        if !first && !child.is_dirty() && !child.should_render() {
            match self.cached.get(scoped) {
                some(before) => { return ok(before) }
                none => {}
            }
        }

        let subtree: Element = self.render_one(child, scoped)?
        self.cached[scoped] = subtree
        return ok(subtree)
    }

    /// `Composer`: the child under `key`, built the first time it is asked
    /// for.
    pub fn obtain(key: string, described: reflect.Type) -> Result<reflect.Value> {
        let scoped: string = self.scoped_key(key)
        match self.prepared.get(scoped) {
            some(held) => { return ok(reflect.value(held)) }
            none => {}
        }
        let boxed: reflect.Value = self.construct(described)?
        match boxed as? Component {
            none => {
                return err("{described.qualified_name()} is not a Component, so it cannot be shown",
                           "not_a_component")
            }
            some(built) => {
                self.prepare(built)?
                self.prepared[scoped] = built
                return ok(reflect.value(built))
            }
        }
    }

    fn construct(described: reflect.Type) -> Result<reflect.Value> {
        match self.builder_of_types {
            some(who) => {
                match who.build(described) {
                    ok(value) => { return ok(value) }
                    err(problem) => {
                        return err("{described.qualified_name()}: {problem}", "cannot_build")
                    }
                }
            }
            none => {}
        }
        match described.initializer() {
            none => {
                return err("{described.qualified_name()} has no initializer reflection can call — an abstract class, a singleton and a closed generic have none. Give the mount a container, or hold the component in a field and show it with `show`",
                           "no_initializer")
            }
            some(make) => {
                if make.parameters().len() > 0 {
                    return err("{described.qualified_name()} takes constructor arguments, and this mount has no container to resolve them from — call `use_activator`, or hold the component in a field and show it with `show`",
                               "needs_container")
                }
                var empty: List<reflect.Value> = []
                match make.call(move empty) {
                    ok(value) => { return ok(value) }
                    err(problem) => {
                        return err("{described.qualified_name()}: {problem.message()}", "cannot_build")
                    }
                }
            }
        }
    }

    // ---- preparation ----

    /// Fills a component's injected fields and runs the start of its life.
    fn prepare(component: Component) -> Result<bool> {
        // `reflect.value` boxes the *runtime* type, so a subclass mounted
        // through a `Component` reference is reflected as itself and not as
        // the base — which is the whole point, since the annotations are on
        // the subclass.
        let receiver: reflect.Value = reflect.value(component)
        let described: reflect.Type = receiver.type()
        let plan: MountPlan = self.plan_for(described)
        var problems: List<string> = []
        for fault: string in plan.faults {
            problems.push(fault)
        }
        if plan.bindings.len() > 0 {
            match self.services {
                none => {
                    for binding: InjectBinding in plan.bindings {
                        problems.push(
                            "{described.qualified_name()}.{binding.field.name()} is @inject, but this mount has no service container to fill it from")
                    }
                }
                some(source) => {
                    for binding: InjectBinding in plan.bindings {
                        if binding.fault != "" {
                            problems.push(binding.fault)
                            continue
                        }
                        match source.provide(binding.wanted) {
                            err(problem) => {
                                problems.push("{described.qualified_name()}.{binding.field.name()}: {problem}")
                            }
                            ok(value) => {
                                match binding.field.set(receiver.copy(), value) {
                                    ok(done) => {}
                                    err(problem) => {
                                        problems.push("{described.qualified_name()}.{binding.field.name()}: {problem.message()}")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if problems.len() > 0 {
            var joined: string = ""
            for problem: string in problems {
                if joined != "" { joined = "{joined}; " }
                joined = "{joined}{problem}"
            }
            return err(joined, "injection_failed")
        }
        component.on_params_set()
        component.on_init()
        return ok(true)
    }

    fn plan_for(described: reflect.Type) -> MountPlan {
        let key: string = described.qualified_name()
        match self.plans.get(key) {
            some(found) => { return found }
            none => {}
        }
        let made: MountPlan = MountPlan.of(described)
        self.plans[key] = made
        return made
    }

    fn settle_all() {
        match self.top {
            none => {}
            some(component) => { self.settle_one(component, self.shown) }
        }
        for key: string in self.prepared.keys() {
            match self.prepared.get(key) {
                some(child) => { self.settle_one(child, self.cached.get(key)) }
                none => {}
            }
        }
    }

    fn settle_one(component: Component, rendered: Option<Element>) {
        component.settle()
        if !component.is_mounted() {
            component.note_mounted(true)
            component.on_mount(self.stage_for(rendered))
        }
    }

    /// The controls one component rendered, by the key it gave them.
    ///
    /// Walks that component's own element subtree rather than the whole
    /// mount's, so two components may both use the key "plot" and neither
    /// finds the other's.
    fn stage_for(rendered: Option<Element>) -> Stage {
        var found: Map<string, platform.Handle> = {}
        match rendered {
            some(root) => { Mount.collect_keys(root, found) }
            none => {}
        }
        // The controls themselves, for the calls a handle cannot make — a
        // table's source, a tab's labels. One walk of the real tree, keyed by
        // handle, rather than one walk per key: a screen with six keyed
        // controls would otherwise walk it six times.
        var by_handle: Map<u64, controls.Widget> = {}
        Mount.collect_controls(self.root, by_handle)
        var objects: Map<string, controls.Widget> = {}
        for key: string in found.keys() {
            match found.get(key) {
                some(handle) => {
                    match by_handle.get(handle.raw) {
                        some(control) => { objects[key] = control }
                        none => {}
                    }
                }
                none => {}
            }
        }
        return new Stage(move found, move objects, self.router, platform.Handle.none())
    }

    /// Every control under `box`, by the handle it holds.
    ///
    /// Through `children()` rather than by downcasting to `Container`: a
    /// disclosure, a group box, a scroll view and a tab view all hold children
    /// and none of them is a `Container`. Every widget answers `children()`,
    /// and a leaf answers with none.
    static fn collect_controls(box: controls.Widget, into: Map<u64, controls.Widget>) {
        for child: controls.Widget in box.children() {
            into[child.handle().raw] = child
            Mount.collect_controls(child, into)
        }
    }

    /// Every keyed element in a subtree, with the control it became.
    ///
    /// A child component's own subtree is skipped: it was rendered by that
    /// component and belongs to its stage, not to this one.
    static fn collect_keys(element: Element, into: Map<string, platform.Handle>) {
        if element.key != "" && element.control.raw != 0 {
            into[element.key] = element.control
        }
        for child: Element in element.children() {
            Mount.collect_keys(child, into)
        }
    }

    // ---- layout ----

    /// Builds a layout tree that mirrors the element tree and solves it.
    ///
    /// Rebuilt each refresh rather than patched. The tree is small, the nodes
    /// hold no platform handles, and a layout tree patched in step with a
    /// widget tree is a second reconciler to keep correct — one whose bugs
    /// would show up as controls in the wrong place with every frame otherwise
    /// looking right.
    fn lay_out() -> Result<bool> {
        match self.shown {
            none => { return ok(true) }
            some(element) => {
                match self.face {
                    none => { return ok(true) }
                    some(control) => {
                        let moved: int = self.solve_once(element, control)?
                        // **A split view needs a second pass, and only the
                        // second one is true.**
                        //
                        // Where a divider sits is the control's own state, and
                        // a split view that has never been laid out has no
                        // frame to divide — so the first pass reads a divider
                        // of nothing and gives one pane the lot. The first
                        // pass is what gives it its frame; the second is the
                        // one whose pane widths are real.
                        //
                        // Conditional twice over. On the screen having a split
                        // view at all: one without solves once, as it always
                        // did. And on the first pass having *moved* something:
                        // a divider is read back from a frame, so a pass that
                        // wrote no frame cannot have changed one, and a second
                        // solve would produce the answer that is already on the
                        // screen. That is the common case — a screen re-laid
                        // out after a click moves a control or two and leaves
                        // the rest where they were — and it used to cost a
                        // whole second pass over the tree, every time, for
                        // every screen with a splitter on it.
                        //
                        // Hand-written latte programs have always had to do
                        // this — `examples/cask` said so in a comment before
                        // it was markup — and a screen described rather than
                        // built should not have to know.
                        if moved > 0 && Mount.holds_split(element) {
                            self.solve_once(element, control)?
                        }
                    }
                }
                return ok(true)
            }
        }
    }

    /// One pass, answering how many controls it actually moved.
    ///
    /// The sheet is emptied rather than replaced. It used to be replaced —
    /// `new WidgetLayout()` on every pass — and what went with it each time
    /// was the only record of what the platform had already been told, so
    /// every pass asked every container for its chrome again and wrote every
    /// control's frame again whether or not it had moved. On a screen of
    /// eighty controls that was seventy crossings and eighty writes per pass,
    /// for two frames that had actually changed.
    fn solve_once(element: Element, control: controls.Widget) -> Result<int> {
        self.sheet.reset()
        // From the mount's own fields. A scale or a reading order written onto
        // the solver alone did not survive the solver being replaced every
        // pass, which is why `scale` and `reading` had no effect beyond the
        // first refresh.
        self.solver.set_scale(self.scaling)
        self.solver.set_direction(self.reading_order)
        var page: layout.LayoutNode = self.node_for(element, control)?
        self.solver.solve(page, geometry.Rect.at(geometry.Point.zero(), self.bounds))?
        return self.sheet.apply(page)
    }

    /// Whether anything in this tree divides its own panes.
    static fn holds_split(element: Element) -> bool {
        if element.kind == controls.WidgetKind.split_view { return true }
        for child: Element in element.children() {
            if Mount.holds_split(child) { return true }
        }
        return false
    }

    fn node_for(element: Element, control: controls.Widget) -> Result<layout.LayoutNode> {
        // **A split view arranges its own panes, and only it can.**
        //
        // Where the divider sits is the control's own state — a person drags
        // it — so the arranger has to be asked for rather than described: no
        // attribute in the markup could say it, and a stack arranger would
        // give both panes the whole width. A `<SplitView>` written in markup
        // laid its panes on top of each other until this line existed, and
        // `examples/gallery` did not catch it because the two panes it shows
        // are empty containers.
        //
        // Chosen before the node is made rather than replacing one already
        // registered, which used to enter the same control in the sheet twice.
        var arranger: Option<layout.Layout> = element.arranger
        match control as? controls.SplitView {
            none => {}
            // Not swallowed. A divider is read back with `ctd_get_int` and
            // `ctd_get_real`, which answer no platform difference for a control
            // that exists — so the only refusal here is a released split view,
            // and laying its panes out on a guess would hide that.
            some(divided) => { arranger = some(divided.split_layout()?) }
        }
        var node: layout.LayoutNode = layout.LayoutNode.leaf(element.tag, -1)
        match arranger {
            none => { node = self.sheet.leaf(element.tag, control) }
            some(chosen) => { node = self.sheet.group(element.tag, control, chosen)? }
        }
        node.spec = element.spec
        match control as? controls.ChildHolder {
            none => { return ok(node) }
            some(box) => {
                var index: int = 0
                for index: int in 0..element.count() {
                    match box.child_at(index) {
                        some(child) => { node.add(self.node_for(element.child_at(index), child)?) }
                        none => {}
                    }
                }
            }
        }
        return ok(node)
    }

    // ---- events ----

    /// Framework use: records which element a control stands for.
    pub fn record(handle: u64, element: Element) {
        self.by_handle[handle] = element
        // AppKit moves a split view's panes while the user drags its divider.
        // Their descendants still have the boxes from the last solve until
        // the mount solves again. Watch every mounted split, including nested
        // ones; EventRouter.watch replaces an existing watch on a refresh.
        if element.kind == controls.WidgetKind.split_view {
            let owner: Mount = self
            self.router.watch(platform.Handle.of(handle), input.EventKind.value_changed,
                fn(event: input.UiEvent) {
                    match owner.lay_out() {
                        ok(done) => { owner.note_boxes() }
                        err(problem) => {}
                    }
                })
        }
        // The element keeps its control too, which is what lets `Stage` hand a
        // component the controls it rendered without a reverse map anybody has
        // to keep correct.
        element.control = platform.Handle.of(handle)
    }

    /// Framework use: forgets a control that has gone.
    pub fn release(handle: u64) {
        self.by_handle.remove(handle)
        // And what the sheet had been told about it. A handle carries its
        // generation, so a recycled slot is a different key and could not
        // inherit these rows — but a control removed and never replaced would
        // leave them in the map for the life of the mount.
        self.sheet.forget(handle)
    }

    /// Framework use: a property was written to this control, so anything the
    /// layout remembered about its shape is no longer true.
    pub fn wrote_to(handle: u64) {
        self.sheet.forget(handle)
    }

    /// Delivers an event to the handler the current render put on that
    /// control.
    ///
    /// The lookup happens now, not when the handler subscribed, which is what
    /// makes a re-rendered closure take effect with no platform call. A
    /// control whose element has gone — an event already in flight when its
    /// row was removed — is dropped rather than reaching a stale closure.
    pub fn dispatch(handle: u64, kind: input.EventKind, event: input.UiEvent) {
        match self.by_handle.get(handle) {
            none => { return }
            some(element) => {
                match element.listener(kind) {
                    none => { return }
                    some(listener) => { listener.fire(event) }
                }
            }
        }
    }

    /// Whether anything this mount owns has asked to be rendered again.
    pub fn is_dirty() -> bool {
        match self.top {
            none => { return false }
            some(component) => { if component.is_dirty() { return true } }
        }
        for key: string in self.prepared.keys() {
            match self.prepared.get(key) {
                some(child) => { if child.is_dirty() { return true } }
                none => {}
            }
        }
        return false
    }

    /// Renders again only if something asked. What an event loop calls after
    /// handling an event.
    pub fn refresh_if_needed() -> Result<bool> {
        if !self.is_dirty() {
            return ok(false)
        }
        self.refresh()?
        return ok(true)
    }
}
