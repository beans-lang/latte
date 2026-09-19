// How one component shows another.
package compose

import std.reflect

/// Renders a child component on a parent's behalf.
///
/// The `Builder` a parent renders into does not know what a mount is, and must
/// not: it is the same object whether it is building a real window, a test
/// tree or a subtree for comparison. So `Builder.child` asks this, and the
/// mount is what implements it.
///
/// The implementation is responsible for everything the parent should not have
/// to think about: filling the child's injected fields the first time it is
/// seen, running its lifecycle in order, and — when the child says it has
/// nothing new to show — handing back the subtree it produced last time
/// instead of rendering it again.
pub interface Composer {
    fn compose(key: string, child: Component) -> Result<Element>

    /// The child registered under `key`, building one of type `described` the
    /// first time it is asked for.
    ///
    /// Markup names a component by its type, not by an instance — `<Price
    /// drink={self.drink} />` — so the mount has to own the instance and hand
    /// the same one back on every later render. That is what makes a child
    /// keep its state.
    ///
    /// Not generic, and it cannot be: Beans refuses a generic method on an
    /// interface. So it answers a boxed `reflect.Value` and `Builder.child<T>`
    /// — a concrete class, where a generic method is allowed — does the
    /// downcast. A `reflect.Value` is the one source `as?` may narrow to an
    /// instantiation, which is what makes the whole shape possible.
    fn obtain(key: string, described: reflect.Type) -> Result<reflect.Value>
}
