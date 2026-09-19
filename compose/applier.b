// Turning edits into platform calls.
package compose

import latte.controls
import latte.input
import latte.platform

/// Applies a list of `Change`s to a real widget tree.
///
/// The only class in `latte.compose` that touches a control. Everything
/// above it — the builder, the elements, the differ — is values, which is why
/// all of that is tested on machines with no display and this is tested
/// against AppKit.
///
/// Two things it is careful about:
///
/// **Order.** Changes arrive in the order the differ produced them, and that
/// order is load-bearing: removals come from the back so they do not renumber
/// each other, and creations and moves are interleaved with property writes
/// that address positions those very operations decide. Applying them in any
/// other order addresses the wrong child.
///
/// **Handlers are not changes.** A closure cannot be compared, so the differ
/// never emits one. After the structural work is done the applier walks the
/// new tree once and records each element against the handle of the control it
/// became, which is what `Mount.dispatch` reads when an event arrives. That
/// walk costs no platform call at all.
pub class Applier {
    root: controls.Widget
    router: input.EventRouter
    owner: Mount

    pub fn init(root: controls.Widget, router: input.EventRouter, owner: Mount) {
        self.root = root
        self.router = router
        self.owner = owner
    }

    /// Applies every change, in order.
    pub fn apply(changes: List<Change>) -> Result<int> {
        var done: int = 0
        for change: Change in changes {
            self.one(change)?
            done = done + 1
        }
        return ok(done)
    }

    fn one(change: Change) -> Result<bool> {
        let target: controls.Widget = self.resolve(change)?
        match change.kind {
            set => {
                // Writing to a control can change the room it keeps for its
                // own chrome — a group box retitled draws a wider border, a
                // disclosure retitled a taller header — and the layout sheet
                // remembers that answer between passes. So it is forgotten
                // here, at the one place in latte where a property is
                // written, rather than at each of the setters.
                self.owner.wrote_to(target.handle().raw)
                // Stepped over where the platform has not got the property,
                // for the reason `write_all` gives: a screen still renders.
                match WidgetMaker.write(target, change.attribute) {
                    ok(done) => { return ok(true) }
                    err(problem) => {
                        return err(problem.msg, problem.kind)
                    }
                }
            }
            bind => {
                // The closure looks the handler up at the moment the event
                // arrives, never at the moment it subscribes. That is what
                // lets a re-render replace a handler without touching the
                // platform, and what keeps the router's table free of
                // references back into the component tree.
                let owner: Mount = self.owner
                let handle: u64 = target.handle().raw
                let kind: input.EventKind = change.event
                self.router.on(target.handle(), kind,
                    fn(event: input.UiEvent) { owner.dispatch(handle, kind, event) })
                return ok(true)
            }
            unbind => {
                self.router.off(target.handle(), change.event)
                return ok(true)
            }
            create => {
                match change.element {
                    none => { return err("a create carried no element to build", "empty_create") }
                    some(element) => {
                        let built: controls.Widget = WidgetMaker.make(element, self.root.render_context())?
                        self.container(target, change)?.insert(built, change.index)?
                        // A `create` carries a whole subtree, and the differ
                        // emits no `bind` for anything inside it — there was no
                        // previous tree to compare against. So the handlers in
                        // a newly built subtree are subscribed here. Without
                        // this every first render produces controls that look
                        // right and do nothing, which is a bug that only a
                        // test firing a real click can see.
                        return self.subscribe(element, built)
                    }
                }
            }
            remove => {
                let box: controls.Holder = self.container(target, change)?
                match box.child_at(change.index) {
                    none => { return box.remove(change.index) }
                    some(going) => {
                        self.forget(going)
                        box.remove(change.index)?
                        // And then the control itself. Dropping the last Beans
                        // reference would get there eventually, but "eventually"
                        // means after the layout sheet that also holds it has
                        // been rebuilt — so a list that churned rows kept a
                        // native control per dead row until the next render,
                        // and a torn-down screen kept all of them.
                        //
                        // After `remove`, not before: releasing a control while
                        // it is still a child leaves the parent unparenting a
                        // handle the platform has already let go.
                        self.let_go(going)
                        return ok(true)
                    }
                }
            }
            relocate => {
                return self.container(target, change)?.move_child(change.index, change.target)
            }
        }
    }

    /// Subscribes every listener in a freshly built subtree.
    fn subscribe(element: Element, control: controls.Widget) -> Result<bool> {
        var index: int = 0
        for index: int in 0..element.listener_count() {
            let owner: Mount = self.owner
            let handle: u64 = control.handle().raw
            let kind: input.EventKind = element.listener_at(index).kind
            self.router.on(control.handle(), kind,
                fn(event: input.UiEvent) { owner.dispatch(handle, kind, event) })
        }
        if element.count() == 0 {
            return ok(true)
        }
        match control as? controls.ChildHolder {
            none => {
                return err("<{element.tag}> has children but its control holds none", "tree_drift")
            }
            some(box) => {
                for index: int in 0..element.count() {
                    match box.child_at(index) {
                        none => { return err("child {index} of <{element.tag}> is missing", "tree_drift") }
                        some(child) => { self.subscribe(element.child_at(index), child)? }
                    }
                }
            }
        }
        return ok(true)
    }

    /// The control a change addresses.
    ///
    /// A change that acts on the surface names the container this mount was
    /// given. Everything else names an element, and the element tree's root is
    /// that container's only child — so an element path is walked from there.
    fn resolve(change: Change) -> Result<controls.Widget> {
        if change.at_surface {
            return ok(self.root)
        }
        var here: controls.Widget = self.face()?
        var step: int = 0
        for step: int in 0..change.depth() {
            let index: int = change.step(step)
            let children: List<controls.Widget> = here.children()
            if index < 0 || index >= children.len() {
                return err("{change.path_text()} names child {index} of a {here.kind().name()} with {children.len()}",
                           "bad_path")
            }
            here = children[index]
        }
        return ok(here)
    }

    /// The control a structural change acts inside.
    ///
    /// Two kinds hold children, and a `ScrollView` is not a `Container` — it
    /// keeps its own list and puts the children somewhere the platform decided.
    /// A `Holder` is the interface both answer, so the applier does not care
    /// which it has.
    fn container(target: controls.Widget, change: Change) -> Result<controls.Holder> {
        match target as? controls.ChildHolder {
            some(box) => { return ok(box) }
            none => {}
        }
        match target as? controls.ScrollView {
            some(scroller) => { return ok(scroller) }
            none => {}
        }
        return err("{change.kind.name()} at {change.path_text()} needs something that holds children, but that is a {target.kind().name()}",
                   "not_a_container")
    }

    /// Drops every registration under a subtree that is going away.
    ///
    /// Without this the router keeps a closure per removed control for the
    /// life of the window. The closure holds the mount, the mount holds
    /// everything — so one list that churns a thousand rows would hold a
    /// thousand dead subscriptions, and nothing would ever say so.
    /// Releases a subtree's controls, depth first.
    ///
    /// Separate from `forget` because they happen at different moments:
    /// forgetting has to precede the removal, so a handler cannot fire at a
    /// control on its way out, and releasing has to follow it.
    fn let_go(going: controls.Widget) {
        for child: controls.Widget in going.children() {
            self.let_go(child)
        }
        going.release()
    }

    fn forget(going: controls.Widget) {
        self.router.forget(going.handle())
        self.owner.release(going.handle().raw)
        for child: controls.Widget in going.children() {
            self.forget(child)
        }
    }

    /// Records which element each control now stands for.
    ///
    /// Walked after every apply, over the element tree and the widget tree
    /// together — they have the same shape, because the applier just made them
    /// so. No platform call happens here; it is a map write per element, and
    /// it is what makes a handler always the current one.
    ///
    /// It starts at the root container's *first child*, not at the container:
    /// the mount is given a box to fill, and the element tree is what goes
    /// inside it. The empty path in a `Change` names that box for the same
    /// reason, which is why a first render reads `create root[0]`.
    pub fn index(element: Element) -> Result<bool> {
        return self.index_at(element, self.face()?)
    }

    /// The control the element tree's root became.
    pub fn face() -> Result<controls.Widget> {
        match self.root as? controls.ChildHolder {
            none => { return err("a mount needs a container to fill", "not_a_container") }
            some(box) => {
                match box.child_at(0) {
                    none => { return err("nothing has been mounted yet", "not_mounted") }
                    some(child) => { return ok(child) }
                }
            }
        }
    }

    fn index_at(element: Element, control: controls.Widget) -> Result<bool> {
        self.owner.record(control.handle().raw, element)
        match control as? controls.TabView { some(tabs) => { tabs.validate_pages()? } none => {} }
        if element.count() == 0 {
            return ok(true)
        }
        match control as? controls.ChildHolder {
            none => {
                return err("<{element.tag}> has {element.count()} children but its control holds none",
                           "tree_drift")
            }
            some(box) => {
                if box.count() != element.count() {
                    return err("<{element.tag}> has {element.count()} children but its control has {box.count()}",
                               "tree_drift")
                }
                var index: int = 0
                for index: int in 0..element.count() {
                    match box.child_at(index) {
                        none => { return err("child {index} of <{element.tag}> is missing", "tree_drift") }
                        some(child) => { self.index_at(element.child_at(index), child)? }
                    }
                }
            }
        }
        return ok(true)
    }
}
