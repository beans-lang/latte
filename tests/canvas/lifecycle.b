// Stage 2's proof: a component with state, a handler and a layout pass, mounted
// and unmounted over and over.
//
// It is deliberately written in Beans rather than in `.bx`. The markup compiler
// is a separate thing that can be wrong on its own, and this file exists to say
// whether the *runtime* works — so it uses the Builder calls a generated
// component would produce and nothing else.
//
// One file, three backends. `main` is what the interpreter and the native
// binary run; `latte_stage2_run` is the same body, exported so a browser can
// call it out of a WebAssembly module. The three outputs are diffed against
// one golden, which is the only way to find out that a backend disagrees —
// and one backend disagreeing with another is what nearly every real fault in
// this workspace has turned out to be.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.scene
import latte.stage

pub class Counter extends compose.Component {
    pub count: int = 0
    pub label: string = "nothing yet"
    pub renders: int = 0

    pub fn init() { super.init() }

    fn bump(event: input.UiEvent) {
        self.count = self.count + 1
        self.label = "clicked {self.count}"
        self.request_render()
    }

    pub override fn render(b: compose.Builder) {
        self.renders = self.renders + 1
        b.open("VStack")
        b.number("padding", 8.0)
        b.number("spacing", 6.0)
        b.open("Label")
        b.text(self.label)
        b.number("font_size", 13.0)
        b.close()
        b.open("Button")
        b.text("Add one")
        b.on("click", fn(e: input.UiEvent) { self.bump(e) })
        b.close()
        b.close()
    }
}

/// The middle of the first node with this role, in scene coordinates.
fn centre_of(page: stage.Scene, role: string) -> Option<geometry.Point> {
    for node: scene.SemanticsNode in page.semantics() {
        if node.role() == role {
            let box: geometry.Rect = node.bounds()
            return some(geometry.Point.at(box.x + box.width / 2.0,
                                          box.y + box.height / 2.0))
        }
    }
    return none
}

fn frame_of(page: stage.Scene, role: string) -> string {
    for node: scene.SemanticsNode in page.semantics() {
        if node.role() == role {
            let box: geometry.Rect = node.bounds()
            return "{box.x as int},{box.y as int} {box.width as int}x{box.height as int}"
        }
    }
    return "missing"
}

pub extern "C" fn run() -> i32 as "latte_stage2_run" {
    let renderer: headless.MetricRenderer = new headless.MetricRenderer()
    var page: stage.Scene = new stage.Scene(renderer, geometry.Size.of(320.0, 160.0))
    let counter: Counter = new Counter()
    page.show(counter).expect("show the counter")

    io.println("renders after show: {counter.renders}")
    io.println("label: {counter.label}")
    // A layout pass really ran: the button is below the label, which only
    // happens if the stack measured both and placed them.
    io.println("label frame: {frame_of(page, "text")}")
    io.println("button frame: {frame_of(page, "button")}")

    // The click goes through the scene the way a real one does — hit test,
    // route, handler, re-render — not by calling `bump` directly.
    match centre_of(page, "button") {
        none => { io.println("no button to click") }
        some(where) => {
            page.pointer(input.EventKind.pointer_down, where, 1, 1, 0).expect("press")
            page.pointer(input.EventKind.pointer_up, where, 1, 1, 0).expect("release")
        }
    }
    io.println("after one click: {counter.label}")

    // Every handler the component registered must go when the scene does.
    io.println("handlers while mounted: {page.context().router().registered() > 0}")
    page.close()
    io.println("handlers after close: {page.context().router().registered()}")
    io.println("closed: {page.is_closed()}")

    // Mount and unmount many times. What this asserts is that nothing is kept:
    // a scene that held on to its controls would show a rising handler count
    // on the next one, because the router is per scene and a leaked one would
    // still be subscribed.
    var last: int = 0
    for round: int in 0..25 {
        let again: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                                 geometry.Size.of(320.0, 160.0))
        again.show(new Counter()).expect("show")
        last = again.context().router().registered()
        again.close()
    }
    io.println("handlers on the 25th mount: {last}")
    return 0
}

fn main() { run() }
