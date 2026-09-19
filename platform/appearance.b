// Light or dark, and how sharp the display is.
package platform


/// Whether the system is showing light or dark.
///
/// Latte draws every control itself, so this reaches the theme rather than a
/// set of system widgets: `scene.Theme` picks its colours from it, and a
/// program only asks directly when it draws something of its own. Changes
/// arrive as an `appearance` event, so nothing has to poll.
pub enum Appearance {
    light
    dark

    pub fn name() -> string {
        return match self {
            light => "light",
            dark => "dark",
        }
    }

    /// What the host is showing right now.
    pub static fn current() -> Appearance {
        return HostDesk.instance.host().appearance()
    }

    pub static fn of(code: int) -> Appearance {
        if code == 1 { return Appearance.dark }
        return Appearance.light
    }
}
