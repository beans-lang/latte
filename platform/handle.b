// The integer that names a native control.
package platform

/// A reference to something the platform owns — a widget, a surface, an image.
///
/// It is deliberately not a pointer. The host packs a generation counter into
/// the high half, and releasing a widget bumps that counter, so a handle kept
/// past its widget's life resolves to nothing and every call answers
/// `stale` instead of reaching freed memory. A raw pointer cannot do that: a
/// dangling `NSView *` looks exactly like a live one right up until it
/// crashes, and raw pointers copy freely, so freeing through one alias leaves
/// every other alias dangling with no way to tell.
///
/// Being a struct over a single `u64` means a `Widget` costs one word for its
/// handle, not a second allocation.
pub struct Handle {
    pub raw: u64 = 0

    pub static fn none() -> Handle {
        return Handle {}
    }

    pub static fn of(raw: u64) -> Handle {
        return Handle { raw: raw }
    }

    /// False for the zero handle. This is a cheap syntactic check: it says the
    /// handle was ever issued, not that its widget is still alive. Ask the
    /// host with `Widget.is_alive()` for that.
    pub fn is_set() -> bool {
        return self.raw != 0
    }

    /// The slot the host keeps this widget in. Only the test dumps want it,
    /// and they want it because a slot number is stable across a run while an
    /// address is not.
    pub fn slot() -> int {
        return (self.raw & 0xffffffff) as int
    }

    pub fn generation() -> int {
        return (self.raw >> 32) as int
    }

    pub fn show() -> string {
        return "#{self.slot()}"
    }
}
