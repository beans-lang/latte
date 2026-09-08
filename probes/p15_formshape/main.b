package main

import std.io
import std.reflect

@target(value: ["field"])
@retention(value: "runtime")
annotation ranged {
    min: int
    max: int
}

abstract class Base {
    pub fn init() {}
    pub abstract fn name() -> string
    pub fn greet() -> string { return "hi {self.name()}" }
}

class Leaf extends Base {
    pub model: Inner = new Inner()
    pub fn init() { super.init() }
    pub override fn name() -> string { return "leaf" }
    pub fn value() -> reflect.Value { return reflect.value(self.model) }
}

class Inner {
    @ranged(min: 1, max: 4) pub n: int = 0
    pub fn init() {}
}

fn main() {
    let leaf: Leaf = new Leaf()
    io.println("A {leaf.greet()}")
    let v: reflect.Value = leaf.value()
    io.println("B {v.type().qualified_name()}")
    match v.type().field("n") {
        some(f) => {
            match f.set(v.copy(), reflect.value(7)) {
                ok(_) => { io.println("C set ok, model.n = {leaf.model.n}") }
                err(e) => { io.println("C set err {e.message()}") }
            }
        }
        none => { io.println("C no field") }
    }
    let padded: string = "  ab  "
    io.println("D trim = [{padded.trim()}]")
    let base: Base = leaf
    match base as? Leaf {
        some(_) => { io.println("E base as? Leaf = some") }
        none => { io.println("E base as? Leaf = none") }
    }
}
