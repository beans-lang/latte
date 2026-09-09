// Does `reflect.value(x)` box the value's RUNTIME type or the binding's static
// one?
//
// BLOCKERS.md B6: it used to box the static type, so an object held through a
// base-class binding lost what it was and `as?` back to the subclass answered
// none — "the practical damage is that reflection cannot be used to recover a
// subclass from a base-class binding, which is most of what a framework wants
// it for". Fixed in 0.1.41 (#163). The Renderer holds its page as a
// `Component`, and the mount pass needs the concrete type to find its fields,
// so this is the exact question.
package main

import std.io
import std.reflect
import {Component} from latte

pub class Special extends Component {
    pub tag: int = 7
    pub fn init() {}
}

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("BAD  {what}: got [{got}], want [{want}]") }
}

fn main() {
    // Held as the BASE type, which is how a Renderer holds its page.
    let held: Component = new Special()
    let boxed: reflect.Value = reflect.value(held)
    report("the box names the runtime type", boxed.type().qualified_name(),
           "p_boxed_type.Special")
    report("and its fields are the subclass's",
           "{boxed.type().field("tag").is_some()}", "true")
}
