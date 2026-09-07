// The wall found by probe 3, at its smallest. See BLOCKERS.md, B1.
//
// A CLOSED generic type — `Grid<int>`, every argument bound — has a working
// reflect.Type descriptor, and reflective field access on it works, but
// reflection cannot construct one and cannot call a method on one. A
// non-generic class of the identical shape is the control and does all three.
//
//   probes/run.sh p3_generic_wall
package main

import std.io
import std.reflect

pub class Grid<T> {
    pub title: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "grid {self.title}" }
}

// Identical, minus the type parameter.
pub class Plain {
    pub title: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "plain {self.title}" }
}

// A non-generic subclass of the closed generic — the shape that still works.
pub class IntGrid extends Grid<int> {
    pub fn init() { super.init() }
}

fn report(described: reflect.Type, subject: reflect.Value, label: string) {
    io.println("[{label}] qualified={described.qualified_name()} args={described.type_arguments().len()}")
    io.println("  reflect can construct it: {described.initializer().is_some()}")
    io.println("  the value is of that type: {subject.is_type(described)}")
    io.println("  the type accepts that value: {described.is_assignable_from(subject.type())}")
    match described.field("title") {
        some(f) => {
            match f.get(subject.copy()) {
                ok(got) => { io.println("  reflect can read a field: true ({(got as? string).expect("s")})") }
                err(e) => { io.println("  reflect can read a field: false ({e.kind()})") }
            }
        }
        none => { io.println("  reflect can read a field: no such field") }
    }
    match described.method("touch") {
        some(m) => {
            io.println("  the method is declared on: {m.declaring_type().qualified_name()}")
            match m.call(subject.copy(), []) {
                ok(r) => { io.println("  reflect can call a method: true ({(r as? string).expect("s")})") }
                err(e) => { io.println("  reflect can call a method: false ({e.kind()}: {e.message()})") }
            }
        }
        none => { io.println("  reflect can call a method: no such method") }
    }
}

fn main() {
    let grid: Grid<int> = new Grid<int>()
    grid.title = "orders"
    report(type_of(Grid<int>), reflect.value(grid), "Grid<int> — a closed generic")

    let plain: Plain = new Plain()
    plain.title = "control"
    report(type_of(Plain), reflect.value(plain), "Plain — the control")

    let sub: IntGrid = new IntGrid()
    sub.title = "subclass"
    report(type_of(IntGrid), reflect.value(sub), "IntGrid extends Grid<int> — the route that works")
}
