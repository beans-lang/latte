// Where the layout engine meets real widgets.
package controls

import latte.geometry
import latte.layout

/// Ties a layout tree to the widgets it describes.
///
/// `latte.layout` is pure arithmetic and knows nothing about native
/// controls: it asks an integer key how big it wants to be and writes a
/// rectangle next to that key. This class is the other half — it hands out the
/// keys, answers the measurement question by asking the real control, and
/// writes the finished frames back onto the widgets.
///
/// Keeping it here rather than inside the engine is what lets the engine's
/// entire test suite run on a machine with no window server. Everything that
/// touches a platform is in this file; everything that computes a position is
/// in `latte.layout`, and the two meet only through `layout.Measure`.
///
/// ```
/// var sheet: controls.WidgetLayout = new controls.WidgetLayout()
/// var body: layout.StackLayout = layout.StackLayout.column(12.0)
/// body.set_padding(geometry.EdgeInsets.all(24.0))
///
/// var root: layout.LayoutNode = sheet.group("root", container, body)?
/// root.add(sheet.leaf("heading", heading))
/// root.add(sheet.leaf("buy", button))
///
/// var solver: layout.Solver = new layout.Solver(sheet)
/// solver.solve(root, window.content_frame()?)?
/// sheet.apply(root)?
/// ```
pub class WidgetLayout implements layout.Measure {
    controls: Map<int, Widget>
    next: int = 0

    /// What the platform has already been told, by full handle.
    ///
    /// **A layout pass is mostly a pass that changes nothing.** A screen of
    /// eighty controls re-laid out after a click moves two of them; the other
    /// seventy-eight are solved to the frame they already have. Writing those
    /// back is not free on any platform — on AppKit a container's `setFrame:`
    /// re-lays its own subviews out and can re-measure text to do it — and
    /// asking a container for its chrome again is a second crossing for an
    /// answer that changes only when the container's own title does.
    ///
    /// These two maps are what makes a pass that changes nothing cost nothing.
    /// They survive `reset`, which is what happens between passes; `forget`
    /// takes one control's rows out when it is written to or goes away.
    ///
    /// **What they are not.** `frames` is what this sheet last *asked for*,
    /// not what the control is at. Two things move a control without asking:
    /// a surface's root view, which the platform keeps the size of the
    /// surface — and which is never in a sheet, because a mount's tree starts
    /// at the root's child — and the panes of a split or tab view, whose
    /// frames the platform owns and whose writes `ctd_view_set_frame` already
    /// declines. Anything else that moves a control behind latte's back is
    /// a program calling `Widget.set_frame` on a control a mount is laying
    /// out, which is two things owning one frame.
    frames: Map<u64, geometry.Rect> = {}
    chrome: Map<u64, geometry.EdgeInsets> = {}
    /// What each scrolling control was last told it scrolls over.
    scrolled: Map<u64, geometry.Size> = {}
    /// What each control was last told about being hidden; absent is shown.
    hidden: Map<u64, bool> = {}

    /// How many controls the last `apply` really moved, and how many it left
    /// alone. A test's cheapest proof that a pass that changed nothing wrote
    /// nothing.
    wrote: int = 0
    kept: int = 0
    /// How many containers this pass had to ask the platform about, rather
    /// than answering from `chrome`.
    asked: int = 0
    /// How many nodes the last `apply` found with children past their box.
    spilled: int = 0

    pub fn init() {
        self.controls = {}
    }

    /// Empties the key space for another pass, keeping what the platform has
    /// already been told.
    ///
    /// A layout pass builds its own tree and hands out its own keys, so the
    /// sheet starts each one empty — but the two things worth remembering are
    /// about *controls*, which outlive any one pass. Rebuilding the whole
    /// sheet each time, which is what this replaced, threw them away with it.
    pub fn reset() {
        self.controls = {}
        self.next = 0
        self.wrote = 0
        self.kept = 0
        self.asked = 0
    }

    /// Drops what the platform was told about one control.
    ///
    /// Called when a control is written to — a group box retitled is a group
    /// box with a different border to leave room for — and when one goes away,
    /// so a recycled handle never inherits the last control's numbers.
    pub fn forget(handle: u64) {
        self.frames.remove(handle)
        self.chrome.remove(handle)
        self.scrolled.remove(handle)
        self.hidden.remove(handle)
    }

    /// Everything, for a mount that is closing or a system change that moves
    /// every control at once.
    pub fn forget_all() {
        self.frames = {}
        self.chrome = {}
        self.scrolled = {}
        self.hidden = {}
    }

    /// How many widgets this sheet is tracking.
    /// The frame this sheet last put a control at, or `none` for one it has
    /// never placed. What a mount hands a component as its own box.
    pub fn frame_of(handle: u64) -> Option<geometry.Rect> {
        return self.frames.get(handle)
    }

    pub fn count() -> int {
        return self.controls.len()
    }

    /// How many controls the last `apply` wrote a frame to.
    pub fn written() -> int {
        return self.wrote
    }

    /// How many it found already where the layout wanted them.
    pub fn unchanged() -> int {
        return self.kept
    }

    /// How many containers this pass asked the platform about. Zero on a
    /// second pass over an unchanged tree is the whole point of `chrome`.
    pub fn chrome_asked() -> int {
        return self.asked
    }

    /// How many runs overflowed on the last `apply`. Zero is a screen that fits.
    pub fn overflowing() -> int {
        return self.spilled
    }

    /// A node for a control with no children.
    ///
    /// Registers `control` so the solver can ask it how big it wants to be —
    /// the one question about a native control that latte cannot answer from
    /// arithmetic, because it depends on the platform's fonts.
    pub fn leaf(name: string, control: Widget) -> layout.LayoutNode {
        return layout.LayoutNode.leaf(name, self.register(control))
    }

    /// A node for a control that holds other widgets.
    ///
    /// The container is registered too, so its frame is applied, but it is
    /// never measured: a group's size comes from `arranger` and the children
    /// inside it, and asking the platform as well would let a native minimum
    /// override a layout the application asked for.
    ///
    /// Refused where the control cannot say what it keeps: `ctd_view_content_inset`
    /// answers only `stale_handle` or `wrong_widget`, and both name a bug.
    pub fn group(name: string, control: Widget,
                 arranger: layout.Layout) -> Result<layout.LayoutNode> {
        var chosen: layout.Layout = arranger
        match control as? SplitView {
            some(split) => {
                let split_layout: layout.SplitLayout = split.split_layout()?
                split_layout.set_padding(arranger.padding())
                chosen = split_layout
            }
            none => {}
        }
        var node: layout.LayoutNode = layout.LayoutNode.group(name, chosen)
        node.key = self.register(control)
        // What the platform keeps for itself: a group box's border and title
        // band, a disclosure's header. Asked here, once per tree, rather than
        // written into the caller's padding — before this, a screen with a
        // group box on it added twelve points by eye and was wrong on the
        // other three platforms, whose borders are not twelve points.
        //
        // The refusal is not swallowed. No host answers `unsupported` here, so
        // the only answers are a released widget and a handle that is no view.
        //
        // A zero taken for either is a container laid out as if it drew no
        // chrome, and a released one nothing else in the pass need ever notice.
        //
        // Asked once per control rather than once per pass — see `chrome`.
        let slot: u64 = control.handle().raw
        match self.chrome.get(slot) {
            some(known) => { node.chrome = known }
            none => {
                self.asked = self.asked + 1
                let inset: geometry.EdgeInsets = control.content_inset()?
                node.chrome = inset
                self.chrome[slot] = inset
            }
        }
        // Panes live directly under their render object. SplitLayout already
        // subtracts the six-point divider, so chrome must not remove it twice.
        match control as? SplitView {
            some(split) => { node.chrome = geometry.EdgeInsets.zero() }
            none => {}
        }
        return ok(node)
    }

    /// A node with no control behind it, for grouping that exists only in the
    /// layout. Nothing is created on the platform, so a row of buttons inside
    /// a column costs one native view, not two.
    pub fn spacer(name: string, arranger: layout.Layout) -> layout.LayoutNode {
        return layout.LayoutNode.group(name, arranger)
    }

    fn register(control: Widget) -> int {
        let key: int = self.next
        self.next = key + 1
        self.controls.set(key, control)
        return key
    }

    /// Asks the control itself. This is `layout.Measure`.
    ///
    /// A key with no control measures as zero rather than failing: a node may
    /// legitimately stand for nothing, and the caller who wanted a control
    /// there sees a zero-sized frame, which is visible. Refusing here would
    /// fail the whole solve for one missing entry.
    pub fn measure(key: int, available: geometry.Size) -> Result<geometry.Size> {
        match self.controls.get(key) {
            some(control) => { return control.measure(available) }
            none => { return ok(geometry.Size.zero()) }
        }
    }

    /// Writes every solved frame onto the control it belongs to, and answers
    /// how many controls moved.
    ///
    /// Applied top down, parents before children, because a platform that
    /// clips to its parent's bounds would otherwise place a child against a
    /// frame its parent has not taken yet.
    pub fn apply(root: layout.LayoutNode) -> Result<int> {
        self.wrote = 0
        self.kept = 0
        self.spilled = 0
        return self.apply_at(root, 0.0, 0.0)
    }

    /// The recursive half, carrying the offset contributed by layout-only
    /// ancestors.
    ///
    /// The two trees do not have the same shape, and this is where that is
    /// reconciled. A node's frame is relative to its parent *node*, but a
    /// control's frame is relative to its parent *control* — and `spacer`
    /// deliberately creates nodes with no control behind them, so a row of
    /// buttons can be grouped in the layout without costing a native view.
    /// Every such node sits between a control and its children, and its origin
    /// has to be added to theirs or the whole group lands at the wrong place.
    ///
    /// A node that does have a control resets the offset to zero: the control
    /// is a real view, and its children are positioned inside it.
    fn apply_at(node: layout.LayoutNode, dx: f64, dy: f64) -> Result<int> {
        var moved: int = 0
        if node.overflow > 0.0 { self.spilled = self.spilled + 1 }
        var next_x: f64 = dx + node.frame().x
        var next_y: f64 = dy + node.frame().y
        match self.controls.get(node.key) {
            some(control) => {
                let slot: u64 = control.handle().raw
                // A culled control is hidden, not placed; what is under it
                // sits inside a hidden view and was never laid out.
                if node.culled {
                    self.hide(control, slot, true)?
                    return ok(moved)
                }
                self.hide(control, slot, false)?
                let box: geometry.Rect = node.frame()
                let want: geometry.Rect = geometry.Rect.of(box.x + dx, box.y + dy,
                                                           box.width, box.height)
                if self.told(slot, want) {
                    self.kept = self.kept + 1
                } else {
                    control.set_frame(want)?
                    self.frames[slot] = want
                    self.wrote = self.wrote + 1
                    moved = moved + 1
                }
                // Before the children, because a host may size the thing they
                // live in — Win32 moves the content window this call resizes.
                self.scroll_to(control, slot, node.content)?
                next_x = 0.0
                next_y = 0.0
            }
            none => {
                // A layout-only group that was culled placed none of its children.
                if node.culled { return ok(moved) }
            }
        }
        for index: int in 0..node.count() {
            moved = moved + self.apply_at(node.at(index), next_x, next_y)?
        }
        return ok(moved)
    }

    /// Tells a control whether it is hidden, once per change of answer. A
    /// control never told is taken as shown, so a fresh one costs no write.
    fn hide(control: Widget, slot: u64, state: bool) -> Result<bool> {
        var was: bool = false
        match self.hidden.get(slot) {
            some(told) => { was = told }
            none => {}
        }
        if was == state { return ok(false) }
        control.set_hidden(state)?
        self.hidden[slot] = state
        return ok(true)
    }

    /// Tells a scrolling control how big the area behind its viewport is.
    ///
    /// Only `ScrollLayout` leaves a non-zero `content`, so this is a no-op for
    /// every other node rather than a call every control has to refuse.
    fn scroll_to(control: Widget, slot: u64, size: geometry.Size) -> Result<bool> {
        if size.width <= 0.0 && size.height <= 0.0 { return ok(false) }
        match self.scrolled.get(slot) {
            some(had) => {
                if had.width == size.width && had.height == size.height {
                    return ok(false)
                }
            }
            none => {}
        }
        control.set_content_size(size)?
        self.scrolled[slot] = size
        return ok(true)
    }

    /// Whether this sheet has already asked for exactly this frame.
    ///
    /// Compared field by field rather than through a derived equality, because
    /// a frame is four `f64` and what matters is that all four are the same
    /// number — not that two values look alike.
    fn told(handle: u64, want: geometry.Rect) -> bool {
        match self.frames.get(handle) {
            none => { return false }
            some(had) => {
                return had.x == want.x && had.y == want.y &&
                       had.width == want.width && had.height == want.height
            }
        }
    }
}
