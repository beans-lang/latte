// How much of an application this process is.
package platform


/// The face a latte process shows the system.
pub enum AppRole {
    /// A normal application: dock or taskbar entry, menu bar, can be focused.
    gui
    /// Runs and can show windows, but owns no dock or taskbar entry. Menu bar
    /// extras, background agents and installers live here.
    accessory
    /// Builds and measures widgets, but never puts one on screen.
    ///
    /// This is what the test suite runs as, and it is why latte's expected output
    /// files are the same on a continuous-integration runner as on a desk: the
    /// widget tree is fully real — measured by the platform's own text
    /// metrics — without anything ever being displayed.
    headless

    pub fn code() -> int {
        return match self {
            gui => ROLE_GUI,
            accessory => ROLE_ACCESSORY,
            headless => ROLE_HEADLESS,
        }
    }

    pub fn name() -> string {
        return match self {
            gui => "gui",
            accessory => "accessory",
            headless => "headless",
        }
    }
}
