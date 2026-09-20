// What a control costs to put on a screen, counted in reflection rather than
// milliseconds — a timing assertion pins this laptop. See `compose.PlanDesk`.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.stage

pub class Buttons extends compose.Component {
    pub rows: int = 1
    pub fn init() { super.init() }
    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        for row: int in 0..self.rows {
            b.open("Button")
            b.text("row {row}")
            b.close()
        }
        b.close()
    }
}

fn mount(count: int) {
    let view: Buttons = new Buttons()
    view.rows = count
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(400.0, 2000.0))
    page.show(view).expect("show")
    page.close()
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_mount_cost_run" {
    compose.PlanDesk.instance.reset()

    rule("1 — the first screen scans the types it uses")

    mount(1)
    let first: int = compose.PlanDesk.instance.scanned()
    io.println("types scanned by one button: {first > 0}")

    rule("2 — a second button of the same type scans nothing")

    mount(1)
    io.println("after a second screen: {compose.PlanDesk.instance.scanned() - first}")

    rule("3 — and neither do sixteen")

    mount(16)
    io.println("after sixteen buttons: {compose.PlanDesk.instance.scanned() - first}")

    rule("4 — nor thirty screens")

    for round: int in 0..30 { mount(4) }
    io.println("after thirty more screens: {compose.PlanDesk.instance.scanned() - first}")

    rule("5 — a type nobody has used yet is scanned when it is")

    let before: int = compose.PlanDesk.instance.scanned()
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(400.0, 300.0))
    page.show(new Slider()).expect("show")
    page.close()
    io.println("a new control scanned more: {compose.PlanDesk.instance.scanned() > before}")

    compose.PlanDesk.instance.reset()
    return 0
}

pub class Slider extends compose.Component {
    pub fn init() { super.init() }
    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.open("Slider")
        b.number("min", 0.0)
        b.number("max", 10.0)
        b.number("value", 5.0)
        b.close()
        b.close()
    }
}

fn main() { run() }
