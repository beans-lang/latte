// Does a still screen stop drawing? A page that repaints while nothing moves
// is invisible and costly. A scene at rest answers false to all three numbers.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.motion
import latte.platform
import latte.stage

pub class Fading extends compose.Component {
    pub on: bool = false

    pub fn init() { super.init() }

    pub fn flip() { self.on = !self.on; self.request_render() }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 12.0)
        b.number("spacing", 8.0)
        b.open("Label")
        b.text("A screen that is not moving")
        b.close()
        b.open("Box")
        b.number("width", 120.0)
        b.number("height", 48.0)
        b.open("Rectangle")
        b.word("fill", if self.on { "#365eea" } else { "#c7ccd8" })
        b.number("transition_seconds", 0.25)
        b.word("transition_easing", "ease_in_out")
        b.close()
        b.close()
        b.open("Button")
        b.text("Flip")
        b.on("click", fn(e: input.UiEvent) { self.flip() })
        b.close()
        b.close()
    }
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_idle_run" {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(320.0, 200.0))
    let view: Fading = new Fading()
    page.show(view).expect("show")

    rule("1 — the first frame paints, the second does not")

    io.println("painted on show: {page.refresh().expect("refresh")}")
    io.println("painted again with nothing changed: {page.refresh().expect("refresh")}")
    io.println("animations running: {page.has_active_animations()}")

    rule("2 — a change paints once and settles")

    view.flip()
    io.println("painted after the change: {page.refresh().expect("refresh")}")
    io.println("animations running: {page.has_active_animations()}")

    // The transition is 0.25s. Run it out one frame at a time and count how
    // many of them painted; then check that it really stopped.
    var painted: int = 0
    for step: int in 0..30 {
        if page.advance(1.0 / 60.0).expect("advance") { painted = painted + 1 }
    }
    io.println("frames that painted during a quarter-second fade: {painted > 8 && painted < 20}")
    io.println("animations after it finished: {page.has_active_animations()}")
    io.println("painted after it finished: {page.advance(1.0 / 60.0).expect("advance")}")

    rule("3 — an idle scene asks the host for no frames at all")

    // The clock is the other half. A scene that painted nothing but kept
    // asking for frames would still hold the GPU awake.
    platform.HostDesk.instance.reset()
    motion.ClockDesk.instance.reset()
    let clock: motion.FrameClock = new motion.FrameClock(page.root().handle(),
                                                         page.context().router())
    io.println("pending before anything joins: {motion.ClockDesk.instance.frame_pending()}")
    clock.start(1, fn(f: motion.Frame) {}).expect("start")
    io.println("pending with one listener: {motion.ClockDesk.instance.frame_pending()}")
    clock.stop().expect("stop")
    io.println("pending after the listener leaves: {motion.ClockDesk.instance.frame_pending()}")
    io.println("listeners on the scene: {motion.ClockDesk.instance.listeners_on(page.root().handle())}")

    page.close()
    return 0
}

fn main() { run() }
