// p13 — a string interpolation resolves type names without the file's
// named-import bindings.
//
// BLOCKERS.md B9 found one spelling (`new T()`, refused). B8 found a second
// (`type_of(T)`, accepted and silently wrong), and `p12_consumer_type_of`
// showed they are the same bug rather than the same shape. This probe is the
// rest of the question RULES.md 2 demands: every expression form that names a
// type inside `"{ }"`.
//
// The accepted-and-wrong half is here. The half that used to be REFUSED is
// `p13_interpolation_fixed/` — it was `p13_interpolation_bad/`, and
// `check_refusals.sh` went red the day beans #164 made it compile, which is
// what that record was for. It is now a plain probe of the fixed behaviour.
//
// Every line is written twice: the name inside the quotes, and the same name
// bound to a `let` one line above and interpolated. They must agree.
package main

import std.io
import std.reflect
import {Widget, Fancy, make, twice} from p13_interp.kit

/// The control: a type declared in this file needs no import binding, so it
/// cannot be lost by one. It must read the same both ways.
pub class Local { pub button: int = 3; pub fn init() {} }
pub class LocalChild extends Local { pub fn init() { super.init() } }

fn row(what: string, inside: string, outside: string) {
    io.println("  {what}")
    io.println("      inside  = {inside}")
    io.println("      outside = {outside}")
    io.println("      {if inside == outside { "agree" } else { "DIFFERENT" }}")
}

fn main() {
    let local_t: reflect.Type = type_of(Local)
    row("control — type_of(Local), declared in this file",
        "{type_of(Local).qualified_name()}", local_t.qualified_name())

    let widget_t: reflect.Type = type_of(Widget)
    row("type_of(Widget) — a named import",
        "{type_of(Widget).qualified_name()}", widget_t.qualified_name())

    let fancy_t: reflect.Type = type_of(Fancy)
    row("type_of(Fancy) — a named import, a subclass",
        "{type_of(Fancy).qualified_name()}", fancy_t.qualified_name())

    // The question a framework asks, and the reason this matters at all.
    let base: reflect.Type = type_of(Widget)
    let sub: reflect.Type = type_of(Fancy)
    row("Widget.is_assignable_from(Fancy)",
        "{type_of(Widget).is_assignable_from(type_of(Fancy))}",
        "{base.is_assignable_from(sub)}")

    let lb: reflect.Type = type_of(Local)
    let lc: reflect.Type = type_of(LocalChild)
    row("control — Local.is_assignable_from(LocalChild)",
        "{type_of(Local).is_assignable_from(type_of(LocalChild))}",
        "{lb.is_assignable_from(lc)}")

    // Not every expression inside an interpolation is affected. A CALL that
    // returns the type is fine — it names a function, not a type — which is
    // what says the fault is in type-name resolution and not in interpolation
    // in general.
    let w: Widget = make()
    row("make().label() — a call, no type name",
        "{make().label()}", w.label())

    // ---- the POSITIVE CONTROLS for `p13_interpolation_fixed/` -----------
    //
    // Four shapes are REFUSED inside an interpolation, each naming the wrong
    // package. Written outside the quotes, every one of them compiles and
    // runs — which is what says the refusal is about the interpolation and
    // not about the program. Without these lines the recorded refusals could
    // not be told apart from four programs that are simply wrong.
    io.println("  controls, all OUTSIDE the quotes:")
    let made: Widget = new Widget()
    io.println("      new Widget().button      = {made.button}")
    let f: Widget = new Fancy()
    let hit: Option<Fancy> = f as? Fancy
    io.println("      (f as? Fancy).is_some()  = {hit.is_some()}")
    let n: int = twice<Widget>(made)
    io.println("      twice<Widget>(w)         = {n}")
    let cast: Widget = made as Widget
    io.println("      (w as Widget).button     = {cast.button}")

    // `find_type` on the wrong name finds nothing, which is what makes the
    // wrong answer a dead end rather than a different spelling of the truth.
    let wrong: string = "{type_of(Widget).qualified_name()}"
    let right: string = widget_t.qualified_name()
    io.println("  find_type(\"{wrong}\") = {reflect.find_type(wrong).is_some()}")
    io.println("  find_type(\"{right}\") = {reflect.find_type(right).is_some()}")
}
