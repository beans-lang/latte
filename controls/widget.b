// The control every other control extends.
package controls

import latte.platform
import latte.geometry
import latte.input
import latte.scene
import latte.visual

/// A control's text with its line breaks and tabs escaped, so one widget
/// occupies exactly one line of a dump.
fn one_line(text: string) -> string {
    return text.replace("\\", "\\\\")
               .replace("\n", "\\n")
               .replace("\r", "\\r")
               .replace("\t", "\\t")
}

/// A control in a Latte scene.
///
/// Every `Widget` owns exactly one `scene.RenderObject` and drops it in
/// `release()`. Ownership runs one way: a container holds its children as
/// Beans references, so the Beans tree *is* the lifetime tree, and a subtree
/// dies when the last reference to its root does. The scene's own node list
/// follows along; it never owns anything Latte does not.
///
/// Everything here answers `Result`. A control can fail for reasons the caller
/// cannot see coming — the node was released, the property does not apply to
/// this kind — and a method that swallowed those would leave a control
/// silently not doing what the code says.
pub abstract class Widget {
    kind_value: WidgetKind = WidgetKind.container
    released: bool = false

    context: scene.UiContext
    node_value: Option<scene.RenderObject> = none
    build_error: string = ""

    fn init(kind: WidgetKind, context: scene.UiContext, drawing: Option<visual.Kind> = none) {
        self.kind_value = kind
        self.released = false
        self.context = context
        match SharedFactory.make(kind, context, drawing) {
            err(problem) => { self.build_error = problem.msg }
            ok(object) => {
                match context.add(object) {
                    err(problem) => { self.build_error = problem.msg }
                    ok(_) => { self.node_value = some(object) }
                }
            }
        }
    }

    /// The scene this control draws into.
    pub fn render_context() -> scene.UiContext { return self.context }

    /// The render object, or the reason there is none.
    ///
    /// A Beans `init` cannot fail, so a control whose kind the renderer does
    /// not implement is built and then refuses here — with the message the
    /// factory wrote, naming the kind, rather than a null dereference.
    pub fn node() -> Result<scene.RenderObject> {
        match self.node_value {
            some(object) => { object.demand_alive()?; return ok(object) }
            none => {
                return err(if self.build_error == "" {
                               "a {self.kind_value.name()} has no render object"
                           } else { self.build_error }, "not_rendered")
            }
        }
    }

    /// The same object, for callers outside this package.
    pub fn render_object() -> Result<scene.RenderObject> { return self.node() }

    /// The scene's own id for this control's render object.
    ///
    /// Not a pointer: the scene packs a generation counter into the high half,
    /// so a handle kept past its node's life resolves to nothing and every
    /// call answers `stale` instead of reaching a freed object.
    pub fn handle() -> platform.Handle {
        match self.node_value {
            some(object) => { return platform.Handle.of(object.handle()) }
            none => { return platform.Handle.none() }
        }
    }

    pub fn kind() -> WidgetKind {
        return self.kind_value
    }

    /// Whether the host still has this widget. False after `release()`, and
    /// false if construction failed.
    pub fn is_alive() -> bool {
        match self.node_value {
            some(object) => { return object.is_alive() }
            none => { return false }
        }
    }

    // ---- geometry ----

    pub fn set_frame(frame: geometry.Rect) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_frame(frame)
    }

    pub fn frame() -> Result<geometry.Rect> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.frame())
    }

    /// How big this control wants to be inside `available`.
    ///
    /// A negative component of `available` means unbounded in that direction.
    /// This is the layout engine's one call into the platform: text metrics
    /// are the only thing latte cannot compute for itself.
    pub fn measure(available: geometry.Size) -> Result<geometry.Size> {
        let node: scene.RenderObject = self.node()?
        return node.measure(available)
    }

    // ---- state ----

    pub fn set_enabled(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_ENABLED, on, "enable a {self.kind_value.name()}")
    }

    pub fn is_enabled() -> Result<bool> {
        return self.read_flag(platform.P_ENABLED, "read whether a {self.kind_value.name()} is enabled")
    }

    /// How opaque this control is, 0.0 to 1.0.
    ///
    /// Every kind has one, containers included: unlike `enabled` this really is
    /// a property of any view, and fading a box fades everything in it, which
    /// is what a caller means by it and what all four platforms already do.
    ///
    /// Out of range is a refusal rather than a clamp. A caller that computed
    /// 1.5 has a bug, and quietly showing them 1.0 hides it.
    pub fn set_opacity(value: f64) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_real(platform.P_OPACITY, value)
    }

    pub fn opacity() -> Result<f64> {
        return self.read_real(platform.P_OPACITY,
                              "read the opacity of a {self.kind_value.name()}")
    }

    // ---- how a control is dressed ----
    // Which controls refuse a background is the render object's own rule.
    // Corners and borders have no rule: every control takes both.

    /// The colour behind this control's own drawing.
    ///
    /// Refused by name on the four bezelled text controls: the only way to
    /// show a colour there is to remove the bezel, and then it is not the
    /// theme's text field.
    pub fn set_background(shade: Rgba) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_integer(platform.P_BG_COLOR, shade.packed())
    }

    pub fn background() -> Result<Rgba> {
        let packed: int = self.read_property(platform.P_BG_COLOR)?
        return ok(Rgba.of_packed(packed))
    }

    /// The colour of this control's own text.
    ///
    /// Carried by a label and the four controls you type into, and refused by
    /// name on everything else. A button, a check box and a radio button draw
    /// their words as a title inside the theme's bezel — three mechanisms
    /// with one name — and a link's colour is the theme's.
    ///
    /// Without this `set_background` was half a property: a pale background
    /// behind a label and no way to stop the system drawing white on it.
    pub fn set_text_color(shade: Rgba) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_integer(platform.P_FG_COLOR, shade.packed())
    }

    pub fn text_color() -> Result<Rgba> {
        let packed: int = self.read_property(platform.P_FG_COLOR)?
        return ok(Rgba.of_packed(packed))
    }

    /// Corner rounding in points. Zero is square.
    pub fn set_corner_radius(points: f64) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_real(platform.P_CORNER_RADIUS, points)
    }

    pub fn corner_radius() -> Result<f64> {
        return self.read_real(platform.P_CORNER_RADIUS,
                              "read the corner radius of a {self.kind_value.name()}")
    }

    /// An outline drawn inside the bounds, like CALayer and CSS: an outside
    /// one needs room the layout never gave it.
    pub fn set_border(points: f64, shade: Rgba) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        node.set_integer(platform.P_BORDER_COLOR, shade.packed())?; return node.set_real(platform.P_BORDER_WIDTH, points)
    }

    pub fn border_width() -> Result<f64> {
        return self.read_real(platform.P_BORDER_WIDTH,
                              "read the border width of a {self.kind_value.name()}")
    }

    // ---- a control a program draws itself ----

    /// Whether this control can take the keyboard.
    ///
    /// A canvas and nothing else: every other control's answer is the
    /// platform's. Off by default, so a decorative canvas stays out of the way.
    pub fn set_focusable(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_FOCUSABLE, on,
                             "let a {self.kind_value.name()} take the keyboard")
    }

    pub fn is_focusable() -> Result<bool> {
        return self.read_flag(platform.P_FOCUSABLE,
                              "read whether a {self.kind_value.name()} takes the keyboard")
    }

    /// What a screen reader calls this control when its own text is not it —
    /// an icon-only button, or a canvas, which draws no text latte wrote.
    ///
    /// Carried by every kind. Reading it back answers **what a screen reader
    /// will say** — the label when one was set, and the control's own text
    /// when none was — so `""` means genuinely silent rather than merely
    /// unnamed.
    pub fn set_a11y_label(said: string) -> Result<bool> {
        return self.set_string(platform.S_A11Y_LABEL, said,
                               "name a {self.kind_value.name()} for a screen reader")
    }

    pub fn a11y_label() -> Result<string> {
        return self.string_at(platform.S_A11Y_LABEL,
                              "read what a {self.kind_value.name()} is called")
    }

    /// What kind of thing a canvas is, to a screen reader. See `A11yRole`.
    pub fn set_a11y_role(role: A11yRole) -> Result<bool> {
        return self.set_property(platform.P_A11Y_ROLE, role.code())
    }

    pub fn set_hidden(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_HIDDEN, on, "hide a {self.kind_value.name()}")
    }

    pub fn is_hidden() -> Result<bool> {
        return self.read_flag(platform.P_HIDDEN, "read whether a {self.kind_value.name()} is hidden")
    }

    fn set_flag(key: int, on: bool, attempt: string) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_integer(key, if on { 1 } else { 0 })
    }

    /// Reads one real-valued property by its `platform.P_*` id.
    ///
    /// Package-private: the subclass that has the property exposes it under a
    /// name that says what it is — a slider's `value`, a progress bar's — and
    /// the generic form is for them and for the applier.
    fn read_real(key: int, attempt: string) -> Result<f64> {
        let node: scene.RenderObject = self.node()?
        return node.real(key)
    }

    fn read_flag(key: int, attempt: string) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return ok(node.integer(key)? != 0)
    }

    /// Writes one of a control's other strings by its `platform.S_*` id.
    ///
    /// Public for the reason `set_property` is: a test that asks what a *kind*
    /// answers has no named accessor to reach for, and the applier writes by
    /// id. Application code wants the named one — `field.set_hint(...)` says
    /// what it means.
    pub fn set_string_at(key: int, text: string) -> Result<bool> {
        return self.set_string(key, text, "set string {key} of a {self.kind_value.name()}")
    }

    pub fn string_at_key(key: int) -> Result<string> {
        return self.string_at(key, "read string {key} of a {self.kind_value.name()}")
    }

    /// Writes one of a control's *other* strings by its `platform.S_*` id.
    ///
    /// `set_text_raw` is the text a control **is** — a button's title, a
    /// field's value. A control can carry more than one: a field has words it
    /// shows while it is empty. Those are keyed, for the same reason the
    /// scalar properties are, and each subclass exposes the ones it has under
    /// a name that says what they mean.
    fn set_string(key: int, text: string, attempt: string) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_string(key, text)
    }

    fn string_at(key: int, attempt: string) -> Result<string> {
        let node: scene.RenderObject = self.node()?
        return node.string_at(key)
    }

    // Text lives on the base because three kinds carry it and the host keys it
    // by widget, not by class. Subclasses expose it under the name their
    // control actually uses: a button has a title, a field has a value.
    fn set_text_raw(text: string) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_text(text)
    }

    fn text_raw() -> Result<string> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.text())
    }

    // ---- the platform's own child list ----
    //
    // Two controls hold children — a `Container` and a `ScrollView` — and both
    // keep a Beans list beside the platform's. The three calls that keep the
    // two in step live here rather than being written twice, because a fix to
    // one copy and not the other is exactly the drift the tree dump exists to
    // catch.

    fn attach_child(child: Widget, index: int) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        let rendered: scene.RenderObject = child.render_object()?
        if child.render_context().registry().namespace() !=
           self.context.registry().namespace() {
            return err("a {child.kind().name()} built for one scene cannot go into another",
                       "bad_owner")
        }
        return node.insert(rendered, index)
    }

    fn detach_child(child: Widget) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.remove(child.render_object()?)
    }

    fn reorder_child(from: int, to: int) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.move_child(from, to)
    }

    // ---- generic property access ----
    //
    // The component layer applies a render's result by property id, because
    // the differ compares integers and a translation back to method names
    // would put a string table in the hot path of every frame. Application
    // code should reach for the named methods above and the ones each subclass
    // adds — `set_enabled`, `Button.set_title` — which say what they do.

    /// Writes the text this control shows, whatever the control calls it.
    pub fn set_display_text(text: string) -> Result<bool> {
        return self.set_text_raw(text)
    }

    /// Writes one integer property by its `platform.P_*` id.
    pub fn set_property(property: int, value: int) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_integer(property, value)
    }

    /// Reads one integer property back by its `platform.P_*` id.
    ///
    /// The counterpart of `set_property`, and public for the same reason: the
    /// applier writes attributes by id, and a test that asks what a *kind*
    /// answers has no named accessor to reach for — a `Label` has no
    /// `is_checked()` and should not grow one just to be refused.
    ///
    /// Application code wants the named accessor. `check_box.state()` says
    /// what it reads and returns a `CheckState`; this returns an integer whose
    /// meaning is in a C header.
    pub fn read_property(property: int) -> Result<int> {
        let node: scene.RenderObject = self.node()?
        return node.integer(property)
    }

    /// Reads one real-valued property back by its `platform.P_*` id.
    ///
    /// Public for the same reason `read_property` is: a test that asks what a
    /// *kind* answers has no named accessor to reach for. Application code
    /// wants `slider.value()`, which says what it reads.
    pub fn read_property_real(property: int) -> Result<f64> {
        return self.read_real(property, "read property {property} of a {self.kind_value.name()}")
    }

    /// Writes one real-valued property by its `platform.P_*` id.
    pub fn set_property_real(property: int, value: f64) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_real(property, value)
    }

    // ---- introspection ----

    /// Latte's own class name for this control. The test suite expected output-files
    /// it, because it is the answer that proves the right render object was
    /// built and not a stand-in.
    pub fn native_class() -> Result<string> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok("Latte{self.kind_value.name()}")
    }

    /// The accessibility role, in one vocabulary shared by every platform.
    pub fn a11y_role() -> Result<string> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.role())
    }

    /// How many children the platform says this widget has.
    ///
    /// latte keeps its own child list, and these two numbers must agree.
    /// They are read separately and compared on purpose: the Beans list is
    /// bookkeeping, and bookkeeping that is never checked against the thing it
    /// describes is how a tree ends up correct on paper and wrong on screen.
    pub fn native_child_count() -> Result<int> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.child_count())
    }

    /// The n-th child, as the platform has it. Answers `none` past the end.
    pub fn native_child_at(index: int) -> Option<platform.Handle> {
        match self.node_value {
            some(object) => {
                match object.child_at(index) {
                    some(child) => { return some(platform.Handle.of(child.handle())) }
                    none => { return none }
                }
            }
            none => { return none }
        }
    }

    /// The widget this one sits inside, as the platform has it.
    pub fn native_parent() -> Option<platform.Handle> {
        match self.node_value {
            some(object) => {
                return if object.parent() == 0 { none }
                       else { some(platform.Handle.of(object.parent())) }
            }
            none => { return none }
        }
    }

    /// What kind the platform thinks this widget is.
    ///
    /// latte already knows — it asked for the kind when it built the widget.
    /// Asking again and comparing is what turns "the handle table is correct"
    /// from an assumption into something the test suite checks.
    pub fn native_kind() -> Option<WidgetKind> {
        return if self.is_alive() { some(self.kind_value) } else { none }
    }

    pub fn set_font_size(points: f64) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_real(platform.P_FONT_SIZE, points)
    }

    pub fn font_size() -> Result<f64> {
        let node: scene.RenderObject = self.node()?
        return node.real(platform.P_FONT_SIZE)
    }

    /// The children this widget contains. Empty for everything that is not a
    /// container, so a tree walk needs no downcast and no kind check.
    pub fn children() -> List<Widget> {
        return []
    }

    /// The text this control shows, or "" for one that shows none.
    ///
    /// Overridden rather than downcast to: a dump that asked "is this a
    /// Button?" would need editing every time a kind was added, and would
    /// silently print nothing for the one somebody forgot.
    pub fn display_text() -> Result<string> {
        return ok("")
    }

    /// One line describing this widget: what latte calls it, what the
    /// platform calls it, how assistive technology sees it, its text, its
    /// frame, and whatever state is not at its default.
    ///
    /// This is the line the test expected outputs carry, and it is deliberately built
    /// here in Beans rather than in the platform. If the host formatted it, the
    /// interpreter and a native build would call the same compiled function
    /// and print identical bytes even with the whole foreign-function layer
    /// broken — the comparison would prove nothing. Built here, matching
    /// output means both backends classified every signature, read every
    /// out-pointer and marshalled every string the same way.
    pub fn describe() -> Result<string> {
        let native: string = self.native_class()?
        let role: string = self.a11y_role()?
        // Escaped, because a text area's text has newlines in it and one
        // widget has to be one line: a dump whose rows depend on the content
        // of a control cannot be read down a column, and a diff of it points
        // at the wrong row.
        let text: string = one_line(self.display_text()?)
        let frame: geometry.Rect = self.frame()?
        var line: string = "{self.kind_value.name()} {native} role={role} \"{text}\" frame={frame.show()}"
        // Only a widget that actually has the state reports it. A container
        // has no enabled flag at all, and printing a default for it would say
        // something false about every container in every expected output.
        match self.is_enabled() {
            ok(enabled) => { if !enabled { line = "{line} disabled" } }
            err(absent) => {}
        }
        match self.is_hidden() {
            ok(hidden) => { if hidden { line = "{line} hidden" } }
            err(absent) => {}
        }
        return ok(line)
    }

    /// Sends this control's action the way a real click does — through the
    /// platform's own target/action dispatch, not by calling a handler
    /// directly. Public API, and how every event test drives the framework.
    ///
    /// Not usable on every control, and the reason is worth knowing: clicking
    /// a combo box opens its menu and runs a modal tracking loop, so this
    /// never returns for one. Use `set_value_as_user` for anything that
    /// carries a value.
    pub fn activate() -> Result<bool> {
        return self.context.dispatch(
            input.UiEvent.of(input.EventKind.activate, self.handle()))
    }

    /// Moves this control's value the way a user would, and raises the event
    /// that follows.
    ///
    /// The setters above change a control **silently**, and that is
    /// deliberate: a program that writes a value should not hear about its own
    /// write, or a render would feed itself and never settle. This is the
    /// other half — what a test uses to drive a control, and what an
    /// application uses to replay events.
    ///
    /// `index` chooses for a control with a list and is the new state for a
    /// check box; `value` is the position of a slider.
    /// How much of this control's frame the platform keeps for itself.
    ///
    /// Four zeros for almost everything. The exceptions are the containers a
    /// platform draws chrome for — a group box's border and title band, a
    /// disclosure's header — whose children live inside a view the platform
    /// positions. What the chrome takes from the caller is *room*: the
    /// children's own coordinates already start at that view's corner, so
    /// nothing here moves them.
    ///
    /// `WidgetLayout.group` asks this once per container when the tree is
    /// built. A caller building frames by hand wants it too, and that is why
    /// it is public.
    pub fn content_inset() -> Result<geometry.EdgeInsets> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.content_inset())
    }

    /// How big the area this control scrolls over is.
    ///
    /// A scroll view's frame is its viewport; this is the thing behind it.
    /// Refused on any other control, which scrolls nothing latte laid out.
    pub fn set_content_size(size: geometry.Size) -> Result<bool> {
        let node: scene.RenderObject = self.node()?
        return node.set_content_size(size)
    }

    pub fn content_size() -> Result<geometry.Size> {
        let node: scene.RenderObject = self.node()?
        node.demand_alive()?; return ok(node.content_size())
    }

    pub fn set_value_as_user(index: int, value: f64) -> Result<bool> {
        return self.context.set_value_as_user(self.handle().raw, index, value)
    }

    /// Types text into this control the way a user would, and raises the
    /// commit event that follows.
    pub fn set_text_as_user(text: string) -> Result<bool> {
        self.set_text_raw(text)?
        let event: input.UiEvent =
            input.UiEvent.of(input.EventKind.text_commit, self.handle())
        event.text = text
        return self.context.dispatch(event)
    }

    // ---- the keyboard ----

    /// Points the keyboard at this control.
    ///
    /// Unlike every other write in latte this one is **not silent**, and the
    /// reason is that focus is not a control's private state: it is one thing
    /// the whole window shares, so a program that moved it has by definition
    /// changed what every other control shows. Whatever had it hears `blur`
    /// and this one hears `focus`.
    ///
    /// Refused as `unsupported` by a control that cannot take the keyboard at
    /// all, and **which controls those are is a real platform difference, not
    /// a gap**: a label refuses everywhere, and a button takes it on a desktop
    /// and refuses on a phone, where there is no Tab key to reach it with and
    /// no focus ring to show it. A program asks rather than assuming.
    pub fn focus() -> Result<bool> {
        return self.context.focus(self.handle().raw)
    }

    /// Whether this is the control its window would type into.
    ///
    /// Not "the control the user is typing into": the second needs the window
    /// to be on screen and in front, which makes it a fact about the desktop
    /// rather than about the program — and unanswerable in a headless run.
    pub fn focused() -> bool {
        match self.node_value {
            some(object) => { return object.focused() }
            none => { return false }
        }
    }

    // ---- driving it the way a user would ----

    /// Clicks, releases or moves the pointer over this control.
    ///
    /// `where` is in the control's own space — the same space `set_frame` uses
    /// — so a caller that knows where a control is knows where to click it.
    ///
    /// **What this proves differs by platform, and the difference is worth
    /// knowing before writing a test around it.** On macOS and Windows it is a
    /// real event through the platform's own dispatch, the same road a mouse
    /// travels. GTK4 and UIKit have no public way to build an event at all, so
    /// there it runs latte's own handler — one step short of the platform.
    pub fn point_as_user(kind: input.EventKind, where: geometry.Point,
                         button: input.PointerButton) -> Result<bool> {
        let event: input.UiEvent = input.UiEvent.of(kind, self.handle())
        event.position = where
        event.index = button.code()
        return self.context.dispatch(event)
    }

    /// A press and a release in the same place, which is what a click is.
    pub fn click_as_user(where: geometry.Point) -> Result<bool> {
        self.point_as_user(input.EventKind.pointer_down, where,
                           input.PointerButton.left)?
        return self.point_as_user(input.EventKind.pointer_up, where,
                                  input.PointerButton.left)
    }

    /// Presses or releases a key at this control.
    ///
    /// The control is given the keyboard first if it does not have it, and the
    /// call is refused the same way `focus` would be if it cannot take it —
    /// because driving a key at a control the keyboard is not pointing at is
    /// testing something a user could not do.
    ///
    /// `typed` is what the key produced, which is empty for every key that
    /// produces nothing and is the whole news for `Key.character`.
    pub fn key_as_user(kind: input.EventKind, key: input.Key, typed: string,
                       modifiers: int) -> Result<bool> {
        let event: input.UiEvent = input.UiEvent.of(kind, self.handle())
        event.index = key.code()
        event.text = typed
        event.modifiers = modifiers
        return self.context.dispatch(event)
    }

    // ---- teardown ----

    /// Drops the render object now, rather than when the last reference goes.
    /// Safe to call twice.
    pub fn release() {
        if self.released { return }
        self.released = true
        match self.node_value {
            some(object) => { self.context.release(object.handle()) }
            none => {}
        }
        self.node_value = none
    }

    fn deinit() {
        self.release()
    }
}
