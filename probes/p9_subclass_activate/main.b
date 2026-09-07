package main

import std.io
import std.reflect

pub class Grid<T> {
    pub title: string = "g"
    pub fn init() {}
}
pub class PlainBase {
    pub title: string = "p"
    pub fn init() {}
}

pub class OrderGrid extends Grid<int> {          // subject: subclass of a CLOSED GENERIC
    pub start: int = 41
    pub fn init() { super.init() }
}
pub class PlainSub extends PlainBase {           // CONTROL: same shape, non-generic base
    pub start: int = 41
    pub fn init() { super.init() }
}
pub class Standalone {                           // CONTROL: no base at all
    pub start: int = 41
    pub fn init() {}
}

fn try_construct(label: string, t: reflect.Type) {
    match t.initializer() {
        some(init) => {
            match init.call([]) {
                ok(v) => { io.println("  {label}: CONSTRUCTED") }
                err(e) => { io.println("  {label}: construct FAILED ({e})") }
            }
        }
        none => { io.println("  {label}: no initializer descriptor") }
    }
}

fn main() {
    try_construct("Standalone                  (control, no base)     ", type_of(Standalone))
    try_construct("PlainSub extends PlainBase  (control, plain base)  ", type_of(PlainSub))
    try_construct("OrderGrid extends Grid<int> (subject, generic base)", type_of(OrderGrid))
}
