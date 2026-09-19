// Marks a class as something that can be shown.
package annotations

/// A component: a class that describes a piece of user interface and can be
/// mounted into a surface.
///
/// The annotation carries no arguments and exists to be *found*. A framework
/// that required every component to be registered by hand would have a
/// registry that drifts from the code; one that treated every subclass of
/// `Component` as mountable could not tell a real view from an abstract base
/// somebody wrote to share code between two views. `@view` is the author
/// saying which is which.
///
/// `@retention(value: "runtime")` on every annotation in this package, because
/// the default is not runtime and a scan that cannot see an annotation is not
/// a scan.
///
/// ```beans
/// import {view, param, inject} from latte.annotations
///
/// @view
/// pub class OrderRow extends compose.Component {
///     @param pub title: string = ""
///     @inject pub pricer: Pricer
/// }
/// ```
@target(value: ["type"])
@retention(value: "runtime")
pub annotation view {
}
