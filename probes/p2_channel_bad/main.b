// The boundary of probe 2, stated as a program that must NOT compile.
//
// This file is checked, never run. `probes/p2_channel_bad/expected.txt` is the
// exact answer beansc 0.1.40 gives it; if a later compiler changes any of
// these the recorded answer in ANSWERS.md is stale.
//
//   probes/check_refusals.sh
package main

import std.io

class Component {
    pub count: int = 0
}

class Ctx {
    pub total: int = 0
}

fn main() {
    let inbox: Channel<send fn(Ctx)> = new Channel(4)

    // 1. A send closure may not capture a plain class reference. This is the
    //    one that decides the push handle's shape: a closure cannot carry the
    //    component it means to change, so the receiving fiber must pass it in.
    let owner: Component = new Component()
    inbox.send(fn(c: Ctx) { owner.count += 1 })

    // 2. try_send is not offered for a move-only element type, so an inbox of
    //    send closures has no non-blocking offer: `send` parks when the
    //    channel is full.
    let queued: bool = inbox.try_send(fn(c: Ctx) { c.total += 1 })

    // 3. A mutable local must be moved in, not aliased.
    var tally: int = 0
    inbox.send(fn(c: Ctx) { c.total += tally })

    io.println("unreachable")
}
