// `ViewModel` and `Command`: a component's state and behaviour, separable from
// its markup.
//
// latte does not need MVVM and does not impose it. A component with public
// fields and methods is a perfectly good component, and every example in this
// repo is one. What a view-model adds is a place for three things a component
// is a bad home for:
//
//  * **services.** A component is constructed by the renderer; a view-model is
//    `@inject`ed into it, so it can hold a repository without the page passing
//    one down.
//  * **testing.** A view-model has no render tree and no builder. Its logic can
//    be exercised without mounting anything.
//  * **state that has to outlive a render.** A component is re-rendered; a
//    view-model is not.
//
// This file must stay free of std.io, std.fs, std.net, std.time and
// std.random: it compiles for wasm32-unknown-unknown with the rest of the
// core.
package latte

import std.reflect

/// A view-model.
///
/// Attached to the component that holds it, by the framework, at mount. By the
/// time `on_attach` runs, its `Signal` fields are owned and its own `@inject`
/// fields — if it is itself injected — are filled.
pub class ViewModel {
    /// The component this model renders through.
    ///
    /// **Weak**, and not as a precaution: the component owns the model — it is
    /// a field on it — so a strong edge back is a cycle for the life of the
    /// page. `probes/p6_cycle` measures what that costs, and `Cell.owner` and
    /// `Callback.owner` are weak for the same reason.
    weak host: Option<Component> = none

    pub fn init() {}

    /// Called once, by the framework, when the component holding this model is
    /// mounted. An author overrides `on_attach`, not this.
    pub fn attach(host: Component) {
        self.host = some(host)
        self.on_attach()
    }

    /// Set up. Everything the framework can do for you is already done: signals
    /// are owned, injected fields are filled, and `notify()` works.
    ///
    /// It is also where `Command`s are built, because a field initializer
    /// cannot name `self` — the compiler refuses it while the object is still
    /// being assembled, which is exactly when a field initializer runs.
    pub fn on_attach() {}

    /// Whether this model has been attached to a component yet.
    pub fn attached() -> bool {
        match self.host {
            some(_) => { return true }
            none => { return false }
        }
    }

    /// Mark the view showing this model dirty.
    ///
    /// A `Signal` write does not need this — it patches the one bound
    /// expression that read it, which is the whole point of the tier. This is
    /// for state that is not a signal, and for a model that changed several
    /// things and wants one render.
    pub fn notify() {
        match self.host {
            some(component) => { component.notify() }
            none => {}
        }
    }
}

/// A named action a view binds to.
///
/// ```beans
/// pub override fn on_attach() {
///     self.place = Command.of(self, fn(model: ViewModel) {
///         match model as? OrderModel {
///             some(order) => { order.placed.set(order.placed.peek() + 1) }
///             none => {}
///         }
///     })
/// }
/// ```
///
/// **Why the body takes the model instead of capturing it.** A closure that
/// captures `self` into a field the same object owns is a reference cycle:
/// model → command → closure → model. `probes/p6_cycle` runs six shapes of
/// exactly this and measures which release immediately; the ones that do are
/// the ones where the callback holds a **weak** owner and the closure takes it
/// as a parameter. That is this shape. The `as?` inside is the cost, and it is
/// the cost of not leaking a model per circuit.
pub class Command {
    /// Weak, for the reason above.
    weak owner: Option<ViewModel> = none
    body: fn(ViewModel) = fn(model: ViewModel) {}
    guard: fn(ViewModel) -> bool = fn(model: ViewModel) -> bool { return true }

    pub fn init() {}

    /// A command that runs `body` against `owner`.
    pub static fn of(owner: ViewModel, body: fn(ViewModel)) -> Command {
        var made: Command = new Command()
        made.owner = some(owner)
        made.body = body
        return move made
    }

    /// The same, with a condition. A view asks `can_run()` to decide whether to
    /// disable the control, and `run()` asks it again — so a stale render
    /// cannot fire a command the model has since disallowed.
    pub static fn guarded(owner: ViewModel, body: fn(ViewModel),
                          guard: fn(ViewModel) -> bool) -> Command {
        var made: Command = Command.of(owner, body)
        made.guard = guard
        return move made
    }

    /// Whether this command would do anything. `false` for a command whose
    /// model has been disposed, which is what makes a stale handler safe.
    pub fn can_run() -> bool {
        match self.owner {
            some(model) => {
                let ask: fn(ViewModel) -> bool = self.guard
                return ask(model)
            }
            none => { return false }
        }
    }

    /// Run it, if it can run. A command that cannot is silently not run: a
    /// disabled button that was clicked anyway is not an error, it is a race
    /// the model already decided.
    pub fn run() {
        match self.owner {
            some(model) => {
                let ask: fn(ViewModel) -> bool = self.guard
                if !ask(model) { return }
                let act: fn(ViewModel) = self.body
                act(model)
            }
            none => {}
        }
    }
}
