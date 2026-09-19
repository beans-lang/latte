// A piece of user interface, and its life.
package compose

import latte.geometry

/// CSS's `clamp`: the low bound wins when the two are the wrong way round,
/// which is what the web specifies rather than something guessed here.
fn held(want: f64, low: f64, high: f64) -> f64 {
    var answer: f64 = want
    if answer > high { answer = high }
    if answer < low { answer = low }
    return answer
}

/// Something that describes an interface and can be shown.
///
/// A component is an ordinary Beans class. Its fields are its state, its
/// methods are its behaviour, and `render` says what it should look like right
/// now. It never touches a control: it describes one, and latte works out
/// what to change.
///
/// ```beans
/// @view
/// pub class Counter extends component.Component {
///     @param pub start: int = 0
///     @inject pub log: Journal
///     count: int = 0
///
///     pub fn init() { super.init() }
///     pub override fn on_init() { self.count = self.start }
///
///     pub override fn render(into: component.Builder) {
///         into.open("HStack")
///         into.number("spacing", 8.0)
///             into.open("Label")
///             into.text("{self.count}")
///             into.close()
///             into.open("Button")
///             into.text("More")
///             into.on("click", fn(event: input.UiEvent) { self.bump() })
///             into.close()
///         into.close()
///     }
///
///     fn bump() {
///         self.count = self.count + 1
///         self.request_render()
///     }
/// }
/// ```
///
/// ### The order things happen in
///
/// 1. The component is built — by `new`, or by the container when it has
///    constructor parameters.
/// 2. `@inject` fields are filled and `@param` fields are set.
/// 3. `on_init` runs, once, with everything in place.
/// 4. `on_params_set` runs, now and every time a parameter changes after.
/// 5. `render` runs, and its result reaches the platform.
/// 6. `on_mount` runs, once, after real controls exist.
/// 7. `on_unmount` runs when the component goes away.
///
/// `on_init` is separate from `init` precisely because of step 2: an `init`
/// body cannot see an injected field, since nothing has filled it yet. Putting
/// setup in `init` and wondering why a service is empty is the mistake this
/// ordering removes.
pub abstract class Component {
    /// Set by `request_render`, cleared by the framework once the render has
    /// happened.
    ///
    /// A flag and not a callback into whatever is showing this component. A
    /// back-reference would be a cycle — the mount holds the component, the
    /// component holds the mount — and a cycle whose members hold platform
    /// resources is exactly the shape that never runs `deinit`. The mount
    /// already visits every component it owns; asking is cheaper than being
    /// told, and it cannot leak.
    needs_render: bool = false
    mounted: bool = false
    room: geometry.Size = geometry.Size.zero()
    /// Whether the last render read `room`, and whether one is running — a
    /// read from an event handler is not a dependency.
    room_read: bool = false
    in_render: bool = false
    frame: geometry.Rect = geometry.Rect.of(0.0, 0.0, 0.0, 0.0)
    box_read: bool = false

    pub fn init() {}

    /// Describe what this component should look like, now.
    ///
    /// Called whenever something might have changed. It must not have side
    /// effects: it is called more often than an author expects and, after a
    /// `should_render` says no, not at all.
    pub abstract fn render(into: Builder)

    /// Run once, after injection and parameters, before the first render.
    pub fn on_init() {}

    /// Run after the parameters are set — the first time and every later time
    /// one changes.
    pub fn on_params_set() {}

    /// Run once, after this component's controls exist on the platform.
    ///
    /// `stage` is how a component reaches them: `stage.control(key)` answers
    /// the handle an element with that key became. This is the place to ask a
    /// control something only it knows, or to start something that has to stop
    /// in `on_unmount` — a frame clock, a subscription, a file.
    ///
    /// The stage is made for this call and carries no reference to the mount,
    /// so keeping one is not a cycle; it is simply stale. See `Stage`.
    pub fn on_mount(stage: Stage) {}

    /// Run when this component goes away. Stop here whatever `on_mount`
    /// started: a timer, a subscription, a file. `deinit` is not the place —
    /// a component caught in a reference cycle never runs one.
    pub fn on_unmount() {}

    /// Whether this component needs re-rendering.
    ///
    /// The default is yes, which is always correct and sometimes wasteful.
    /// Override it to compare what this component actually depends on; a
    /// component whose answer is no is not rendered, and the subtree it
    /// produced last time is reused untouched.
    pub fn should_render() -> bool {
        return true
    }

    /// Ask to be rendered again. Call it after changing state that the
    /// interface shows.
    pub fn request_render() {
        self.needs_render = true
    }

    pub fn is_dirty() -> bool {
        return self.needs_render
    }

    /// Framework use: clears the flag once the render it asked for has
    /// happened.
    pub fn settle() {
        self.needs_render = false
    }

    pub fn is_mounted() -> bool {
        return self.mounted
    }

    /// The room the mount lays this component out in — the window's content
    /// size — as of its last render. Zero before the first.
    pub fn viewport() -> geometry.Size {
        // Reading it during a render is what declares the dependency.
        if self.in_render { self.room_read = true }
        return self.room
    }

    /// Framework use: the mount, before every render and on every resize.
    pub fn note_viewport(size: geometry.Size) {
        self.room = size
    }

    /// Whether a resize is a reason to render again. Answered by whether the
    /// last render read `viewport()`; override it to decide otherwise.
    pub fn follows_viewport() -> bool {
        return self.room_read
    }

    /// Framework use: brackets one render. Opening it clears the record, so a
    /// branch that stops reading the room stops following it.
    pub fn note_rendering(state: bool) {
        if state {
            self.room_read = false
            self.box_read = false
        }
        self.in_render = state
    }

    /// The box the solver gave this component's root on the last pass — what
    /// `onLayout` hands a React Native view. Zero before the first.
    ///
    /// The *last* pass, and that is the whole contract: a size read from here
    /// is one pass behind, and the mount lays out again when it moves. A
    /// component whose own content decides its box cannot also be sized from
    /// it, and the mount refuses that rather than laying out for ever.
    pub fn box() -> geometry.Rect {
        if self.in_render { self.box_read = true }
        return self.frame
    }

    /// Framework use: the mount, after every layout pass.
    pub fn note_box(frame: geometry.Rect) {
        self.frame = frame
    }

    /// Whether a box that moved is a reason to render again. Answered by
    /// whether the last render read `box()`.
    pub fn follows_box() -> bool {
        return self.box_read
    }

    /// Run when the box this component was laid out in changed.
    pub fn on_layout(frame: geometry.Rect) {}

    /// A share of this component's own width, held between two points.
    pub fn cw(share: f64, low: f64, high: f64) -> f64 {
        return held(self.box().width * share / 100.0, low, high)
    }

    /// A share of this component's own height, held between two points.
    pub fn ch(share: f64, low: f64, high: f64) -> f64 {
        return held(self.box().height * share / 100.0, low, high)
    }

    /// A share of the window's width, held between two points — the web's
    /// `clamp(low, share vw, high)`. `share` is 0 to 100, like `width_percent`.
    ///
    /// This is the size a control property cannot ask for on its own:
    /// `font_size`, `padding` and the rest leave a render as plain points, so
    /// a share of the room has to be worked out before they go. Reading it
    /// here is what makes the screen follow a resize — see `viewport`.
    pub fn vw(share: f64, low: f64, high: f64) -> f64 {
        return held(self.viewport().width * share / 100.0, low, high)
    }

    /// A share of the window's height, held between two points.
    pub fn vh(share: f64, low: f64, high: f64) -> f64 {
        return held(self.viewport().height * share / 100.0, low, high)
    }

    /// Framework use: records that this component's controls exist.
    pub fn note_mounted(state: bool) {
        self.mounted = state
    }
}
