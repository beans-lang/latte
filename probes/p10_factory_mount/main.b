// p10 — does a compiler-emitted FACTORY CLOSURE mount a generic component on
// both backends, where reflective activation of the closed generic itself
// still cannot (it has no initializer descriptor, on either backend)?
//
// The whole mount path is reproduced, not a piece of it: an INSTANCE method on
// a Builder-shaped host, generic in T, taking `fn() -> T` and `fn(T)`; the
// mount table holding the `reflect.Value` the construction produced; the two
// downcasts a re-render needs (to T for the setter, to the base for the render
// call); and a virtual call through the base.
//
// Controls, because a probe with no control cannot tell "it works" from "it
// never ran":
//   C1  the same host method over a NON-GENERIC component — must work.
//   C2  reflective activation of the non-generic component — must work.
//   C3  reflective activation of a NON-generic subclass of a closed generic —
//       must work on both backends too. (This used to construct under the
//       interpreter and fail natively; beans 0.1.41 fixed the split.)
package main

import std.io
import std.reflect

// ---- the component hierarchy ------------------------------------------------
pub class Node {
    pub label: string = ""      // declared by a NON-generic base
    pub fn tag() -> string { return "node" }
    pub fn touched() -> int { return -1 }
}

pub class Grid<T> extends Node {
    pub title: string = ""
    pub rows: int = 0
    pub fn init() {}
    pub override fn tag() -> string { return "grid" }
    pub override fn touched() -> int { return self.rows }
}

pub class Hint extends Node {                       // C1/C2: non-generic
    pub title: string = ""
    pub rows: int = 0
    pub fn init() {}
    pub override fn tag() -> string { return "hint" }
    pub override fn touched() -> int { return self.rows }
}

pub class OrderGrid extends Grid<int> {             // C3's shape: a non-generic subclass of a closed generic
    pub fn init() { super.init() }
    pub override fn tag() -> string { return "ordergrid" }
}

// ---- the host: Builder.component_made<T>, in miniature ----------------------
pub class Host {
    pub children: Map<int, reflect.Value> = {}
    pub log: List<string> = []
    pub fn init() {}

    /// The factory route. `make` is what the markup compiler would emit; the
    /// generic entry point is an instance method because it reads and writes
    /// `self.children`.
    pub fn component_made<T>(slot: int, make: fn() -> T, setup: fn(T)) {
        let described: reflect.Type = type_of(T)
        if !self.children.contains_key(slot) {
            let fresh: T = make()
            self.children[slot] = reflect.value(fresh)
            self.log.push("{slot}: mounted {described.name()}")
        } else {
            self.log.push("{slot}: reused {described.name()}")
        }
        match self.children.get(slot) {
            some(stored) => {
                match stored.copy() as? T {
                    some(typed) => { setup(typed) }
                    none => { self.log.push("{slot}: as? T FAILED") }
                }
                match stored.copy() as? Node {
                    some(base) => {
                        self.log.push("{slot}: base says {base.tag()} rows={base.touched()}")
                    }
                    none => { self.log.push("{slot}: as? Node FAILED") }
                }
                self.log.push("{slot}: stored type is {stored.type().qualified_name()}")
            }
            none => { self.log.push("{slot}: missing") }
        }
    }
}

fn reflective(label: string, described: reflect.Type) {
    match described.initializer() {
        some(ctor) => {
            match ctor.call([]) {
                ok(made) => {
                    match made.copy() as? Node {
                        some(base) => { io.println("  {label}: CONSTRUCTED, base says {base.tag()}") }
                        none => { io.println("  {label}: CONSTRUCTED, as? Node FAILED") }
                    }
                }
                err(problem) => { io.println("  {label}: construct FAILED ({problem.message()})") }
            }
        }
        none => { io.println("  {label}: no initializer descriptor") }
    }
}

/// The other half of the decision: latte binds a page's `@param` from a route
/// REFLECTIVELY. A reflective field access on a field declared by a generic
/// type used to answer `ok` interpreted and `err unsupported` natively; beans
/// 0.1.41 fixed the divergence. This measures it directly rather than assuming.
fn field_probe(label: string, described: reflect.Type, receiver: reflect.Value,
               name: string) {
    match described.field(name) {
        some(field) => {
            let declared: string = field.declaring_type().qualified_name()
            let generic: bool = field.declaring_type().type_arguments().len() > 0
            match field.set(receiver.copy(), reflect.value("bound")) {
                ok(_) => {
                    match field.get(receiver.copy()) {
                        ok(read) => {
                            match read as? string {
                                some(text) => {
                                    io.println("  {label}.{name}: set+get OK -> \"{text}\"  (declared by {declared}, generic={generic})")
                                }
                                none => { io.println("  {label}.{name}: read is not a string") }
                            }
                        }
                        err(problem) => {
                            io.println("  {label}.{name}: get FAILED ({problem.message()})  (declared by {declared}, generic={generic})")
                        }
                    }
                }
                err(problem) => {
                    io.println("  {label}.{name}: set FAILED ({problem.message()})  (declared by {declared}, generic={generic})")
                }
            }
        }
        none => { io.println("  {label}.{name}: no such field") }
    }
}

fn main() {
    let host: Host = new Host()

    io.println("--- subject: a CLOSED GENERIC through a factory closure")
    // two renders at the same slot, because a mount that is never reused is
    // the n=1 shape that proves nothing
    host.component_made<Grid<int>>(7,
        fn() -> Grid<int> { return new Grid<int>() },
        fn(c: Grid<int>) { c.title = "orders"; c.rows = 3 })
    host.component_made<Grid<int>>(7,
        fn() -> Grid<int> { return new Grid<int>() },
        fn(c: Grid<int>) { c.rows = c.rows + 4 })

    io.println("--- C1: the same host method over a NON-GENERIC component")
    host.component_made<Hint>(9,
        fn() -> Hint { return new Hint() },
        fn(c: Hint) { c.title = "hi"; c.rows = 1 })
    host.component_made<Hint>(9,
        fn() -> Hint { return new Hint() },
        fn(c: Hint) { c.rows = c.rows + 4 })

    for line: string in host.log { io.println("  {line}") }

    io.println("--- C2/C3: the reflective route, for comparison")
    reflective("Hint       (control, non-generic)  ", type_of(Hint))
    reflective("OrderGrid  (generic base)          ", type_of(OrderGrid))
    reflective("Grid<int>  (closed generic)        ", type_of(Grid<int>))

    io.println("--- the @param hazard: a reflective field access, by declaring type")
    let plain: Hint = new Hint()
    field_probe("Hint      (control, non-generic)", type_of(Hint),
                reflect.value(plain), "title")
    let closed: Grid<int> = new Grid<int>()
    field_probe("Grid<int> (declared by a generic)", type_of(Grid<int>),
                reflect.value(closed), "title")
    let sub: OrderGrid = new OrderGrid()
    field_probe("OrderGrid (inherited from Grid<int>)", type_of(OrderGrid),
                reflect.value(sub), "title")

    io.println("--- is the fault the FIELD's declaring type, or the RECEIVER's?")
    let plain2: Hint = new Hint()
    field_probe("Hint      (non-generic receiver, base field)", type_of(Hint),
                reflect.value(plain2), "label")
    let closed2: Grid<int> = new Grid<int>()
    field_probe("Grid<int> (generic receiver, NON-generic base field)",
                type_of(Grid<int>), reflect.value(closed2), "label")
    let sub2: OrderGrid = new OrderGrid()
    field_probe("OrderGrid (generic ancestor, NON-generic base field)",
                type_of(OrderGrid), reflect.value(sub2), "label")

    io.println("--- what the base chain reports, which is how a scan would detect it")
    describe_chain("Hint", type_of(Hint))
    describe_chain("Grid<int>", type_of(Grid<int>))
    describe_chain("OrderGrid", type_of(OrderGrid))
}

fn describe_chain(label: string, start: reflect.Type) {
    var walk: Option<reflect.Type> = some(start)
    var line: string = "  {label}:"
    for true {
        match walk {
            some(t) => {
                line = "{line} {t.qualified_name()}(args={t.type_arguments().len()}) ->"
                walk = t.base_type()
            }
            none => { break }
        }
    }
    io.println("{line} .")
}
