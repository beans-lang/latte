// A second, independent fault found beside B1: the native backend hands back
// a reflect error message one byte short. See BLOCKERS.md, B2.
//
// Nothing generic here — this is an ordinary receiver-type mismatch, the kind
// any reflective call can produce.
//
//   probes/run.sh p3_reflect_msg
package main

import std.io
import std.reflect

pub class A {
    pub fn touch() -> string { return "a" }
}

pub class B {
    pub fn touch() -> string { return "b" }
}

fn main() {
    let wrong: B = new B()
    match type_of(A).method("touch") {
        some(m) => {
            match m.call(reflect.value(wrong), []) {
                ok(r) => { io.println("unexpectedly ok") }
                err(e) => {
                    io.println("kind:    {e.kind()}")
                    io.println("message: {e.message()}")
                    io.println("length:  {e.message().len()}")
                    io.println("last byte is 'h': {e.message().ends_with("h")}")
                }
            }
        }
        none => { io.println("no method") }
    }
    // A second, different message — the RIGHT receiver and the wrong argument
    // count — so the truncation is seen on more than one string and cannot be
    // read as one bad constant.
    let right: A = new A()
    match type_of(A).method("touch") {
        some(m) => {
            match m.call(reflect.value(right), [reflect.value(1)]) {
                ok(r) => { io.println("unexpectedly ok") }
                err(e) => {
                    io.println("kind2:    {e.kind()}")
                    io.println("message2: {e.message()}")
                    io.println("length2:  {e.message().len()}")
                }
            }
        }
        none => {}
    }
    // A third: a field written with the wrong value type.
    match type_of(A).initializer() {
        some(ctor) => {
            match ctor.call([reflect.value(1)]) {
                ok(r) => { io.println("unexpectedly ok") }
                err(e) => {
                    io.println("kind3:    {e.kind()}")
                    io.println("message3: {e.message()}")
                    io.println("length3:  {e.message().len()}")
                }
            }
        }
        none => { io.println("A has no initializer") }
    }
    match reflect.find_type("p3_reflect_msg.A") {
        some(t) => {
            match t.field("missing") {
                some(f) => { io.println("unexpected field") }
                none => { io.println("a missing field is Option.none, not an error") }
            }
        }
        none => { io.println("A is not registered") }
    }
}
