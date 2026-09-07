package main

import std.io
import std.reflect

pub class Grid<T> {
    pub title: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "grid {self.title}" }
}

pub class Plain {
    pub title: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "plain {self.title}" }
}

fn main() {
    let closed: reflect.Type = type_of(Grid<int>)
    io.println("closed qualified: {closed.qualified_name()} args {closed.type_arguments().len()}")
    io.println("closed initializer: {closed.initializer().is_some()}")
    match closed.method("touch") {
        some(m) => {
            io.println("touch declaring type: {m.declaring_type().qualified_name()}")
            io.println("touch is_generic: {m.is_generic()}")
        }
        none => { io.println("no touch") }
    }
    let g: Grid<int> = new Grid<int>()
    g.title = "orders"
    let v: reflect.Value = reflect.value(g)
    io.println("value type: {v.type().qualified_name()}")
    io.println("value is_type(closed): {v.is_type(closed)}")
    io.println("closed.is_assignable_from(value type): {closed.is_assignable_from(v.type())}")
    match closed.method("touch") {
        some(m) => {
            match m.call(v.copy(), []) {
                ok(r) => { io.println("reflective touch: {(r as? string).expect("s")}") }
                err(e) => { io.println("reflective touch failed: {e.kind()}: {e.message()}") }
            }
        }
        none => {}
    }
    // Field read/write through reflection on a closed generic.
    match closed.field("title") {
        some(f) => {
            match f.get(v.copy()) {
                ok(got) => { io.println("field read: {(got as? string).expect("s")}") }
                err(e) => { io.println("field read failed: {e.kind()}: {e.message()}") }
            }
        }
        none => { io.println("no title field") }
    }
    // The same three on a non-generic class, as the control.
    let p: Plain = new Plain()
    p.title = "control"
    let pv: reflect.Value = reflect.value(p)
    match type_of(Plain).method("touch") {
        some(m) => {
            match m.call(pv.copy(), []) {
                ok(r) => { io.println("control touch: {(r as? string).expect("s")}") }
                err(e) => { io.println("control touch failed: {e.kind()}: {e.message()}") }
            }
        }
        none => {}
    }
    match type_of(Plain).field("title") {
        some(f) => {
            match f.get(pv.copy()) {
                ok(got) => { io.println("control field read: {(got as? string).expect("s")}") }
                err(e) => { io.println("control field read failed: {e.kind()}: {e.message()}") }
            }
        }
        none => {}
    }
}
