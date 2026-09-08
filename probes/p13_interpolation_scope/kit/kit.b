// The imported half. Every name below reaches this package through a NAMED
// import in `main.b`, which is the binding the interpolation loses.
package kit

pub class Widget {
    pub button: int = 7
    pub fn init() {}
    pub fn label() -> string { return "widget" }
}

pub class Fancy extends Widget {
    pub fn init() { super.init() }
}

pub fn make() -> Widget { return new Widget() }

pub fn twice<T>(item: T) -> int { return 2 }

pub enum Tone { plain, loud }

pub class Shop {
    pub fn init() {}
    /// A static, so `Widget.tally()` names the TYPE in a call position.
    pub static fn tally() -> int { return 11 }
}

/// A function taking a closure, so a `fn(Widget)` type annotation can be
/// written inside an interpolation.
pub fn apply(f: fn(Widget) -> int) -> int { return f(new Widget()) }
