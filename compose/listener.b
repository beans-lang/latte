// One event a described widget wants to hear about.
package compose

import latte.input

/// An event kind and what to do when it happens.
///
/// A class rather than a struct because it holds a closure, and because the
/// differ needs to compare *which events are listened for* without ever
/// comparing the closures themselves — two closures are never equal in any
/// useful sense, so a differ that tried would rebuild a handler on every
/// render.
///
/// So the rule is: the set of event kinds is diffed, and the action is
/// refreshed for every element the differ visits. Those are exactly the
/// elements whose component re-rendered, which are exactly the ones whose
/// closures may have changed — a component that `should_render` skipped is
/// left holding the closure it already had, correctly.
pub class Listener {
    pub kind: input.EventKind = input.EventKind.activate
    action: fn(input.UiEvent)

    pub fn init(kind: input.EventKind, action: fn(input.UiEvent)) {
        self.kind = kind
        self.action = action
    }

    pub fn fire(event: input.UiEvent) {
        let action: fn(input.UiEvent) = self.action
        action(event)
    }
}
