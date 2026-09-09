// Can the framework own a component's signals for it?
//
// `Signal<T>.own(self)` has to be written by hand in `on_init`, once per
// signal, and forgetting it is a signal that records no binding. The framework
// could do it at mount — walk the component's fields, find the `Signal` ones,
// and own them — but only if reflection can reach a generic field's contents.
//
// `Signal<T>` is generic and `as? Signal<int>` is refused outright ("as? cannot
// test for an instantiation"). The way through, if there is one, is that `Cell`
// is NOT generic: read the signal's `cell` field reflectively and downcast that.
//
// BLOCKERS.md B1a says reading a field whose DECLARING type is generic answered
// `unsupported` natively in 0.1.40 and was fixed in 0.1.41 (#158/#159). This is
// exactly that shape, so it is measured rather than assumed, on both backends.
package main

import std.io
import std.reflect
import {Cell, Component, Signal} from latte

pub class Clock extends Component {
    pub ticks: Signal<int> = new Signal<int>(0)
    pub name: string = "clock"
    pub fn init() {}
}

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("BAD  {what}: got [{got}], want [{want}]") }
}

fn main() {
    let clock: Clock = new Clock()
    let described: reflect.Type = type_of(Clock)

    // 1. can the field be seen at all, and does it name the closed generic?
    var signal_fields: int = 0
    var type_name: string = ""
    for field: reflect.Field in described.fields() {
        if field.type().qualified_name().starts_with("latte.Signal") {
            signal_fields += 1
            type_name = field.type().qualified_name()
        }
    }
    report("one Signal field found", "{signal_fields}", "1")
    report("and its type is the closed generic", type_name, "latte.Signal<int>")

    // 2. read it, and reach its Cell — the non-generic half.
    let boxed: reflect.Value = reflect.value(clock)
    match described.field("ticks") {
        none => { io.println("BAD  no field descriptor for ticks") }
        some(field) => {
            match field.get(boxed.copy()) {
                err(problem) => {
                    io.println("BAD  reading the signal failed: {problem.message()}")
                }
                ok(signal_value) => {
                    io.println("ok   the Signal field can be read reflectively")
                    match signal_value.type().field("cell") {
                        none => { io.println("BAD  Signal has no reflective 'cell' field") }
                        some(cell_field) => {
                            match cell_field.get(signal_value.copy()) {
                                err(problem) => {
                                    io.println("BAD  reading Signal.cell failed: {problem.message()}")
                                }
                                ok(cell_value) => {
                                    match cell_value as? Cell {
                                        none => { io.println("BAD  the cell did not downcast") }
                                        some(cell) => {
                                            // The whole point: own it without
                                            // the author writing a line.
                                            cell.own(clock)
                                            report("the framework owned the signal",
                                                   "{cell.attached()}", "false")
                                            io.println("   (attached is false because nothing mounted this component;")
                                            io.println("    what matters is that own() was reached and did not fail)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
