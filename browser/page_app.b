// One scene in a page, driven from JavaScript.
package browser

import latte.canvaskit
import latte.compose
import latte.geometry
import latte.input
import latte.paint
import latte.platform
import latte.scene
import latte.stage
import latte.headless

/// The whole of what a page drives: every `pub extern "C"` export is a line
/// here. It asks for frames and stops; `tests/canvas/idle.b` counts them.
pub singleton class PageApp {
    scene_value: Option<stage.Scene> = none
    renderer_value: Option<canvaskit.CanvasKitRenderer> = none
    host: Option<BrowserHost> = none
    /// Set when a call failed, and read back through `latte_last_error`: an
    /// export answers an integer, so the reason has to travel somewhere.
    last_error: string = ""
    /// Whether a frame has been asked for and not yet delivered.
    frame_asked: bool = false
    /// Counts what the page did, for the gates: frames delivered, frames that
    /// painted, and frames asked for.
    pub frames: int = 0
    pub painted: int = 0
    pub requests: int = 0

    fn init() {}

    /// Installs the browser host, before anything else: a scene built first
    /// would read the headless clock and appearance.
    pub fn boot() -> int {
        self.host = some(PageHost.instance.install())
        return 0
    }

    /// Builds a scene at this size and shows `view`. With no surface it
    /// measures instead of refusing, so layout and semantics still answer.
    pub fn mount(view: compose.Component, width: f64, height: f64,
                 scale: f64) -> int {
        self.unmount()
        let drawing: canvaskit.CanvasKitRenderer = new canvaskit.CanvasKitRenderer()
        self.renderer_value = some(drawing)
        var renderer: paint.Renderer = drawing
        if !drawing.ready() {
            // No surface: the scene still runs, and `latte_software` says the
            // page is measuring rather than drawing.
            renderer = new headless.MetricRenderer()
        }
        let page: stage.Scene = new stage.Scene(renderer,
                                                geometry.Size.of(width, height))
        self.scene_value = some(page)
        match page.resize(geometry.Size.of(width, height), scale) {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(_) => {}
        }
        match page.show(view) {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(_) => {}
        }
        self.ask_for_frame()
        return 0
    }

    pub fn scene() -> Option<stage.Scene> { return self.scene_value }

    /// Whether the page is drawing on the CPU. True with no surface at all,
    /// which is the honest answer: nothing is reaching the GPU.
    pub fn software() -> bool {
        match self.renderer_value {
            some(drawing) => { return drawing.software() || !drawing.ready() }
            none => { return true }
        }
    }

    pub fn error() -> string { return self.last_error }

    fn fail(message: string) {
        self.last_error = message
    }

    fn with_scene(attempt: string) -> Result<stage.Scene> {
        match self.scene_value {
            some(page) => { return ok(page) }
            none => {
                return err("could not {attempt}: nothing is mounted", "wrong_moment")
            }
        }
    }

    /// Asks the page for the next frame, unless one is already coming.
    fn ask_for_frame() {
        if self.frame_asked { return }
        match self.host {
            none => {}
            some(page_host) => {
                match page_host.request_frame(fn(seconds: f64) {}) {
                    ok(_) => { self.frame_asked = true; self.requests = self.requests + 1 }
                    err(problem) => { self.fail(problem.msg) }
                }
            }
        }
    }

    /// The page's frame callback, where everything that moves moves. The next
    /// frame is asked for only if something is still moving.
    pub fn frame(seconds: f64) -> int {
        self.frame_asked = false
        self.frames = self.frames + 1
        // Whatever else asked the host for this frame runs first: a program's
        // own `motion.FrameClock` would otherwise never tick in a page.
        PageHost.instance.deliver_frame(seconds)
        match self.with_scene("draw a frame") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                var moved: bool = false
                if page.has_active_animations() {
                    match page.advance(self.delta(seconds)) {
                        ok(changed) => { moved = changed }
                        err(problem) => { self.fail(problem.msg); return -1 }
                    }
                } else {
                    match page.refresh() {
                        ok(changed) => { moved = changed }
                        err(problem) => { self.fail(problem.msg); return -1 }
                    }
                }
                if moved { self.painted = self.painted + 1 }
                self.publish_semantics(page)
                if page.has_active_animations() { self.ask_for_frame() }
                return if moved { 1 } else { 0 }
            }
        }
    }

    last_seconds: f64 = -1.0

    /// Seconds since the previous frame. The first is a sixtieth: an
    /// animation's first delta should not be the time since the page loaded.
    fn delta(seconds: f64) -> f64 {
        if self.last_seconds < 0.0 { self.last_seconds = seconds; return 1.0 / 60.0 }
        var gap: f64 = seconds - self.last_seconds
        self.last_seconds = seconds
        // A backgrounded tab gets one frame's worth, not the minutes it was
        // away, or every animation finishes the instant it comes back.
        if gap <= 0.0 || gap > 0.25 { gap = 1.0 / 60.0 }
        return gap
    }

    // ---- input ----

    pub fn pointer(kind: int, x: f64, y: f64, button: int, clicks: int,
                   modifiers: int) -> int {
        match self.with_scene("send a pointer event") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                match page.pointer(input.EventKind.of(kind), geometry.Point.at(x, y),
                                   button, clicks, modifiers) {
                    err(problem) => { self.fail(problem.msg); return -1 }
                    ok(_) => { self.after_input(page); return 0 }
                }
            }
        }
    }

    /// A key press or release. Text is `text_input`, and a text kind arriving
    /// here is refused by the input manager rather than quietly mis-read.
    pub fn key(kind: int, key: int, text: string, modifiers: int) -> int {
        match self.with_scene("send a key event") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                match page.key(input.EventKind.of(kind), input.Key.of(key), text, modifiers) {
                    err(problem) => { self.fail(problem.msg); return -1 }
                    ok(_) => { self.after_input(page); return 0 }
                }
            }
        }
    }

    pub fn scroll(x: f64, y: f64, dx: f64, dy: f64) -> int {
        match self.with_scene("scroll") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                // Applied without drawing: a wheel sends a burst, and the next
                // frame draws the sum once rather than one draw per event.
                match page.apply_scroll(geometry.Point.at(x, y), dx, dy) {
                    err(problem) => { self.fail(problem.msg); return -1 }
                    ok(_) => { self.ask_for_frame(); return 0 }
                }
            }
        }
    }

    pub fn text_input(kind: int, text: string, anchor: int, caret: int) -> int {
        match self.with_scene("send text") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                match page.text_input(input.EventKind.of(kind), text, anchor, caret) {
                    err(problem) => { self.fail(problem.msg); return -1 }
                    ok(_) => { self.after_input(page); return 0 }
                }
            }
        }
    }

    pub fn resize(width: f64, height: f64, scale: f64) -> int {
        match self.with_scene("resize") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                match page.resize(geometry.Size.of(width, height), scale) {
                    err(problem) => { self.fail(problem.msg); return -1 }
                    ok(_) => { self.ask_for_frame(); return 0 }
                }
            }
        }
    }

    pub fn semantics_action(handle: u64, action: int) -> int {
        match self.with_scene("run an accessibility action") {
            err(problem) => { self.fail(problem.msg); return -1 }
            ok(page) => {
                match stage.SemanticsAction.of(action) {
                    none => {
                        self.fail("could not run an accessibility action: {action} is not one")
                        return -1
                    }
                    some(what) => {
                        match page.semantics_action(handle, what) {
                            err(problem) => { self.fail(problem.msg); return -1 }
                            ok(_) => { self.after_input(page); return 0 }
                        }
                    }
                }
            }
        }
    }

    /// After anything that could have changed the scene: publish the semantics
    /// tree and ask for a frame. A click that moved focus changed both.
    fn after_input(page: stage.Scene) {
        self.publish_semantics(page)
        self.ask_for_frame()
    }

    semantics_revision: int = -1

    /// Hands the page the semantics tree when it changed, whole rather than as
    /// a diff: a diff is a second model to keep in step by hand.
    fn publish_semantics(page: stage.Scene) {
        match self.host {
            none => {}
            some(page_host) => {
                if !page_host.can(platform.Capability.accessibility) { return }
                match page_host.semantics_begin() {
                    err(_) => { return }
                    ok(_) => {}
                }
                match page.focused_object() {
                    some(focused) => { self.send_nodes(page, page_host, focused.handle()) }
                    none => { self.send_nodes(page, page_host, 0) }
                }
                page_host.semantics_end()
            }
        }
    }

    fn send_nodes(page: stage.Scene, page_host: BrowserHost, focused: u64) {
        for node: scene.SemanticsNode in page.semantics() {
            let box: geometry.Rect = node.bounds()
            page_host.semantics_node(node.id(), node.role(), node.label(), node.value(),
                                     box.x, box.y, box.width, box.height,
                                     node.enabled(), node.id() == focused)
        }
    }

    // ---- teardown ----

    /// Drops the scene and everything it holds, the renderer with it — which
    /// is what releases every paragraph and image handle the page issued.
    pub fn unmount() -> int {
        match self.scene_value {
            some(page) => { page.close() }
            none => {}
        }
        self.scene_value = none
        self.renderer_value = none
        self.frame_asked = false
        self.last_seconds = -1.0
        return 0
    }
}
