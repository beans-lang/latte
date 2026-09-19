// Marks a field the container fills.
package annotations

/// A dependency: a field whose value comes from the service container.
///
/// Filled once, when the component is mounted — never per render. Resolving a
/// service costs on the order of a microsecond, which is nothing once and a
/// great deal sixty times a second, so latte works out a component type's
/// injection plan on its first mount and keeps it for the life of the
/// application.
///
/// The field must be `pub`, for the same reason a `@param` must: reflection
/// does not bypass visibility. A private `@inject` is named in a startup
/// refusal rather than left holding nothing.
///
/// ### An injected field needs a placeholder value
///
/// ```beans
/// @inject pub prices: Prices = new Prices()
/// ```
///
/// The `= new Prices()` is not optional and not a default the container falls
/// back to — it is overwritten at mount, always. Beans proves every field is
/// assigned before a constructor returns, and `init` runs long before anything
/// has a container to ask, so the field has to start somewhere. An
/// `Option<Prices>` would satisfy the checker too, at the cost of an unwrap at
/// every use.
///
/// **So prefer constructor injection for anything a component cannot work
/// without.** The container resolves an initializer's parameters when it
/// builds the component, no annotation is involved, and there is no
/// placeholder to build and throw away:
///
/// ```beans
/// pub class Basket extends compose.Component {
///     prices: Prices
///     pub fn init(prices: Prices) { super.init(); self.prices = prices }
/// }
/// ```
///
/// `@inject` earns its place where a constructor cannot reach: a base class
/// that needs a service without every subclass threading it through
/// `super.init`, and a component built by hand — `new OrderRow()` in a
/// parent's field — which the container never sees.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation inject {
}
