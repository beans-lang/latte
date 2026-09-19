// Where injected fields come from.
package compose

import std.reflect

/// Answers for a service a component asked for.
///
/// An interface over `std.reflect` and nothing else, so `latte.compose`
/// needs no dependency on any particular container. `cortado_app` implements it
/// over barista; an application with its own idea of where services come from
/// implements it over that. The component layer never learns what a service
/// collection is.
///
/// `knows` exists separately from `provide` because a question that has to
/// build the object in order to be asked is not a question you can ask about
/// two hundred components at startup. Checking a whole application's
/// dependencies before it opens a window means a missing registration is one
/// message at launch rather than a blank panel three screens in.
pub interface ServiceSource {
    fn provide(described: reflect.Type) -> Result<reflect.Value, string>

    /// Whether this source could answer for `described`, without building
    /// anything.
    fn knows(described: reflect.Type) -> bool
}
