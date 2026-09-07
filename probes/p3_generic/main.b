// Probe 3 — an unbounded `component<T>` activated through `type_of(T)`.
//
// Generic bounds in Beans are interfaces only, so `T` in
// `b.component<Hint>(18, setter)` cannot be bounded to `Component` and latte
// cannot write `new T()`. PLAN.md's answer is reflection: reach `type_of(T)`
// from inside the generic, activate an instance, downcast the reflect.Value
// to `T` for the setter and to `Component` for the render call.
//
// The three things that have to be true, none of which are obvious:
//   1. `type_of(T)` is legal for an *unbounded* generic parameter.
//   2. `value as? T` is legal for an unbounded `T`.
//   3. one activation can be seen as both `T` and its base class, so the
//      setter writes the subclass's fields and the renderer walks the base.
package main

import std.io
import std.reflect

pub class Builder {
    pub out: string = ""
    pub fn text(seq: int, body: string) { self.out = "{self.out}[{seq}:{body}]" }
}

pub class Component {
    pub fn render(b: Builder) { b.text(-1, "base") }
}

pub class Hint extends Component {
    pub label: string = "unset"
    pub tone: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.text(1, "hint {self.label}/{self.tone}")
    }
}

pub class Badge extends Component {
    pub count: int = -1
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(2, "badge {self.count}") }
}

// A component with no zero-argument initializer, to see what the failure looks
// like when latte cannot activate.
pub class NeedsDep extends Component {
    pub name: string
    pub fn init(name: string) { self.name = name }
    pub override fn render(b: Builder) { b.text(3, "dep {self.name}") }
}

// Not a Component at all, but activatable. `component<T>` has no way to refuse
// this at compile time — `T` is unbounded — so the refusal has to be the
// markup compiler's, and this is what happens if it is not.
pub class NotAComponent {
    pub whatever: int = 0
    pub fn init() {}
}

// A generic component. `pub partial class Grid<T> extends Component` is what
// PLAN.md says a generic component is, so `component<Grid<int>>` is the shape
// the markup compiler emits for `<Grid ...>` with a type argument.
pub class Grid<T> extends Component {
    pub rows: List<T> = []
    pub title: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.text(4, "grid {self.title}/{self.rows.len()}")
    }
}

// ------------------------------------------------------------------ the probe
//
// This is the shape the markup compiler emits: an unbounded generic method on
// the builder, a sequence number, and a setter closure typed to the component.
class Renderer {
    pub log: string = ""

    // Every activation, so a test can prove two calls made two objects rather
    // than assuming it.
    pub made: List<string> = []

    pub fn component<T>(b: Builder, seq: int, setup: fn(T)) -> string {
        let described: reflect.Type = type_of(T)
        match described.initializer() {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => {
                        // Two views of one activation. `copy()` is what keeps
                        // the first downcast from taking the payload.
                        let typed: Option<T> = made.copy() as? T
                        let based: Option<Component> = made as? Component
                        match typed {
                            some(instance) => { setup(instance) }
                            none => { return "not a {described.name()}" }
                        }
                        match based {
                            some(component) => {
                                b.text(seq, "<")
                                component.render(b)
                                b.text(seq, ">")
                                return "ok"
                            }
                            none => { return "{described.name()} is not a Component" }
                        }
                    }
                    err(e) => { return "activate failed: {e.message()}" }
                }
            }
            none => { return "no zero-argument initializer on {described.name()}" }
        }
    }
}

// Identity, without relying on the frames reading right. Two activations of
// the same T must be two objects: writing one must not be visible in the other.
class Pair {
    pub first: Option<Hint> = none
    pub second: Option<Hint> = none
}

fn distinct(r: Renderer, b: Builder) -> bool {
    let pair: Pair = new Pair()
    let one: string = r.component<Hint>(b, 50, fn(h: Hint) {
        h.label = "first"
        h.tone = 1
        pair.first = some(h)
    })
    let two: string = r.component<Hint>(b, 51, fn(h: Hint) {
        h.label = "second"
        h.tone = 2
        pair.second = some(h)
    })
    if one != "ok" || two != "ok" { return false }
    match pair.first {
        some(a) => {
            match pair.second {
                some(c) => {
                    // Write through the second and read the first: a shared
                    // instance would show the write.
                    c.tone = 99
                    return a.label == "first" && a.tone == 1 && c.label == "second"
                }
                none => { return false }
            }
        }
        none => { return false }
    }
}

fn main() {
    let r: Renderer = new Renderer()
    let b: Builder = new Builder()

    let first: string = r.component<Hint>(b, 10, fn(h: Hint) {
        h.label = "keep going"
        h.tone = 3
    })
    let second: string = r.component<Badge>(b, 20, fn(x: Badge) {
        x.count = 7
    })
    // Two instantiations of the same T must not share an instance.
    let third: string = r.component<Hint>(b, 30, fn(h: Hint) {
        h.label = "second"
        h.tone = 9
    })
    let fourth: string = r.component<NeedsDep>(b, 40, fn(d: NeedsDep) {
        d.name = "never"
    })

    let fifth: string = r.component<NotAComponent>(b, 60, fn(n: NotAComponent) {
        n.whatever = 1
    })
    let sixth: string = r.component<Grid<int>>(b, 70, fn(g: Grid<int>) {
        g.title = "orders"
        g.rows.push(4)
        g.rows.push(5)
    })

    io.println("type_of(T) reached an unbounded T: {first == "ok"}")
    io.println("a second component type worked too: {second == "ok"}")
    io.println("a third call worked: {third == "ok"}")
    io.println("two activations are two objects: {distinct(r, b)}")
    io.println("a generic component activated: {sixth}")
    io.println("no zero-arg init: {fourth}")
    io.println("T that is not a Component: {fifth}")
    io.println("frames: {b.out}")
}
