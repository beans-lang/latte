package main

import std.io
import {Counter, Builder, Component} from p5_partial.pages

fn main() {
    let c: Counter = new Counter()
    c.count = 7
    let b: Builder = new Builder()
    let base: Component = c
    base.render(b)
    io.println(b.out)
}
