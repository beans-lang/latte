// Restricts a member to the platforms that have it.
package annotations

/// A member that exists only on some platforms.
///
/// `only` names them: `@platform(only: ["macos", "windows"])`. On any other
/// platform the member is refused **at startup**, with a message naming the
/// member and the platforms it was declared for.
///
/// Refusing loudly is the whole point. The alternative every framework
/// reaches for is to make the call a no-op off-platform, and a no-op is
/// indistinguishable from a feature that is broken: a menu bar that quietly
/// does nothing on Linux looks exactly like a menu bar that failed to build.
/// latte's rule throughout is that a platform which cannot do something says
/// so — `ctd_capability` at the ABI, `CTD_ERR_UNSUPPORTED` from a call, and
/// this at the declaration.
///
/// Use it for the genuinely unportable: a dock tile, a jump list, a system
/// tray. For anything latte can express on every platform, do not use it —
/// ask `platform.Capability` at run time instead, which is a question with an
/// answer rather than a member that may not be there.
@target(value: ["method", "field"])
@retention(value: "runtime")
pub annotation platform {
    only: List<string> = []
}
