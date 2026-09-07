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
import std.time

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

// ------------------------------------------------------------------ the cost
//
// `component<T>` sits inside `render`, so its cost is paid on every render of
// every parent that holds a child component — not once at mount. Two numbers
// decide whether the reflective spelling is affordable:
//
//   mount  — activate through type_of(T).initializer(), the first render only
//   render — reach type_of(T) and dispatch to an already-mounted child
//
// against the same two through a factory closure the markup compiler could
// emit instead, since it knows the concrete type at the call site.
// These live on a class rather than at package scope on purpose: a FREE
// generic function with a `fn(T)` parameter type-checks and runs but cannot be
// built natively (BLOCKERS.md, B3). The same signature as a method emits.
class Bench {
    pub fn init() {}

    pub fn reflect_mount<T>(rounds: int, setup: fn(T)) -> int {
    let described: reflect.Type = type_of(T)
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match described.initializer() {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => {
                        match made as? T {
                            some(instance) => { setup(instance); kept += 1 }
                            none => {}
                        }
                    }
                    err(e) => {}
                }
            }
            none => {}
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
    }

    // The real per-render cost of `component<T>`: the mounted child is kept as
    // the reflect.Value its activation produced (BLOCKERS.md B6 says a
    // re-boxed Component loses its type), so every render downcasts it twice —
    // once to T for the setter, once to Component for the render call.
    pub fn reflect_reuse<T>(rounds: int, setup: fn(T)) -> int {
        match type_of(T).initializer() {
            some(ctor) => {
                match ctor.call([]) {
                    ok(mounted) => {
                        var kept: int = 0
                        let t0: int = time.monotonic_nanos()
                        for round: int in 0..rounds {
                            match mounted.copy() as? T {
                                some(typed) => { setup(typed); kept += 1 }
                                none => {}
                            }
                            match mounted.copy() as? Component {
                                some(based) => { kept += 1 }
                                none => {}
                            }
                        }
                        let spent: int = time.monotonic_nanos() - t0
                        if kept != rounds * 2 { return -1 }
                        return spent / rounds
                    }
                    err(e) => { return -1 }
                }
            }
            none => { return -1 }
        }
    }

    // The per-render half: reach the descriptor and identify it, which is all
    // a mounted child needs before its render call.
    pub fn reflect_identify<T>(rounds: int) -> int {
    var total: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        let described: reflect.Type = type_of(T)
        total += described.qualified_name().len()
    }
    let spent: int = time.monotonic_nanos() - t0
    if total <= 0 { return -1 }
    return spent / rounds
    }
}

fn bench_factory_mount(rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        let made: Hint = new Hint()
        made.label = "keep going"
        made.tone = 3
        kept += 1
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

fn bench_direct_render(rounds: int, b: Builder) -> int {
    let mounted: Hint = new Hint()
    mounted.label = "x"
    let based: Component = mounted
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        based.render(b)
        b.out = ""
    }
    let spent: int = time.monotonic_nanos() - t0
    return spent / rounds
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

    let rounds: int = 20000
    let scratch: Builder = new Builder()
    let bench: Bench = new Bench()
    // A discarded warm pass first. Measured on this machine, the first pass of
    // any of these reads 2x slow — the earlier recorded 2,420 ns for a
    // reflective mount was that artifact, and the warm number is ~1,110.
    // Probe 5 pays the same tax and warms the same way.
    let warm_mount: int = bench.reflect_mount<Hint>(rounds, fn(h: Hint) { h.tone = 1 })
    let warm_identify: int = bench.reflect_identify<Hint>(rounds)
    let warm_reuse: int = bench.reflect_reuse<Hint>(rounds, fn(h: Hint) { h.tone = 1 })
    let warm_factory: int = bench_factory_mount(rounds)
    let warm_render: int = bench_direct_render(rounds, scratch)
    let reflect_mount: int = bench.reflect_mount<Hint>(rounds, fn(h: Hint) {
        h.label = "keep going"
        h.tone = 3
    })
    let reflect_identify: int = bench.reflect_identify<Hint>(rounds)
    let reflect_reuse: int = bench.reflect_reuse<Hint>(rounds, fn(h: Hint) {
        h.label = "keep going"
        h.tone = 3
    })
    let factory_mount: int = bench_factory_mount(rounds)
    let direct_render: int = bench_direct_render(rounds, scratch)
    // Measurements, not claims: these differ per backend by design, and the
    // native leg is the one that decides. The interpreter's numbers are
    // dominated by interpretation — its plain `new Hint()` costs 10 us — so
    // read them as an upper bound on the edit loop, not as latte's cost.
    io.println("ns/op  reflective mount {reflect_mount}  type_of(T) identify {reflect_identify}  reuse a mounted child {reflect_reuse}  new+set {factory_mount}  a mounted child's render {direct_render}")
    io.println("200 children: {reflect_mount * 200 / 1000} us to mount reflectively, {factory_mount * 200 / 1000} us with new; {(reflect_identify + reflect_reuse) * 200 / 1000} us to reach and reuse them on a later render")

    // The recorded answer includes the three refusals, so a run where the
    // generic component suddenly activated fails here — which is what must
    // happen, because BLOCKERS.md B1 and probes/BUILDER.md would be stale.
    let all_ok: bool =
        first == "ok" && second == "ok" && third == "ok" &&
        distinct(r, b) &&
        sixth == "no zero-argument initializer on Grid" &&
        fourth == "activate failed: wrong reflected argument count" &&
        fifth == "NotAComponent is not a Component" &&
        reflect_mount > 0 && reflect_identify > 0 && reflect_reuse > 0 &&
        factory_mount > 0 && direct_render > 0 &&
        warm_mount > 0 && warm_identify > 0 && warm_reuse > 0 &&
        warm_factory > 0 && warm_render > 0 &&
        // the shape of the answer, not only the numbers: reaching a mounted
        // child must stay far cheaper than activating one
        reflect_reuse < reflect_mount && reflect_identify < reflect_reuse
    if all_ok { io.println("probe p3_generic: ok") }
    else { io.println("probe p3_generic: FAILED") }
}
