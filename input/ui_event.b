// One thing that happened, decoded.
package input

import latte.platform
import latte.geometry

/// An event, in Beans terms.
///
/// One record for every kind, filled in by whatever raised it — the browser
/// adapter, a control driving itself, or a test. It carries no reference back
/// to the control, which is what lets a handler be an ordinary function rather
/// than a closure that captures the control it belongs to — and that, in turn,
/// is what keeps controls and handlers from forming a cycle the collector
/// cannot see.
pub class UiEvent {
    pub kind: EventKind = EventKind.unknown
    pub target: platform.Handle = platform.Handle.none()
    pub modifiers: int = 0
    /// Row, tab, selected index or key code, depending on `kind`. For a table
    /// cell's `text_commit`, this is the row.
    pub index: int = 0
    /// Echoes the word passed to `Application.post`, for `post` events. For a
    /// table cell's `text_commit`, this is the column.
    /// For pointer down/up, this is the native click count (use `click_count`).
    pub token: int = 0
    pub position: geometry.Point = geometry.Point.zero()
    pub size: geometry.Size = geometry.Size.zero()

    /// What the control said, for the events where that is the news: a value
    /// that changed, a field that committed, the characters a key produced.
    /// Empty for every other kind.
    pub text: string = ""

    pub fn init(kind: EventKind, target: platform.Handle) {
        self.kind = kind
        self.target = target
    }

    /// An event for a control, with nothing else set yet.
    ///
    /// Everything raises events this way — the browser adapter, a control
    /// driving a change it made itself, the differ, a test — so a handler has
    /// one shape whatever woke it, and none of it needs a machine.
    pub static fn of(kind: EventKind, target: platform.Handle) -> UiEvent {
        return new UiEvent(kind, target)
    }

    pub fn has_modifier(bit: int) -> bool {
        return (self.modifiers & bit) != 0
    }

    /// Which key, for a key event.
    ///
    /// `Key.character` means the key typed something and `text` is what — a
    /// letter, a digit, an accented vowel, a whole Japanese syllable. Every
    /// other member is a key that types nothing and means the same thing on
    /// every keyboard there is.
    pub fn key() -> Key {
        return Key.of(self.index)
    }

    /// Which button, for a pointer event. Always `left` on a phone, where a
    /// finger has no buttons.
    pub fn button() -> PointerButton {
        return PointerButton.of(self.index)
    }
    pub fn click_count() -> int {
        if self.kind != EventKind.pointer_down && self.kind != EventKind.pointer_up { return 0 }
        return if self.token > 0 { self.token } else { 1 }
    }

    /// The line the event goldens carry. Only the fields a given kind actually
    /// uses appear, so adding a field to the record does not churn every
    /// golden in the suite.
    pub fn show() -> string {
        match self.kind {
            post => { return "post token={self.token}" }
            // The number and nothing else. A frame also carries when it
            // happened and how long since the last one, and neither is the
            // same twice — a golden that printed them would be a report on
            // how busy the machine was.
            frame => { return "frame #{self.index}" }
            surface_resized => { return "surface_resized {self.size.show()}" }
            pointer_down => { return "pointer_down {self.target.show()} {self.position.show()} {self.button().name()}" }
            pointer_up => { return "pointer_up {self.target.show()} {self.position.show()} {self.button().name()}" }
            pointer_move => { return "pointer_move {self.target.show()} {self.position.show()}" }
            selection => { return "selection {self.target.show()} index={self.index}" }
            // The key's name and not its number, because the number is an ABI
            // detail and the name is the same word on every host — which is
            // what makes one golden stand for four of them.
            key_down => { return "key_down {self.target.show()} key={self.key().name()} typed=\"{self.text}\"" }
            key_up => { return "key_up {self.target.show()} key={self.key().name()}" }
            focus => { return "focus {self.target.show()}" }
            // The machine's own events name no widget: `target` is 0, because
            // a network is not a control.
            net_changed => { return "net_changed index={self.index} flags={self.position.x as int}" }
            power_changed => { return "power_changed index={self.index}" }
            blur => { return "blur {self.target.show()}" }
            _ => { return "{self.kind.name()} {self.target.show()}" }
        }
    }
}
