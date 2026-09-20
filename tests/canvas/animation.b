// A transition, frame by frame, by value.
//
// `tests/canvas/idle.b` counts the frames a fade paints and asserts the clock
// stops afterwards. That is a check on the *schedule* — it would pass for an
// animation that jumped straight to the end and then idled for a quarter of a
// second.
//
// This asks what the value was on the way. `Scene.advance(seconds)` is a
// deterministic clock, so a fade can be stepped and read at each frame, and
// the numbers below are the ones an eased curve really produces: slow, fast,
// slow, and exactly at the destination on the last frame and not before.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.platform
import latte.scene
import latte.stage
import latte.visual

pub class Fade extends compose.Component {
    pub lit: bool = false
    pub straight: bool = false

    pub fn init() { super.init() }

    pub override fn render(b: compose.Builder) {
        b.open("Box")
        b.number("width", 120.0)
        b.number("height", 48.0)
        b.open("Rectangle")
        // A corner radius rather than a colour: one number to follow, and a
        // colour would be four interleaved tweens printed as one packed
        // integer.
        b.number("clip_radius", if self.lit { 24.0 } else { 0.0 })
        b.number("transition_seconds", 0.25)
        b.word("transition_easing", if self.straight { "linear" } else { "ease_in_out" })
        b.close()
        b.close()
    }
}

/// The drawing node under the root.
fn shape_of(node: scene.RenderObject) -> Option<scene.VisualRender> {
    match node as? scene.VisualRender {
        some(found) => { return some(found) }
        none => {}
    }
    for index: int in 0..node.child_count() {
        match node.child_at(index) {
            some(child) => {
                match shape_of(child) {
                    some(found) => { return some(found) }
                    none => {}
                }
            }
            none => {}
        }
    }
    match node.visual() {
        some(visual) => { return shape_of(visual) }
        none => { return none }
    }
}

/// Two decimal places, so a golden is about the curve and not about the last
/// bit of a double.
fn rounded(value: f64) -> string {
    let hundredths: int = (value * 100.0 + 0.5) as int
    return "{hundredths / 100}.{if hundredths % 100 < 10 { "0" } else { "" }}{hundredths % 100}"
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

/// Steps a quarter-second transition and prints the value at every frame.
fn trace(page: stage.Scene, shape: scene.VisualRender) -> string {
    var steps: List<string> = []
    for frame: int in 0..17 {
        steps.push(rounded(shape.real(visual.CLIP_RADIUS).expect("opacity")))
        page.advance(1.0 / 60.0).expect("advance")
    }
    return steps.join(" ")
}

pub extern "C" fn run() -> i32 as "latte_animation_run" {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(200.0, 100.0))
    let fade: Fade = new Fade()
    match page.show(fade) {
        ok(_) => {}
        err(problem) => { io.println("refused: {problem.msg}"); return 1 }
    }
    let shape: scene.VisualRender =
        shape_of(page.root().render_object().expect("root")).expect("a drawing node")

    rule("1 — the first value is the one it was given, not the one it is going to")

    io.println("at rest: {rounded(shape.real(visual.CLIP_RADIUS).expect("opacity"))}")
    io.println("animating: {shape.animating()}")

    rule("2 — an eased fade is slow, fast, slow")

    fade.lit = true
    fade.request_render()
    page.refresh().expect("refresh")
    io.println("frames: {trace(page, shape)}")
    io.println("at the end: {rounded(shape.real(visual.CLIP_RADIUS).expect("opacity"))}")
    io.println("still animating: {shape.animating()}")

    rule("3 — a linear fade is a straight line")

    fade.straight = true
    fade.lit = false
    fade.request_render()
    page.refresh().expect("refresh")
    io.println("frames: {trace(page, shape)}")
    io.println("at the end: {rounded(shape.real(visual.CLIP_RADIUS).expect("opacity"))}")

    rule("4 — a change mid-flight starts from where it is, not from where it began")

    fade.lit = true
    fade.request_render()
    page.refresh().expect("refresh")
    for frame: int in 0..7 { page.advance(1.0 / 60.0).expect("advance") }
    let caught: f64 = shape.real(visual.CLIP_RADIUS).expect("opacity")
    io.println("caught halfway at {rounded(caught)}")
    fade.lit = false
    fade.request_render()
    page.refresh().expect("refresh")
    let turned: f64 = shape.real(visual.CLIP_RADIUS).expect("opacity")
    io.println("after turning round, still at {rounded(turned)}")
    io.println("it did not jump: {turned == caught}")
    io.println("frames back down: {trace(page, shape)}")

    page.close()
    return 0
}

fn main() { run() }
