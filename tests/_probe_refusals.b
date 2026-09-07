package main

import std.io
import {Builder, Component, MouseEvent, Serializer} from latte

pub class NeedsArgs {
    pub value: int = 0
    pub fn init(seed: int) { self.value = seed }
}

pub class NoInit {
    pub value: int = 0
}

pub class Hidden {
    pub value: int = 0
    fn init() {}
}

pub class KidA extends Component {
    pub label: string = "a"
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "A/{self.label}") }
}

pub class KidB extends Component {
    pub label: string = "b"
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "B/{self.label}") }
}

pub class Flip extends Component {
    pub second: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        if self.second { b.component<KidB>(0, fn(c: KidB) { c.label = "two" }) }
        else { b.component<KidA>(0, fn(c: KidA) { c.label = "one" }) }
    }
}

fn show(name: string, b: Builder) {
    io.println("-- {name}")
    for fault: string in b.all_faults() { io.println("   fault: {fault}") }
    let w: Serializer = new Serializer()
    io.println("   html: {w.page(b)}")
}

fn main() {
    let a: Builder = new Builder()
    a.reset()
    a.component<NeedsArgs>(0, fn(x: NeedsArgs) {})
    a.settle()
    show("component<NeedsArgs>", a)

    let b: Builder = new Builder()
    b.reset()
    b.component<NoInit>(0, fn(x: NoInit) {})
    b.settle()
    show("component<NoInit>", b)

    let c: Builder = new Builder()
    c.reset()
    c.component<Hidden>(0, fn(x: Hidden) {})
    c.settle()
    show("component<Hidden> (private init)", c)

    // the class-change shape
    let flip: Flip = new Flip()
    let f: Builder = new Builder()
    f.render_root(flip)
    show("flip pass 1", f)
    flip.second = true
    f.render_root(flip)
    show("flip pass 2 (KidA slot asked for KidB)", f)

    // a fragment scope reaching unwind_to
    let g: Builder = new Builder()
    g.reset()
    g.boundary(0)
    g.fragment(1, fn(inner: Builder) {
        inner.text(0, "in the fragment")
        inner.end_boundary()
    })
    g.settle()
    show("end_boundary from inside a fragment body", g)

    let h: Builder = new Builder()
    h.reset()
    h.boundary(0)
    h.fragment(1, fn(inner: Builder) {
        inner.text(0, "written then thrown away")
        inner.fail_boundary("panicked inside a slot body")
        inner.text(0, "fallback")
    })
    h.end_boundary()
    h.settle()
    show("fail_boundary from inside a fragment body", h)
}
