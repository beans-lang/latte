// Who gets told about a frame.
//
// A page has one `requestAnimationFrame` and two things that want it: the
// scene, which advances its own transitions, and `motion.FrameClock`, which is
// what a program uses to move something of its own. Wiring one and not the
// other is the kind of fault that reads as "animation does not work on the
// web" — everything built into a control moves, and nothing an application
// wrote does.
//
// `platform.HeadlessHost` is the clock here: `advance(seconds)` runs whatever
// asked for a frame and nothing else, so the question is answerable with no
// browser at all.
package main

import std.io
import latte.geometry
import latte.headless
import latte.input
import latte.motion
import latte.platform
import latte.stage

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_frames_run" {
    platform.HostDesk.instance.reset()
    motion.ClockDesk.instance.reset()
    let clock_host: platform.HeadlessHost = new platform.HeadlessHost()
    platform.HostDesk.instance.install(clock_host)

    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(200.0, 120.0))
    let router: input.EventRouter = page.context().router()

    rule("1 — a clock with no listener asks for nothing")

    io.println("pending: {motion.ClockDesk.instance.frame_pending()}")

    rule("2 — one listener asks once, and is told once per frame")

    var ticks: int = 0
    var seen: List<string> = []
    let clock: motion.FrameClock = new motion.FrameClock(page.root().handle(), router)
    clock.start(7, fn(f: motion.Frame) {
        ticks = ticks + 1
        seen.push("#{f.number} token {f.token}")
    }).expect("start")
    io.println("pending after joining: {motion.ClockDesk.instance.frame_pending()}")

    for frame: int in 0..3 { clock_host.advance(1.0 / 60.0) }
    io.println("ticks: {ticks}")
    io.println("frames: {seen.join(", ")}")
    io.println("still pending: {motion.ClockDesk.instance.frame_pending()}")

    rule("3 — a second listener shares the same frame")

    var other: int = 0
    let second: motion.FrameClock = new motion.FrameClock(page.root().handle(), router)
    second.start(9, fn(f: motion.Frame) { other = other + 1 }).expect("start")
    let before: int = ticks
    clock_host.advance(1.0 / 60.0)
    io.println("the first heard {ticks - before} more, the second {other}")

    rule("4 — the token is each listener's own")

    io.println("the first listener's frames carry its own token: {seen[0].contains("token 7")}")

    rule("5 — when the last listener leaves, nothing is asked for")

    clock.stop().expect("stop")
    io.println("pending with one left: {motion.ClockDesk.instance.frame_pending()}")
    second.stop().expect("stop")
    io.println("pending with none: {motion.ClockDesk.instance.frame_pending()}")
    io.println("listeners: {motion.ClockDesk.instance.listeners_on(page.root().handle())}")

    // And a frame delivered after everyone left reaches nobody.
    let after: int = ticks + other
    clock_host.advance(1.0 / 60.0)
    io.println("ticks after everyone left: {ticks + other - after}")

    page.close()
    motion.ClockDesk.instance.reset()
    platform.HostDesk.instance.reset()
    return 0
}

fn main() { run() }
