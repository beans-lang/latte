// Where a component, a renderer and a surface meet.
package stage

import latte.compose
import latte.controls
import latte.geometry
import latte.input
import latte.paint
import latte.platform
import latte.scene
import latte.templates

/// One canvas, one component tree, one renderer. It takes a `paint.Renderer`
/// rather than making one, which is what lets a check run the same scene.
pub class Scene {
    renderer_value: paint.Renderer
    context_value: scene.UiContext
    root_value: controls.Container
    mount: compose.Mount
    template_set: compose.TemplateSet
    size_value: geometry.Size
    scale_value: f64 = 1.0
    closed: bool = false
    layout_version: int = -1
    theme_version: int = -1
    renderer_revision: int = -1

    /// `namespace` separates one scene's handles from another's: two scenes
    /// sharing a number would let one's control be added to the other.
    pub fn init(renderer: paint.Renderer, size: geometry.Size, namespace: int = 1) {
        self.renderer_value = renderer
        self.size_value = size
        self.context_value = new scene.UiContext(renderer, namespace)
        self.root_value = new controls.Container(self.context_value)
        self.mount = new compose.Mount(self.root_value, self.context_value.router())
        self.template_set =
            new compose.TemplateSet(self.context_value, new templates.DefaultTemplates())
        // Read once, where the scene is made. Every motion token answers zero
        // while the setting is on.
        self.context_value.theme()
            .set_reduced_motion(platform.HostDesk.instance.host().reduce_motion())
    }

    pub fn context() -> scene.UiContext { return self.context_value }
    pub fn renderer() -> paint.Renderer { return self.renderer_value }
    pub fn root() -> controls.Container { return self.root_value }
    pub fn size() -> geometry.Size { return self.size_value }
    pub fn scale() -> f64 { return self.scale_value }
    pub fn is_closed() -> bool { return self.closed }

    /// Whether anything is mid-animation. The frame clock reads it: a scene
    /// that answers false is a scene that should stop asking for frames.
    pub fn has_active_animations() -> bool {
        return self.context_value.has_active_animations()
    }

    pub fn advance(seconds: f64) -> Result<bool> {
        self.demand_open("advance a scene")?
        self.context_value.advance(seconds)?
        return self.refresh()
    }

    pub fn use_templates(factory: compose.TemplateFactory) {
        self.template_set.close()
        self.template_set = new compose.TemplateSet(self.context_value, factory)
    }

    pub fn show(view: compose.Component) -> Result<bool> {
        self.demand_open("show a component")?
        self.root_value.set_frame(geometry.Rect.at(geometry.Point.zero(), self.size_value))?
        self.mount.set_bounds(self.size_value)
        self.mount.show(view)?
        return self.refresh()
    }

    pub fn resize(size: geometry.Size, scale: f64) -> Result<bool> {
        self.demand_open("resize a scene")?
        if !(size.width > 0.0 && size.width < 10000000.0 &&
             size.height > 0.0 && size.height < 10000000.0 &&
             scale > 0.0 && scale < 16.0) {
            return err("could not resize a scene: {size.show()} at scale {scale} is not a size anything can draw",
                       "out_of_range")
        }
        self.size_value = size
        self.scale_value = scale
        self.root_value.set_frame(geometry.Rect.at(geometry.Point.zero(), size))?
        self.mount.rescaled(scale)?
        self.mount.resized(size)?
        self.context_value.invalidation().paint()
        return self.refresh()
    }

    /// Settles the geometry before hit testing, without painting: against a
    /// stale tree a click lands on the button that used to be there.
    pub fn prepare_input() -> Result<bool> {
        self.demand_open("prepare a scene for input")?
        self.mount.refresh_if_needed()?
        if self.theme_version != self.context_value.theme().version() ||
           self.layout_version != self.context_value.invalidation().layout_version() {
            self.mount.remeasure()?
            self.theme_version = self.context_value.theme().version()
        }
        self.context_value.validate_input()
        self.template_set.refresh(self.root_value)?
        self.layout_version = self.context_value.invalidation().layout_version()
        return ok(true)
    }

    /// Settles and draws, and answers whether anything was painted. False is
    /// the useful answer: it is what lets an idle page stop asking for frames.
    pub fn refresh() -> Result<bool> {
        self.prepare_input()?
        // A renderer that replaced its surface holds none of the old pixels,
        // so everything is repainted once rather than the dirty part.
        if self.renderer_revision != self.renderer_value.revision() {
            self.context_value.invalidation().paint()
        }
        let was_software: bool = self.renderer_value.software()
        var painted: bool = false
        match self.context_value.draw(self.root_value.render_object()?,
                                      self.size_value, self.scale_value) {
            ok(changed) => { painted = changed }
            err(problem) => {
                // A surface that failed mid-frame is replaced, and the tree
                // replayed onto it once: a second failure is not a lost context.
                if was_software || !self.renderer_value.software() {
                    return err(problem.msg, problem.kind)
                }
                self.context_value.invalidation().paint()
                painted = self.context_value.draw(self.root_value.render_object()?,
                                                  self.size_value, self.scale_value)?
            }
        }
        self.renderer_revision = self.renderer_value.revision()
        self.layout_version = self.context_value.invalidation().layout_version()
        return ok(painted)
    }

    pub fn snapshot() -> Result<paint.Pixels> {
        self.demand_open("read a scene back")?
        let was_software: bool = self.renderer_value.software()
        match self.renderer_value.snapshot() {
            ok(pixels) => { return ok(pixels) }
            err(problem) => {
                if was_software || !self.renderer_value.software() {
                    return err(problem.msg, problem.kind)
                }
                self.context_value.invalidation().paint()
                self.refresh()?
                return self.renderer_value.snapshot()
            }
        }
    }

    // ---- input ----

    pub fn pointer(kind: input.EventKind, point: geometry.Point, button: int = 1,
                   clicks: int = 1, modifiers: int = 0) -> Result<bool> {
        self.demand_open("send a pointer event")?
        self.context_value.pointer(self.root_value.render_object()?, kind, point,
                                   button, clicks, modifiers)?
        return self.refresh()
    }

    pub fn key(kind: input.EventKind, key: input.Key, text: string = "",
               modifiers: int = 0) -> Result<bool> {
        self.demand_open("send a key event")?
        self.context_value.key(self.root_value.render_object()?, kind, key, text, modifiers)?
        return self.refresh()
    }

    pub fn scroll(point: geometry.Point, dx: f64, dy: f64) -> Result<bool> {
        self.apply_scroll(point, dx, dy)?
        return self.refresh()
    }

    /// Applies wheel input without drawing, for a host that draws at its next
    /// frame: keeping the two apart is one draw per frame, not per event.
    pub fn apply_scroll(point: geometry.Point, dx: f64, dy: f64) -> Result<bool> {
        self.demand_open("scroll a scene")?
        return self.context_value.scroll(self.root_value.render_object()?, point, dx, dy)
    }

    /// Text from an input method, aimed at whatever has the keyboard. `index`
    /// and `token` are the composition's selection in bytes, or -1 for none.
    pub fn text_input(kind: input.EventKind, text: string, index: int = -1,
                      token: int = -1) -> Result<bool> {
        self.demand_open("send text input")?
        match self.context_value.focused_object() {
            some(object) => {
                let event: input.UiEvent =
                    input.UiEvent.of(kind, platform.Handle.of(object.handle()))
                event.text = text
                event.index = index
                event.token = token
                self.context_value.dispatch(event)?
            }
            none => {}
        }
        return self.refresh()
    }

    pub fn focused_object() -> Option<scene.RenderObject> {
        return self.context_value.focused_object()
    }

    /// Where an input method should put its editing element, in SCENE
    /// coordinates, or `none` when nothing is being edited.
    pub fn editing_spot() -> Option<scene.EditingSpot> {
        match self.context_value.focused_object() {
            none => { return none }
            some(object) => {
                match object.editing_spot() {
                    none => { return none }
                    some(spot) => {
                        match self.global_frame(object) {
                            err(problem) => { return none }
                            ok(frame) => {
                                return some(new scene.EditingSpot(spot.text, spot.anchor, spot.caret,
                                    geometry.Rect.of(frame.x + spot.rect.x, frame.y + spot.rect.y,
                                                     spot.rect.width, spot.rect.height)))
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn global_frame(object: scene.RenderObject) -> Result<geometry.Rect> {
        return self.context_value.global_frame(object)
    }

    pub fn global_visual_frame(object: scene.RenderObject) -> Result<geometry.Rect> {
        return self.context_value.global_visual_frame(object)
    }

    // ---- accessibility ----

    /// The semantics tree, in paint order, built fresh: a cached copy would be
    /// a second tree to keep in step with the first.
    pub fn semantics() -> List<scene.SemanticsNode> {
        var nodes: List<scene.SemanticsNode> = []
        match self.root_value.render_object() {
            ok(root) => { self.collect_semantics(root, nodes, true, geometry.Point.zero()) }
            err(_) => {}
        }
        match self.context_value.popups().root() {
            some(popup) => { self.collect_semantics(popup, nodes, true, geometry.Point.zero()) }
            none => {}
        }
        return move nodes
    }

    /// `origin` is where this node's own box starts from — the running sum of
    /// every ancestor's frame and child offset, carried down rather than
    /// rebuilt per node. Climbing back up cost a registry lookup per ancestor
    /// for every node in the tree, which on a table is most of a frame.
    fn collect_semantics(object: scene.RenderObject, nodes: List<scene.SemanticsNode>,
                         enabled: bool, origin: geometry.Point) {
        if !object.is_alive() || object.is_hidden() { return }
        let layout: geometry.Rect = object.frame()
        let visual: geometry.Rect = object.visual_frame()
        let node: scene.SemanticsNode = object.semantics_at(
            geometry.Rect.of(origin.x + visual.x, origin.y + visual.y,
                             visual.width, visual.height))
        let live: bool = enabled && node.enabled()
        if live != node.enabled() {
            nodes.push(new scene.SemanticsNode(node.id(), node.role(), node.label(),
                                               node.value(), node.bounds(), live))
        } else {
            nodes.push(node)
        }
        if object.interactive_visual() {
            match object.visual() {
                some(visual_root) => {
                    let shift: geometry.Point = object.child_offset_for(visual_root.handle())
                    self.collect_semantics(visual_root, nodes, live,
                        geometry.Point.at(origin.x + layout.x + shift.x,
                                          origin.y + layout.y + shift.y))
                }
                none => {}
            }
        }
        if !object.shows_children() { return }
        let inside: geometry.Point = object.child_offset()
        let start: geometry.Point = geometry.Point.at(origin.x + layout.x + inside.x,
                                                      origin.y + layout.y + inside.y)
        for index: int in 0..object.child_count() {
            if !object.shows_child(index) { continue }
            match object.child_at(index) {
                some(child) => { self.collect_semantics(child, nodes, live, start) }
                none => {}
            }
        }
    }

    /// The revision the semantics tree is at. A page that published this one
    /// already has nothing to send.
    pub fn semantics_version() -> int {
        return self.context_value.invalidation().semantics_version()
    }

    /// Runs what assistive technology asked for on one node.
    pub fn semantics_action(handle: u64, action: SemanticsAction) -> Result<bool> {
        self.demand_open("run an accessibility action")?
        match action {
            activate => {
                self.context_value.dispatch(
                    input.UiEvent.of(input.EventKind.activate, platform.Handle.of(handle)))?
            }
            focus => { self.context_value.focus(handle)? }
        }
        return self.refresh()
    }

    // ---- teardown ----

    /// Drops everything this scene owns, in the order that keeps each drop
    /// legal, and the renderer last. Safe twice, and called from `deinit`.
    pub fn close() {
        if self.closed { return }
        self.closed = true
        self.template_set.close()
        self.mount.close()
        self.root_value.release()
        self.context_value.close()
    }

    fn deinit() { self.close() }

    fn demand_open(attempt: string) -> Result<bool> {
        if self.closed {
            return err("could not {attempt}: it was closed", "stale_handle")
        }
        return ok(true)
    }
}

/// What assistive technology can ask a node to do.
pub enum SemanticsAction {
    activate
    focus

    pub fn name() -> string {
        return match self { activate => "activate", focus => "focus" }
    }

    pub static fn of(code: int) -> Option<SemanticsAction> {
        if code == 1 { return some(SemanticsAction.activate) }
        if code == 2 { return some(SemanticsAction.focus) }
        return none
    }
}
