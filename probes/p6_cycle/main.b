// Probe 6 — a closure capturing `self`, returned from a method and stored.
//
// This is latte's event handler:
//
//     b.on_click(9, fn(e: MouseEvent) { self.count += 1 })
//
// The closure captures the component; the frame that holds it is owned by the
// renderer; the renderer owns the component. A cycle either way. PLAN.md
// answers it with "component back-edges, Callback owners and signal
// subscribers are weak — the leaks gate is what proves it, not the argument",
// so this probe runs the argument and then runs `leaks`.
//
// Five shapes, each 5,000 components made and dropped. What is counted is how
// many `deinit` bodies ran BEFORE the program ended, because the runtime forces
// a cycle sweep at exit (`cc_at_exit`) and a circuit that runs for hours never
// reaches it. A shape that only cleans up at exit is a leak in a server.
package main

import std.io

const MANY: int = 5000

// Not part of any cycle: every component points at it, it points at nobody.
class Ledger {
    pub made: int = 0
    pub gone: int = 0
    pub fn init() {}
    pub fn reset() { self.made = 0; self.gone = 0 }
    pub fn live() -> int { return self.made - self.gone }
}

// ------------------------------------------------------------- the component
class Comp {
    ledger: Ledger
    pub count: int = 0
    // The handler table a rendered frame keeps. A default that captures
    // nothing, so an unarmed component is the control.
    pub handler: fn(int) = fn(x: int) {}
    pub fn init(ledger: Ledger) {
        self.ledger = ledger
        ledger.made += 1
    }
    fn deinit() { self.ledger.gone += 1 }
    // The event handler as latte writes it: the closure captures `self`.
    pub fn arm() { self.handler = fn(x: int) { self.count += x } }
}

// PLAN.md's Callback: the closure plus a WEAK reference to the component that
// supplied it, so invoking it can mark that component dirty.
class Callback {
    pub weak owner: Option<Comp> = none
    pub call: fn(int) = fn(x: int) {}
    pub fn init() {}
    pub fn fire(amount: int) { self.call(amount) }
}

// A component that hands a Callback to a child, which is the shape a parent
// passes `on_pick={fn(id: int) { self.select(id) }}` down in.
class Parent {
    ledger: Ledger
    pub child: Option<Callback> = none
    pub paramchild: Option<ParamCallback> = none
    pub picked: int = 0
    pub fn init(ledger: Ledger) {
        self.ledger = ledger
        ledger.made += 1
    }
    fn deinit() { self.ledger.gone += 1 }
}

// ------------------------------------------------------------- the five shapes
//
// 1. no closure at all — the control.
fn shape_plain(ledger: Ledger) {
    for round: int in 0..MANY {
        let c: Comp = new Comp(ledger)
        c.count += 1
    }
}

// 2. a closure capturing self, stored in the component's own field.
fn shape_self_capture(ledger: Ledger) {
    for round: int in 0..MANY {
        let c: Comp = new Comp(ledger)
        c.arm()
        c.handler(1)
    }
}

// 3. the closure lives OUTSIDE the component, in a list that outlives the
//    loop body — the renderer's frame table.
fn shape_frames(ledger: Ledger, frames: List<fn(int)>) {
    for round: int in 0..MANY {
        let c: Comp = new Comp(ledger)
        c.arm()
        frames.push(c.handler)
    }
}

// 4. PLAN.md's Callback: weak owner, and a closure that still captures self.
fn shape_weak_owner_strong_closure(ledger: Ledger) {
    for round: int in 0..MANY {
        let c: Comp = new Comp(ledger)
        let cb: Callback = new Callback()
        cb.owner = some(c)
        cb.call = fn(x: int) { c.count += x }
        cb.fire(1)
    }
}

// 5. the same Callback held by a PARENT, which is where it really lives.
// 6. the contrast that decides the Callback shape: the parent still holds the
//    Callback, but the closure captures NOTHING — it takes the component as a
//    parameter, the way a posted job does (probe 2). There is no strong cycle
//    at all, so release does not wait for a collector.
class ParamCallback {
    pub weak owner: Option<Parent> = none
    pub call: fn(Parent, int) = fn(p: Parent, x: int) {}
    pub fn init() {}
    pub fn fire(amount: int) {
        match self.owner {
            some(p) => { self.call(p, amount) }
            none => {}
        }
    }
}

fn shape_no_capture(ledger: Ledger) {
    for round: int in 0..MANY {
        let p: Parent = new Parent(ledger)
        let cb: ParamCallback = new ParamCallback()
        cb.owner = some(p)
        cb.call = fn(owner: Parent, x: int) { owner.picked += x }
        p.paramchild = some(cb)
        cb.fire(1)
    }
}

fn shape_parent_holds_callback(ledger: Ledger) {
    for round: int in 0..MANY {
        let p: Parent = new Parent(ledger)
        let cb: Callback = new Callback()
        cb.owner = none
        cb.call = fn(x: int) { p.picked += x }
        p.child = some(cb)
        cb.fire(1)
    }
}

// Cyclic garbage of a class the ledger never sees, made and dropped in bulk so
// the runtime's cycle threshold is crossed and a sweep is due. This is what
// separates "the collector has not got to it yet" from "the collector never
// will" — without it every shape below reads as a leak for the first moment
// after the loop, and with it a shape that still reads live is really live.
class Churn {
    pub self_ref: Option<Churn> = none
    pub hold: fn(int) = fn(x: int) {}
    pub tally: int = 0
    pub fn init() {}
}

fn churn(rounds: int) {
    for round: int in 0..rounds {
        let junk: Churn = new Churn()
        junk.self_ref = some(junk)
        junk.hold = fn(x: int) { junk.tally += x }
        junk.hold(1)
    }
}

// `want_immediate` is the difference the design turns on: a shape with no
// strong cycle releases everything straight away, and one with a cycle needs
// the collector. A run where a cyclic shape suddenly released immediately, or
// where an acyclic one stopped, is a changed answer either way.
fn report(label: string, ledger: Ledger, want_immediate: bool) -> bool {
    let before: int = ledger.gone
    churn(20000)
    io.println("{label}: made {ledger.made}, deinit ran {before} straight away, {ledger.gone} after a forced sweep, still live {ledger.live()}")
    if ledger.live() != 0 { return false }
    if want_immediate { return before == ledger.made }
    return true
}

// 7. the other half of what `weak` buys, which is not about leaks at all: a
//    Callback fired after its owner is gone must find `none` and do nothing,
//    rather than marking a dead component dirty. `weak` reads `none` from the
//    first moment of the referent's death, before its deinit body runs.
fn weak_zeroes(ledger: Ledger) -> string {
    let cb: ParamCallback = new ParamCallback()
    var alive_before: bool = false
    make_and_drop(ledger, cb)
    match cb.owner {
        some(p) => { return "still some after the owner died" }
        none => {}
    }
    // Firing it now must be a no-op rather than a fault.
    cb.fire(1)
    return "none, and firing it was a no-op"
}

fn make_and_drop(ledger: Ledger, cb: ParamCallback) {
    let p: Parent = new Parent(ledger)
    cb.owner = some(p)
    cb.call = fn(owner: Parent, x: int) { owner.picked += x }
    cb.fire(1)
    match cb.owner {
        some(alive) => { if alive.picked != 1 { io.println("weak read wrong") } }
        none => { io.println("weak read none while the owner was alive") }
    }
}

fn main() {
    let ledger: Ledger = new Ledger()

    shape_plain(ledger)
    let one: bool = report("1 no closure                       ", ledger, true)
    ledger.reset()

    shape_self_capture(ledger)
    let two: bool = report("2 closure captures self, own field ", ledger, false)
    ledger.reset()

    var frames: List<fn(int)> = []
    shape_frames(ledger, frames)
    // Held by a live list: nothing may be released, and the churn must not
    // free them either.
    churn(20000)
    let held: bool = ledger.gone == 0 && ledger.live() == MANY
    io.println("3 closure in an outside frame list : made {ledger.made}, deinit ran {ledger.gone} after a forced sweep, still live {ledger.live()}")
    frames.clear()
    let three: bool = report("3 after the frame list is cleared  ", ledger, false)
    ledger.reset()

    shape_weak_owner_strong_closure(ledger)
    let four: bool = report("4 weak owner, closure captures self", ledger, true)
    ledger.reset()

    shape_parent_holds_callback(ledger)
    let five: bool = report("5 parent holds a callback to itself", ledger, false)
    ledger.reset()

    shape_no_capture(ledger)
    let six: bool = report("6 same, but the closure captures no", ledger, true)
    ledger.reset()

    let verdict: string = weak_zeroes(ledger)
    io.println("7 a weak owner after its owner died: {verdict}")
    io.println("7 the owner really was released:     {ledger.live() == 0}")
    let seven: bool = verdict == "none, and firing it was a no-op" && ledger.live() == 0
    if one && two && held && three && four && five && six && seven {
        io.println("probe p6_cycle: ok")
    } else {
        io.println("probe p6_cycle: FAILED 1={one} 2={two} held={held} 3={three} 4={four} 5={five} 6={six} 7={seven}")
    }
}
