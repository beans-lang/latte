package compose

import latte.scene
import latte.controls
import latte.geometry

class TemplateInstance {
    owner: scene.RenderObject
    context: scene.UiContext
    root: controls.Container
    view: ControlTemplate
    mount: Mount
    shown: bool = false
    closed: bool = false
    popup: bool
    pub fn init(owner: scene.RenderObject, context: scene.UiContext, view: ControlTemplate, popup: bool = false) {
        self.owner = owner; self.context = context; self.view = view
        self.popup = popup
        self.root = new controls.Container(context)
        self.mount = new Mount(self.root, context.router())
        self.view.bind_actions(context.actions(owner.handle()))
    }
    fn refresh(viewport: geometry.Size) -> Result<bool> {
        var bounds: geometry.Rect = geometry.Rect.at(geometry.Point.zero(), self.owner.template_size())
        if self.popup {
            let owner: geometry.Rect = self.context.global_frame(self.owner)?
            bounds = self.owner.popup_bounds()
            if !(bounds.width > 0.0 && bounds.height > 0.0) { return err("popup must have positive bounds", "out_of_range") }
            bounds.x += owner.x; bounds.y += owner.y
            if bounds.width > viewport.width { bounds.width = viewport.width }
            if bounds.height > viewport.height { bounds.height = viewport.height }
            if bounds.y + bounds.height > viewport.height { bounds.y = owner.y - bounds.height }
            if bounds.x + bounds.width > viewport.width { bounds.x = viewport.width - bounds.width }
            if bounds.x < 0.0 { bounds.x = 0.0 }
            if bounds.y < 0.0 { bounds.y = 0.0 }
        }
        let size: geometry.Size = bounds.size()
        self.root.set_frame(bounds)?
        self.view.update(self.owner, self.context.theme())
        if !self.shown {
            self.mount.set_bounds(size)
            self.mount.show(self.view)?
            if !self.popup { self.owner.set_visual(some(self.root.render_object()?))? }
            self.shown = true
        } else {
            self.mount.resized(size)?
            self.mount.refresh_if_needed()?
        }
        if self.popup {
            self.view.decorate_popup(self.root.render_object()?)?
            self.context.popups().show(self.owner, self.root.render_object()?)?
        }
        if !self.popup && self.owner.visual_focus_requested() {
            match self.first_focusable(self.root.render_object()?) {
                some(part) => {
                    self.context.focus(part.handle())?
                    self.owner.acknowledge_visual_focus()
                }
                none => {}
            }
        }
        return ok(true)
    }
    fn first_focusable(root: scene.RenderObject) -> Option<scene.RenderObject> {
        if !self.context.interactive(root) { return none }
        if root.is_focusable() { return some(root) }
        for index: int in 0..root.child_count() {
            match root.child_at(index) {
                some(child) => {
                    match self.first_focusable(child) { some(found) => { return some(found) } none => {} }
                }
                none => {}
            }
        }
        return none
    }
    fn close() {
        if self.closed { return }
        self.closed = true
        if self.popup {
            if self.context.popups().owner() == self.owner.handle() { self.context.popups().dismiss() }
        } else { self.owner.set_visual(none) }
        self.mount.close()
        self.root.release()
    }
    fn deinit() { self.close() }
}

/// Owns template mounts separately from the logical widgets. No registry or
/// render object points back to these mounts, so teardown has no owner cycle.
pub class TemplateSet {
    context: scene.UiContext
    factory: TemplateFactory
    mounted: Map<u64, TemplateInstance> = {}
    popups: Map<u64, TemplateInstance> = {}
    used: Map<u64, bool> = {}
    popup_used: Map<u64, bool> = {}
    viewport: geometry.Size = geometry.Size.zero()
    pub fn init(context: scene.UiContext, factory: TemplateFactory) { self.context = context; self.factory = factory }
    pub fn refresh(root: controls.Widget) -> Result<bool> {
        self.used = {}
        self.popup_used = {}
        self.viewport = root.render_object()?.frame().size()
        self.context.popups().validate()
        self.visit(root, 0, false)?
        for key: u64 in self.popups.keys() {
            match self.popups.get(key) {
                some(instance) => {
                    if !self.popup_used.get(key).or(false) || !instance.owner.popup_open() {
                        instance.close(); self.popups.remove(key)
                    }
                }
                none => {}
            }
        }
        let keys: List<u64> = self.mounted.keys()
        for key: u64 in keys {
            if !self.used.get(key).or(false) {
                match self.mounted.get(key) { some(instance) => { instance.close() } none => {} }
                self.mounted.remove(key)
            }
        }
        return ok(true)
    }
    /// The look a control takes where it stands. Inside an open popup a theme
    /// may dress it differently; a theme that does not just answers the same.
    fn look(object: scene.RenderObject, in_popup: bool) -> Option<ControlTemplate> {
        if in_popup {
            match self.factory as? PopupRowTemplateFactory {
                some(factory) => {
                    match factory.create_in_popup(object) {
                        some(view) => { return some(view) }
                        none => {}
                    }
                }
                none => {}
            }
        }
        return self.factory.create(object)
    }
    fn visit(widget: controls.Widget, depth: int, in_popup: bool) -> Result<bool> {
        if depth > 64 { return err("control templates contain a recursive visual tree", "template_cycle") }
        let object: scene.RenderObject = widget.render_object()?
        if object.needs_template() {
            let key: u64 = object.handle()
            self.used[key] = true
            match self.mounted.get(key) {
                some(instance) => { instance.refresh(self.viewport)?; self.visit(instance.root, depth + 1, in_popup)? }
                none => {
                    match self.look(object, in_popup) {
                        none => { return err("no .bx template for shared control", "missing_template") }
                        some(view) => {
                            let instance: TemplateInstance = new TemplateInstance(object, self.context, view)
                            instance.refresh(self.viewport)?
                            self.mounted[key] = instance
                            self.visit(instance.root, depth + 1, in_popup)?
                        }
                    }
                }
            }
        }
        if object.popup_open() && self.context.interactive(object) {
            let key: u64 = object.handle()
            self.popup_used[key] = true
            match self.popups.get(key) {
                some(instance) => { instance.refresh(self.viewport)?; self.visit(instance.root, depth + 1, true)? }
                none => {
                    match self.factory as? PopupTemplateFactory {
                        some(factory) => {
                            match factory.create_popup(object) {
                                some(view) => {
                                    let instance: TemplateInstance = new TemplateInstance(object, self.context, view, true)
                                    instance.refresh(self.viewport)?
                                    self.popups[key] = instance
                                    self.visit(instance.root, depth + 1, true)?
                                }
                                none => { return err("no .bx popup template for shared control", "missing_template") }
                            }
                        }
                        none => { return err("theme does not supply popup templates", "missing_template") }
                    }
                }
            }
        }
        for child: controls.Widget in widget.children() { self.visit(child, depth + 1, in_popup)? }
        return ok(true)
    }
    pub fn close() {
        for key: u64 in self.popups.keys() {
            match self.popups.get(key) { some(instance) => { instance.close() } none => {} }
        }
        self.popups.clear()
        for key: u64 in self.mounted.keys() {
            match self.mounted.get(key) { some(instance) => { instance.close() } none => {} }
        }
        self.mounted.clear()
    }
    fn deinit() { self.close() }
}
