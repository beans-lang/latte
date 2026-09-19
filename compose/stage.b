// What a component is handed once its controls are real.
package compose

import latte.platform
import latte.input
import latte.controls

/// The platform, as it looks to one component at the moment it is mounted.
///
/// `render` describes controls; it does not have any. By the time `on_mount`
/// runs the controls exist, and this is how a component reaches the ones it
/// asked for — by the `key` it gave them.
///
/// ```
/// pub fn on_mount(stage: component.Stage) {
///     match stage.control("plot") {
///         some(canvas) => { ... }
///         none => {}
///     }
/// }
/// ```
///
/// **Nothing here is a reference to the mount, and that is deliberate.** A
/// component holding its mount would be a cycle — the mount holds the
/// component, the component holds the mount — and a cycle whose members hold
/// platform resources is exactly the shape that never runs `deinit`. So this
/// carries copies: the handles as they were, the router, and the surface. It
/// is made for one call and means nothing after it; a component that keeps one
/// keeps stale handles, which the generation in each one turns into a typed
/// refusal rather than a crash.
pub class Stage {
    priv handles: Map<string, platform.Handle> = {}
    /// The same controls, as the objects a program actually calls methods on.
    ///
    /// A handle alone is not enough to *use* a control: `set_source`,
    /// `set_columns` and `add_page` are on the widget classes, and a handle
    /// cannot be turned into one — a second `Table` around the same handle
    /// would release it twice. So the mount, which walked the real tree to
    /// build a control anyway, keeps what it found.
    ///
    /// This is a reference to a control the tree already owns, held for the
    /// life of one call. It is not a second owner: `ChildHolder` owns the
    /// subtree, and a stage that outlived the call would hold a widget whose
    /// handle is stale — which every method on it answers as a typed refusal.
    priv objects: Map<string, controls.Widget> = {}
    priv router_ref: input.EventRouter = new input.EventRouter()
    priv surface_handle: platform.Handle = platform.Handle.none()

    pub fn init(handles: Map<string, platform.Handle>, objects: Map<string, controls.Widget>,
                router: input.EventRouter, surface: platform.Handle) {
        // Copied rather than moved: a parameter is borrowed, and a stage that
        // took its caller's map would leave the mount without one.
        for key: string in handles.keys() {
            match handles.get(key) {
                some(handle) => { self.handles[key] = handle }
                none => {}
            }
        }
        for key: string in objects.keys() {
            match objects.get(key) {
                some(control) => { self.objects[key] = control }
                none => {}
            }
        }
        self.router_ref = router
        self.surface_handle = surface
    }

    /// The control an element with this key became.
    ///
    /// `none` when nothing in this component's own render carried that key.
    /// Keys are per component, so two components may both use "plot" without
    /// finding each other's.
    pub fn control(key: string) -> Option<platform.Handle> {
        return self.handles.get(key)
    }

    /// The control itself, for the things only the control can be asked.
    ///
    /// **This is what markup cannot carry.** A table's rows, an outline's
    /// nodes, a tab's labels and a page's HTML are *data*, and the calls that
    /// set them are methods on `controls.Table`, `controls.OutlineView`,
    /// `controls.TabView` and `controls.WebView`. So a screen written in `.bx`
    /// describes the shape and fills the data in here:
    ///
    /// ```
    /// pub override fn on_mount(stage: component.Stage) {
    ///     match stage.widget("rows") {
    ///         some(control) => {
    ///             match control as? controls.Table {
    ///                 some(grid) => { grid.set_source(self.rows).or(false) }
    ///                 none => {}
    ///             }
    ///         }
    ///         none => {}
    ///     }
    /// }
    /// ```
    ///
    /// `none` when nothing in this component's own render carried that key —
    /// the same rule `control` follows, for the same reason.
    pub fn widget(key: string) -> Option<controls.Widget> {
        return self.objects.get(key)
    }

    /// Where handlers are registered. The same router the application made,
    /// because there is one per process and an event is dispatched by handle.
    pub fn router() -> input.EventRouter {
        return self.router_ref
    }

    /// The surface these controls are in, for the things that belong to a
    /// window rather than to a control — a frame clock, above all.
    ///
    /// Zero before anything is on screen, which is the case a headless test
    /// hits and a real application does not.
    pub fn surface() -> platform.Handle {
        return self.surface_handle
    }

    /// How many controls this stage knows about, so a component can tell
    /// "no control by that name" from "no controls at all".
    pub fn count() -> int {
        return self.handles.len()
    }
}
