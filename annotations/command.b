// Declares a method as a menu command.
package annotations

/// A method that can be invoked from a menu, a keyboard shortcut, or both.
///
/// `role` is the part that makes this portable, and it is why a command is
/// declared rather than a menu built by hand. Every desktop platform has
/// opinions about where certain commands live and what they are called: About
/// and Preferences belong in the application menu on macOS and in Help and
/// Edit on Windows, Quit is Cmd-Q on one and Alt-F4 on another, and Cut, Copy
/// and Paste must be wired to the platform's own editing machinery rather than
/// to a handler of yours or the system text field stops working.
///
/// A command with a role is placed and named by the platform. A command
/// without one is an application command and goes where the application puts
/// it. Describing a menu as a tree of titles instead would produce a menu that
/// is correct on the platform it was written on and wrong everywhere else.
///
/// `key` is a portable shortcut description — `"mod+s"`, `"mod+shift+n"` —
/// where `mod` is Command on macOS and Control elsewhere.
///
/// `icon` names a `SystemIcon` role — `"refresh"`, `"run"`, `"print"`. It is a
/// string and not the enum so that `latte.annotations` keeps importing
/// nothing: every generated screen imports this package, and a dependency from
/// here on `latte.controls` would put the platform host behind every one of
/// them. An unknown name is refused when the command is wired, naming the
/// role and the method, rather than quietly leaving the space empty.
@target(value: ["method"])
@retention(value: "runtime")
pub annotation command {
    id: string = ""
    title: string = ""
    key: string = ""
    role: string = ""
    icon: string = ""
    /// Put a dividing line above this command.
    ///
    /// A separator belongs to the item below it rather than being an item of
    /// its own, because a list of methods has nowhere to hang a thing that is
    /// not a method — and because a separator that was its own declaration
    /// would be one more row to keep in the right place when commands move.
    separator: bool = false
}
