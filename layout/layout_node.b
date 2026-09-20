// One box in the layout tree.
package layout

import latte.geometry

/// A node the solver sizes and positions.
///
/// The layout tree is deliberately **not** the widget tree. It holds no
/// handles, makes no host calls and knows nothing about AppKit, so the whole
/// engine compiles and runs on a machine with no window server. A node names
/// the widget it stands for with an integer `key`, and whoever owns the
/// widgets turns keys back into controls after the solve.
///
/// That separation is what makes the layout expected outputs meaningful: they run on
/// every CI runner, under both backends, with no display and no foreign call,
/// so a frame that comes out wrong is a solver bug and never a font.
pub class LayoutNode {
    /// The name expected outputs and debug dumps print. Not an identifier — two
    /// siblings may share one, and the engine never looks at it.
    pub name: string = ""

    /// Which widget this node stands for, or -1 for a box that exists only to
    /// group others. `Measure` is asked about this key, and the caller uses it
    /// to find the control a computed frame belongs to.
    pub key: int = -1

    /// What this node asks of its parent. Assignable, because building a tree
    /// otherwise needs a constructor argument for every field on it.
    pub spec: LayoutSpec = LayoutSpec {}

    /// How much of this node's box the platform keeps for itself: a group
    /// box's border and title band, a disclosure's header, a tab strip.
    ///
    /// It is not padding, and the difference is the whole reason it is a
    /// second field. Padding moves the children; this does not. The children
    /// of such a container live inside a view the *platform* positions, so
    /// their coordinates already start at that view's corner — what the chrome
    /// takes away is room, and nothing else.
    ///
    /// Filled by `controls.WidgetLayout` from `ctd_view_content_inset`, and
    /// left at zero by anything that builds a tree without controls, which is
    /// what keeps this package free of host calls and its expected outputs runnable on
    /// a machine with no display.
    pub chrome: geometry.EdgeInsets = geometry.EdgeInsets {}

    /// How big the area behind this node is, when that is not its own frame.
    ///
    /// Only a scrolling container has one, and only `ScrollLayout` writes it.
    /// Zero everywhere else, which is how a caller tells "nothing to scroll"
    /// from "a content size of nothing".
    pub content: geometry.Size = geometry.Size.zero()

    /// How far this node's children ran past its content box on the last
    /// arrange, or 0. Written by the arranger; the dump prints it.
    pub overflow: f64 = 0.0

    /// Left out by the last arrange, by its spec or by the room: a zero frame,
    /// and nothing under it was placed.
    pub culled: bool = false

    arranger: Layout
    contents: List<LayoutNode> = []
    box: geometry.Rect = geometry.Rect.zero()

    /// The last answer `measure` gave, and the question it answered.
    ///
    /// **A two-pass layout asks the same node the same question more than
    /// once, by construction.** A run measures every child to find out how big
    /// it wants to be, then arranges them — and arranging a child means
    /// placing it, which means the child measures *its* children all over
    /// again. The deeper the tree the more of it repeats: a leaf five levels
    /// down was measured ten times for one solve, and every one of those
    /// reached the platform.
    ///
    /// Within one pass the answer cannot change. Nothing writes to a control
    /// while a solve is running, and a node's spec, chrome, arranger and
    /// children are all fixed for the duration — so the same constraint has
    /// the same answer, and this remembers it.
    ///
    /// Across passes it can change, which is why the solver clears the whole
    /// tree before every solve rather than trusting anything to notice. See
    /// `forget_measures`.
    measured_for: Constraint = Constraint {}
    measured: geometry.Size = geometry.Size.zero()
    has_measure: bool = false

    pub fn init(name: string, arranger: Layout) {
        self.name = name
        self.arranger = arranger
    }

    /// A node that measures itself and holds nothing.
    pub static fn leaf(name: string, key: int) -> LayoutNode {
        var node: LayoutNode = new LayoutNode(name, new LeafLayout())
        node.key = key
        return node
    }

    /// A node that arranges children with `arranger`.
    pub static fn group(name: string, arranger: Layout) -> LayoutNode {
        return new LayoutNode(name, arranger)
    }

    pub fn layout() -> Layout {
        return self.arranger
    }

    // ---- tree ----

    /// Appends `child` and answers it, so a tree can be built as an
    /// expression instead of as a sequence of statements.
    pub fn add(child: LayoutNode) -> LayoutNode {
        self.contents.push(child)
        return child
    }

    pub fn count() -> int {
        return self.contents.len()
    }

    pub fn child_at(index: int) -> Option<LayoutNode> {
        if index < 0 || index >= self.contents.len() {
            return none
        }
        return some(self.contents[index])
    }

    /// A copy of the child list, so a caller walking the tree cannot mutate it
    /// underneath the node. The nodes themselves are shared: a frame written
    /// through a walked list lands on the real child.
    ///
    /// **Not what a layout pass uses.** A copy is one allocation, and a solve
    /// walks every node between four and a dozen times — once per ancestor
    /// that measures it, once to arrange it, once to mirror and once to snap.
    /// A profile of a screen re-laying itself out had `beans_list_new` at the
    /// top of it, and this was where they came from. Everything inside
    /// `latte.layout` walks by index through `at` instead; this stays for a
    /// caller outside the engine that wants a list it can keep.
    pub fn children() -> List<LayoutNode> {
        var out: List<LayoutNode> = []
        for child: LayoutNode in self.contents {
            out.push(child)
        }
        return move out
    }

    /// The child at `index`, without copying anything.
    ///
    /// Out of range is a bug in the caller rather than a case to answer: every
    /// caller here walks `0 .. count()`, and an `Option` at each step would be
    /// the allocation this exists to avoid.
    pub fn at(index: int) -> LayoutNode {
        return self.contents[index]
    }

    // ---- results ----

    /// Where this node ended up, relative to its parent's frame origin.
    pub fn frame() -> geometry.Rect {
        return self.box
    }

    pub fn set_frame(frame: geometry.Rect) {
        self.box = frame
    }

    // ---- the two passes ----

    /// How big this node wants to be inside `limit`.
    ///
    /// The node's own `spec` bounds are folded in first, so a child that asks
    /// for a minimum width gets one even when its layout would have measured
    /// smaller, and the final answer is clamped to what the parent offered.
    pub fn measure(limit: Constraint, ruler: Measure) -> Result<geometry.Size> {
        if self.has_measure && self.measured_for.same_as(limit) {
            return ok(self.measured)
        }
        let mine: Constraint = self.spec.constrain(limit)
        let inside: Constraint = mine.deflate(self.chrome)
        let wanted: geometry.Size = self.arranger.measure(self, inside, ruler)?
        var whole: geometry.Size = geometry.Size.of(
            wanted.width + self.chrome.horizontal(),
            wanted.height + self.chrome.vertical())
        if self.spec.aspect_ratio > 0.0 {
            whole = self.spec.shaped(whole, mine)
        }
        let answer: geometry.Size = mine.clamp(whole)
        // Only a whole answer is remembered. A measure that failed part-way
        // down left nothing to remember, and remembering the constraint alone
        // would answer the next caller with a size nobody computed.
        self.measured_for = limit
        self.measured = answer
        self.has_measure = true
        return ok(answer)
    }

    /// Forgets every remembered measurement in this subtree.
    ///
    /// Called by the solver at the start of every pass, and by nothing else.
    /// A cache that tried to notice what had changed would be a second
    /// reconciler — the thing this engine deliberately does not have — so it
    /// is thrown away wholesale instead, which is one walk of a tree of plain
    /// objects with no platform call anywhere in it.
    pub fn forget_measures() {
        self.has_measure = false
        for index: int in 0..self.contents.len() {
            self.contents[index].forget_measures()
        }
    }

    /// Puts this node at `frame` and lays its children out inside it.
    ///
    /// This is the only place a frame is written, which is why a layout
    /// subclass never touches `box` directly: "who moved this node" has one
    /// answer, and a subclass that placed nodes itself could place one twice.
    /// Leaves this node out of the pass: no frame, and no children placed.
    pub fn cull() {
        self.culled = true
        self.box = geometry.Rect.zero()
        self.overflow = 0.0
    }

    pub fn place(frame: geometry.Rect, ruler: Measure) -> Result<bool> {
        self.box = frame
        self.overflow = 0.0
        self.culled = false
        // The chrome comes off the size and not off the origin — see the
        // field's own note. A child of a group box that starts at zero starts
        // at the corner of the box's *content view*, which AppKit has already
        // moved inside the border; offsetting it here as well would move it
        // twice.
        let room: geometry.Rect = geometry.Rect.of(
            0.0, 0.0,
            widen(frame.width - self.chrome.horizontal()),
            widen(frame.height - self.chrome.vertical()))
        let content: geometry.Rect = self.arranger.padding().deflate(room)
        return self.arranger.arrange(self, content, ruler)
    }
}

/// The children of `node` that take part in a box `room` wide, in order.
/// The rest are culled here, so every arranger leaves them out the same way.
fn members_of(node: LayoutNode, room: f64) -> List<int> {
    var out: List<int> = []
    for index: int in 0..node.count() {
        let child: LayoutNode = node.at(index)
        if child.spec.shown_in(room) {
            out.push(index)
        } else {
            child.cull()
        }
    }
    return move out
}

/// How many children of `node` take part in a box `room` wide.
fn shown_count(node: LayoutNode, room: f64) -> int {
    var count: int = 0
    for index: int in 0..node.count() {
        if node.at(index).spec.shown_in(room) { count = count + 1 }
    }
    return count
}

/// Zero rather than a negative size.
///
/// A container smaller than its own chrome is a real thing to ask for — a
/// window dragged down to nothing does it — and a negative width would put a
/// child's right edge to the left of its left one, which every arranger below
/// would then propagate.
fn widen(value: f64) -> f64 {
    if value < 0.0 { return 0.0 }
    return value
}
