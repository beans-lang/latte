// Probe 2 — a Channel of send closures, invoked on another fiber.
//
// This is latte's cross-thread push handle (PLAN.md: "Any other thread reaches
// the circuit by posting a send closure to the inbox"). The question is
// whether a closure can be built on one OS thread, crossed to a fiber that
// owns the component state, and invoked there against state the sender never
// had a reference to.
//
// The shape:
//
//   main worker                          a real OS thread
//   -----------                          ----------------
//   let ctx = new Ctx()                  builds `send fn(Ctx)` closures
//   brew pump(inbox, ctx, n)             inbox.send(job) for each
//   pump parks in inbox.receive()
//   ... job(ctx) runs HERE
//
// `Ctx` is a plain class and plain class references are not Send, so the
// sender cannot capture it — the closure can only reach it because the
// receiver passes it in. That is what makes "it ran on the receiving fiber"
// a fact rather than a hope.
package main

import std.io
import std.thread

class Ctx {
    pub total: int = 0
    pub notes: List<string> = []
    pub bytes_seen: int = 0
}

// The inbox pump. Runs on a brewed fiber; `receive` parks it.
fn pump(inbox: Channel<send fn(Ctx)>, ctx: Ctx, count: int) -> int {
    var ran: int = 0
    for ran < count {
        match inbox.receive() {
            some(job) => { job(ctx); ran += 1 }
            none => { return ran }
        }
    }
    return ran
}

// `brew` is legal only at a function's own scope.
fn circuit(inbox: Channel<send fn(Ctx)>, ctx: Ctx, count: int) -> int {
    let reader: Brew<int> = brew pump(inbox, ctx, count)
    match reader.join() {
        ok(ran) => { return ran }
        err(e) => { return -1 }
    }
}

// ------------------------------------------------------------ a bounded inbox
//
// `try_send` is not offered for a move-only element type (see
// probes/p2_channel_bad/), so a full inbox parks the posting thread rather
// than refusing. PLAN.md's "inbox depth per circuit ... crossing one ends the
// circuit with a bye, never a panic" therefore needs the depth kept beside the
// channel. An AtomicInt claimed before the send is enough, and it is what this
// phase proves: the receiver is not started at all, the channel fills, and the
// posts past the cap are refused without anyone parking.
fn bounded(inbox: Channel<send fn(Ctx)>, depth: AtomicInt, cap: int,
           total: int) -> int {
    var refused: int = 0
    for index: int in 0..total {
        if depth.add_and_get(1) > cap {
            let released: int = depth.add_and_get(-1)
            refused += 1
        } else {
            inbox.send(fn(c: Ctx) { c.total += 1 })
        }
    }
    return refused
}

fn drain_all(inbox: Channel<send fn(Ctx)>, ctx: Ctx, depth: AtomicInt) -> int {
    // try_receive never parks, so the circuit fiber can empty its inbox in one
    // pass and get back to rendering.
    var ran: int = 0
    var more: bool = true
    for more {
        match inbox.try_receive() {
            some(job) => { job(ctx); let left: int = depth.add_and_get(-1); ran += 1 }
            none => { more = false }
        }
    }
    return ran
}

fn main() {
    let inbox: Channel<send fn(Ctx)> = new Channel(4)
    let ctx: Ctx = new Ctx()
    let count: int = 6

    let poster: Thread<int> = thread.spawn(fn() -> int {
        var posted: int = 0
        for index: int in 1..count + 1 {
            // Captures: an int and a string, both Send and both copied into
            // the closure. A distinct payload per job, so a channel that
            // delivered one job twice would show up in the total.
            let label: string = "job-{index}"
            let owned: Bytes = Bytes.filled(index, 65)
            inbox.send(fn(c: Ctx) move(owned) {
                c.total += index * index
                c.notes.push(label)
                c.bytes_seen += owned.len()
            })
            posted += 1
        }
        return posted
    })

    let ran: int = circuit(inbox, ctx, count)
    let posted: int = poster.join()

    // 1..6 squared is 91; 1..6 summed is 21.
    io.println("the sender posted every job: {posted == count}")
    io.println("the receiving fiber ran every job: {ran == count}")
    io.println("each job ran exactly once: {ctx.total == 91}")
    io.println("a moved Bytes capture survived the crossing: {ctx.bytes_seen == 21}")
    io.println("string captures arrived in order: {ctx.notes.len() == count && ctx.notes[0] == "job-1" && ctx.notes[count - 1] == "job-{count}"}")
    inbox.close()

    // The bounded inbox, with no receiver running at all: the channel holds 4,
    // the cap is 4, and 10 posts are attempted. A poster that parked would
    // hang here, so reaching the next line is itself part of the answer.
    let cap: int = 4
    let bound: Channel<send fn(Ctx)> = new Channel(cap)
    let depth: AtomicInt = new AtomicInt(0)
    let refused: int = bounded(bound, depth, cap, 10)
    let sink: Ctx = new Ctx()
    let drained: int = drain_all(bound, sink, depth)
    io.println("a full inbox refused the overflow instead of parking: {refused == 6}")
    io.println("everything under the cap was kept: {drained == cap && sink.total == cap}")
    io.println("the depth returned to zero: {depth.load() == 0}")
    bound.close()

    let all_ok: bool = posted == count && ran == count && ctx.total == 91 &&
        ctx.bytes_seen == 21 && ctx.notes.len() == count &&
        ctx.notes[0] == "job-1" && refused == 6 && drained == cap &&
        sink.total == cap && depth.load() == 0
    if all_ok { io.println("probe p2_channel: ok") }
    else { io.println("probe p2_channel: FAILED") }
}
