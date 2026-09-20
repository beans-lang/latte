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

/// The whole of what a page drives.
///
/// A Latte WebAssembly module exports a handful of `pub extern "C"` functions
/// and every one of them is a line here: mount, a frame, a pointer, a key,
/// some text, a resize, an accessibility action, unmount. An application's own
/// module writes those exports — the linker only exports names it can see —
/// and each one calls the matching method here, so the sequencing, the error
/// handling and the frame scheduling are written once.
///
/// **It schedules its own frames, and stops.** A call that changes something
/// asks for a frame; a frame that paints nothing and finds no animation
/// running asks for no more. An idle page therefore costs nothing at all,
/// which `tests/canvas/idle.b` checks by counting the frames a still scene
/// asks for.
pub singleton class PageApp {
    scene_value: Option<stage.Scene> = none
    renderer_value: Option<canvaskit.CanvasKitRenderer> = none
    host: Option<BrowserHost> = none
    /// Set when a call failed, and read back out through `latte_last_error`.
    /// A WebAssembly export answers an integer; the reason has to travel
    /// somewhere, and a page that only ever saw -1 could not say why.
    last_error: string = ""
    /// Whether a frame has been asked for and not yet delivered.
    frame_asked: bool = false
    /// Counts what the page did, for the gates: frames delivered, frames that
    /// painted, and frames asked for.
    pub frames: int = 0
    pub painted: int = 0
    pub requests: int = 0

    fn init() {}

    /// Installs the browser host. Called once, before anything else — the
    /// clock, the appearance and the reduce-motion setting all read through
    /// it, and a scene built before it would read the headless answers.
    pub fn boot() -> int {
        self.host = some(PageHost.instance.install())
        return 0
    }

    /// Builds a scene at this size and shows `view`.
    ///
    /// The renderer is CanvasKit's when the page has a surface, and the
    /// measuring one when it has not. Falling back rather than refusing is
    /// deliberate: a page whose WebGL context is gone should still lay out and
    /// still answer an accessibility tree, and the pixels come back when the
    /// context does.
    pub fn mount(view: compose.Component, width: f64, height: f64,
                 scale: f64) -> int {
        self.unmount()
        let drawing: canvaskit.CanvasKitRenderer = new canvaskit.CanvasKitRenderer()
        self.renderer_value = some(drawing)
        var renderer: paint.Renderer = drawing
        if !drawing.ready() {
            // No surface. The scene still runs; `latte_software` says the page
            // is measuring rather than drawing, so a caller is never left
            // guessing why nothing appeared.
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

    /// The page's frame callback.
    ///
    /// Everything that moves moves here: the animation queue advances by the
    /// time since the last frame, the scene settles and draws, and the next
    /// frame is asked for **only if something is still moving**. A scene that
    /// painted nothing and has no animation running stops the clock, which is
    /// the whole of "an idle page stops drawing".
    pub fn frame(seconds: f64) -> int {
        self.frame_asked = false
        self.frames = self.frames + 1
        // Whatever else asked the host for this frame runs first. A
        // `motion.FrameClock` — what a program uses to move something of its
        // own — goes through `platform.Host.request_frame` and would otherwise
        // never tick in a page, because the page's own callback lands here and
        // stops. Two frame mechanisms with one of them wired is the kind of
        // thing that looks like "animation does not work on the web".
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

    /// Seconds since the previous frame. The first one is a sixtieth rather
    /// than whatever the page's clock happened to read, because the first
    /// delta of an animation should not be the time since the page loaded.
    fn delta(seconds: f64) -> f64 {
        if self.last_seconds < 0.0 { self.last_seconds = seconds; return 1.0 / 60.0 }
        var gap: f64 = seconds - self.last_seconds
        self.last_seconds = seconds
        // A tab that was in the background gets one frame's worth rather than
        // the minutes it was away, or every animation finishes the instant it
        // comes back.
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
                // Applied without drawing. A wheel sends a burst of events and
                // the frame that follows draws the sum of them once, which is
                // what keeps a scroll one draw per frame rather than one per
                // event.
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
    /// tree and ask for a frame. Both are needed — a click that moved focus
    /// changed what a screen reader should say as well as what the screen
    /// shows.
    fn after_input(page: stage.Scene) {
        self.publish_semantics(page)
        self.ask_for_frame()
    }

    semantics_revision: int = -1

    /// Hands the page the semantics tree, when it has changed.
    ///
    /// Sent whole rather than as a diff. A tree is a few dozen nodes for a
    /// screen and the page rebuilds its elements from it; a diff would be a
    /// second model of the same thing, kept in step by hand, which is how an
    /// accessibility tree ends up describing the screen from two frames ago.
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

    /// Drops the scene and everything it holds.
    ///
    /// The renderer goes with it, which is what releases every paragraph and
    /// image handle the page issued. A page that mounted and unmounted
    /// repeatedly without this would leak one Skia paragraph per label per
    /// mount, and nothing in Beans would show it — the handles are integers.
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
