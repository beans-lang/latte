package scene

/// Owned by a window, shared by its objects. No back-reference to the window.
/// Revisions avoid losing invalidations raised during a frame.
pub class Invalidation {
    layout_revision: int = 1
    paint_revision: int = 1
    semantics_revision: int = 1
    painted_revision: int = 0
    animation_queue: AnimationQueue = new AnimationQueue()
    pub fn init() {}
    pub fn layout() { self.layout_revision += 1; self.paint(); self.semantics() }
    pub fn paint() { self.paint_revision += 1 }
    pub fn semantics() { self.semantics_revision += 1 }
    pub fn layout_version() -> int { return self.layout_revision }
    pub fn paint_version() -> int { return self.paint_revision }
    pub fn semantics_version() -> int { return self.semantics_revision }
    pub fn needs_paint() -> bool { return self.paint_revision != self.painted_revision }
    pub fn painted(version: int) { self.painted_revision = version }
    pub fn animations() -> AnimationQueue { return self.animation_queue }
    pub fn request_animation(handle: u64) { self.animation_queue.request(handle) }
}
