// The fonts an interface uses, by the job each one does.
package platform

/// A font by the job it does, rather than by name.
///
/// Naming a family is how an interface ends up looking foreign, and naming a
/// size is how it stops following the reader's own text setting. Asking for
/// the *role* gets one answer for the whole program, in one place — the
/// `FontRoles` a host installs.
pub enum SystemFont {
    body
    heading
    caption
    /// Fixed width, for code and for numbers that should line up in a column.
    mono

    pub fn name() -> string {
        return match self {
            body => "body",
            heading => "heading",
            caption => "caption",
            mono => "mono",
        }
    }

    pub fn family() -> Result<string> {
        return ok(FontDesk.instance.roles().family(self))
    }

    pub fn size() -> Result<f64> {
        return ok(FontDesk.instance.roles().size(self))
    }
}

/// What each role is, on this host.
///
/// An interface rather than a table so a host can answer from the system —
/// a browser reads the user's font settings, a test pins numbers — without
/// Latte reaching for either.
pub interface FontRoles {
    fn family(role: SystemFont) -> string
    fn size(role: SystemFont) -> f64
}

/// The roles Latte uses when a host installs none.
///
/// The families are CSS generic keywords rather than a named face: a keyword
/// resolves to whatever the reader has set, which is the point of asking by
/// role. The sizes are the macOS theme's, which is what the shipped templates
/// were measured against.
pub class DefaultFontRoles implements FontRoles {
    pub fn init() {}

    pub fn family(role: SystemFont) -> string {
        return match role {
            mono => "monospace",
            _ => "system-ui",
        }
    }

    pub fn size(role: SystemFont) -> f64 {
        return match role {
            body => 13.0,
            heading => 15.0,
            caption => 11.0,
            mono => 12.0,
        }
    }
}

pub singleton class FontDesk {
    current: FontRoles = new DefaultFontRoles()

    fn init() {}

    pub fn install(roles: FontRoles) { self.current = roles }
    pub fn roles() -> FontRoles { return self.current }
    pub fn reset() { self.current = new DefaultFontRoles() }
}
