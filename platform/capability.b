// What this host can do.
package platform

/// Something a host may or may not offer.
///
/// Latte's promise is that the same program runs on every host, not that every
/// host grows the features of every other. A browser tab has a clipboard that
/// needs a user gesture; a headless test run has none at all. A program that
/// wants to do the right thing on each asks first.
///
/// The alternative — quietly doing nothing where a feature is missing — is
/// worse than it sounds. It turns "my paste never works" into a bug with no
/// error, no log line and nothing to search for. So every `Host` method
/// refuses by name, and this is how a caller finds out before it calls.
pub enum Capability {
    /// Being told when a frame is due. Every host has one, including the
    /// headless one, whose clock only moves when a test moves it.
    frame_clock
    /// Reading and writing the system clipboard.
    clipboard
    /// Telling an input method where the caret is, so composition and
    /// candidate windows land in the right place.
    text_input
    /// Publishing a tree assistive technology can read.
    accessibility
    /// Drawing through the GPU rather than on the CPU. A host that answers no
    /// still draws — see `software` — it is simply slower.
    gpu
    /// Reading the drawn pixels back out. What the screenshot tests need, and
    /// what a host without a readable surface refuses.
    snapshot
    /// Loading a font file, so a program can pin the face it measured against.
    fonts
    /// Decoding an image from bytes or a URL.
    images
    /// Holding the pointer through a drag that leaves the surface.
    pointer_capture
    /// Following the system's light/dark setting.
    appearance
    /// Following the system's "reduce motion" setting.
    reduce_motion

    pub fn name() -> string {
        return match self {
            frame_clock => "frame_clock",
            clipboard => "clipboard",
            text_input => "text_input",
            accessibility => "accessibility",
            gpu => "gpu",
            snapshot => "snapshot",
            fonts => "fonts",
            images => "images",
            pointer_capture => "pointer_capture",
            appearance => "appearance",
            reduce_motion => "reduce_motion",
        }
    }

    /// Every capability, so a check can walk them rather than list them — a new
    /// one then shows up in the suite whether or not anybody added a row.
    pub static fn all() -> List<Capability> {
        return [Capability.frame_clock, Capability.clipboard, Capability.text_input,
                Capability.accessibility, Capability.gpu, Capability.snapshot,
                Capability.fonts, Capability.images, Capability.pointer_capture,
                Capability.appearance, Capability.reduce_motion]
    }

    /// Whether the host this program is running under offers it.
    pub fn available() -> bool {
        return HostDesk.instance.host().can(self)
    }
}
