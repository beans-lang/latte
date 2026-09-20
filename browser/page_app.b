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
    /// Counts what the page did, for the checks: frames delivered, frames that
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
                platform.Probe.instance.mark_frame()
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
        platform.Probe.instance.enter(platform.PHASE_INPUT)
        defer platform.Probe.instance.leave(platform.PHASE_INPUT)
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
        platform.Probe.instance.enter(platform.PHASE_INPUT)
        defer platform.Probe.instance.leave(platform.PHASE_INPUT)
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
        platform.Probe.instance.enter(platform.PHASE_INPUT)
        defer platform.Probe.instance.leave(platform.PHASE_INPUT)
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
        platform.Probe.instance.enter(platform.PHASE_INPUT)
        defer platform.Probe.instance.leave(platform.PHASE_INPUT)
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
        self.publish_editing(page)
        self.ask_for_frame()
    }

    editing_open: bool = false

    /// Puts the page's editing element under the caret and focuses it, which
    /// is what makes a real keystroke reach Beans at all.
    fn publish_editing(page: stage.Scene) {
        match self.host {
            none => {}
            some(page_host) => {
                if !page_host.can(platform.Capability.text_input) { return }
                match page.editing_spot() {
                    some(spot) => {
                        self.editing_open = true
                        page_host.text_input(true, spot.text, spot.anchor, spot.caret,
                                             spot.rect.x, spot.rect.y,
                                             spot.rect.width, spot.rect.height)
                    }
                    none => {
                        // Only on the way down. Sending it every frame would
                        // blur the element between every keystroke.
                        if self.editing_open {
                            self.editing_open = false
                            page_host.text_input(false, "", 0, 0, 0.0, 0.0, 0.0, 0.0)
                        }
                    }
                }
            }
        }
    }

    semantics_revision: int = -1
    semantics_focus: u64 = 0

    /// Hands the page the semantics tree when it changed, whole rather than as
    /// a diff: a diff is a second model to keep in step by hand.
    ///
    /// "When it changed" is the scene's own semantics revision, which every
    /// frame, bounds and label change already moves. An idle frame therefore
    /// publishes nothing at all, and a page that is only animating a colour
    /// does not rebuild its accessibility tree sixty times a second.
    fn publish_semantics(page: stage.Scene) {
        platform.Probe.instance.enter(platform.PHASE_A11Y)
        defer platform.Probe.instance.leave(platform.PHASE_A11Y)
        match self.host {
            none => {}
            some(page_host) => {
                if !page_host.can(platform.Capability.accessibility) { return }
                var focused: u64 = 0
                match page.focused_object() { some(node) => { focused = node.handle() } none => {} }
                let revision: int = page.semantics_version()
                if revision == self.semantics_revision && focused == self.semantics_focus { return }
                match page_host.semantics_begin() {
                    err(_) => { return }
                    ok(_) => {}
                }
                self.send_nodes(page, page_host, focused)
                page_host.semantics_end()
                self.semantics_revision = revision
                self.semantics_focus = focused
            }
        }
    }

    /// What one node was last published as, so a node that only moved can be
    /// sent as four numbers instead of three strings.
    said: Map<u64, SpokenNode> = {}
    said_round: int = 0

    fn send_nodes(page: stage.Scene, page_host: BrowserHost, focused: u64) {
        var published: int = 0
        let tree: List<scene.SemanticsNode> = page.semantics()
        platform.Probe.instance.enter(platform.PHASE_A11Y_PUBLISH)
        self.said_round = self.said_round + 1
        for node: scene.SemanticsNode in tree {
            published = published + 1
            let box: geometry.Rect = node.bounds()
            let id: u64 = node.id()
            var spoken: bool = false
            match self.said.get(id) {
                some(before) => {
                    if before.same(node) {
                        before.round = self.said_round
                        page_host.semantics_move(id, box.x, box.y, box.width, box.height,
                                                 id == focused)
                        spoken = true
                    }
                }
                none => {}
            }
            if !spoken {
                page_host.semantics_node(id, node.role(), node.label(), node.value(),
                                         box.x, box.y, box.width, box.height,
                                         node.enabled(), id == focused)
                if node.in_grid() {
                    page_host.semantics_grid(id, node.row(), node.column(),
                                             node.rows(), node.columns())
                }
                self.said[id] = new SpokenNode(node, self.said_round)
            }
        }
        // Only when it grew: a tree that shed nodes has to give their records
        // back, and one that did not has nothing to walk.
        if self.said.len() > published { self.forget_unsaid() }
        platform.Probe.instance.leave(platform.PHASE_A11Y_PUBLISH)
        platform.Probe.instance.note(platform.TALLY_A11Y_NODES, published)
    }

    fn forget_unsaid() {
        for id: u64 in self.said.keys() {
            match self.said.get(id) {
                some(before) => { if before.round != self.said_round { self.said.remove(id) } }
                none => {}
            }
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
        self.semantics_revision = -1
        self.semantics_focus = 0
        self.editing_open = false
        self.said = {}
        self.said_round = 0
        return 0
    }
}

/// The words one accessibility node was last published with.
class SpokenNode {
    role: string
    label: string
    value: string
    enabled: bool
    pub round: int
    row: int
    column: int
    rows: int
    columns: int
    pub fn init(node: scene.SemanticsNode, round: int) {
        self.role = node.role(); self.label = node.label(); self.value = node.value()
        self.enabled = node.enabled(); self.round = round
        self.row = node.row(); self.column = node.column()
        self.rows = node.rows(); self.columns = node.columns()
    }
    /// Whether the page already has everything but this node's box.
    pub fn same(node: scene.SemanticsNode) -> bool {
        return self.enabled == node.enabled() && self.role == node.role() &&
               self.label == node.label() && self.value == node.value() &&
               self.row == node.row() && self.column == node.column() &&
               self.rows == node.rows() && self.columns == node.columns()
    }
}
