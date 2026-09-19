package scene

/// Only active handles are visited on a frame. No callbacks or render objects
/// are retained here, so a removed control cannot keep its window alive.
pub class AnimationQueue {
    active: Map<u64, bool> = {}
    pub fn init() {}
    pub fn request(handle: u64) { if handle != 0 { self.active[handle] = true } }
    pub fn cancel(handle: u64) { self.active.remove(handle) }
    pub fn has_work() -> bool { return self.active.len() > 0 }
    pub fn handles() -> List<u64> { return self.active.keys() }
    pub fn clear() { self.active.clear() }
}
