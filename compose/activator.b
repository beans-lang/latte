// Building a component type the framework was handed only by name.
package compose

import std.reflect

/// Constructs a type the container was never told about.
///
/// Markup names a component by its type — `<Price drink={...} />` — so
/// something has to turn that type into an object. A container can do it
/// properly, resolving the initializer's parameters from its own
/// registrations, which is how a component with constructor dependencies works
/// from markup at all.
///
/// It is a separate interface from `ServiceSource` because the two questions
/// are different. `provide` answers for a type somebody registered; this builds
/// one nobody did. A mount with no activator falls back to the type's own
/// zero-argument initializer, which covers every component that needs nothing
/// injected through its constructor.
pub interface Activator {
    fn build(described: reflect.Type) -> Result<reflect.Value, string>
}
