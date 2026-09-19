// Declares the surface a component opens in.
package annotations

/// The window a root component is shown in.
///
/// Only meaningful on a `@view` that is mounted as an application's root. It
/// is a declaration and not a call so that the size and title of a screen live
/// next to the screen, and so a tool can read an application's windows without
/// running it.
///
/// `width` and `height` are the *content* size in points, excluding whatever
/// frame the platform puts around it. A title bar is 28 points on one platform
/// and 32 on another, and a number that meant "including the frame" would
/// describe a different content area on each.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation window {
    title: string = ""
    width: float = 640.0
    height: float = 480.0
    resizable: bool = true
}
