// Does mounting a scene and dropping it give everything back? Counted in
// objects, not bytes: a `deinit` that never runs is what actually leaks.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.stage

/// How many `Panel`s exist. A module-level counter rather than a field,
/// because the question is about objects nobody holds any more.
pub singleton class Census {
    pub live: int = 0
    pub made: int = 0
    fn init() {}
    pub fn born() { self.live = self.live + 1; self.made = self.made + 1 }
    pub fn died() { self.live = self.live - 1 }
}

pub class Panel extends compose.Component {
    pub rows: int = 12
    pub clicks: int = 0

    pub fn init() {
        super.init()
        Census.instance.born()
    }

    fn deinit() { Census.instance.died() }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 6.0)
        b.number("spacing", 4.0)
        for row: int in 0..self.rows {
            b.open("HStack")
            b.number("spacing", 8.0)
            b.open("Label")
            b.text("row {row}")
            b.close()
            b.open("Button")
            b.text("edit {row}")
            // A closure over `self`, the shape that makes a leak possible:
            // handler holds component, router holds handler, scene holds router.
            b.on("click", fn(e: input.UiEvent) { self.clicks = self.clicks + 1 })
            b.close()
            b.close()
        }
        b.close()
    }
}

/// Builds a scene, drives it, drops it. Everything is local, so anything that
/// survives the call was kept by something else — which is the question.
fn one_round() {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(400.0, 600.0))
    page.show(new Panel()).expect("show")
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(60.0, 24.0), 1, 1, 0)
        .expect("press")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(60.0, 24.0), 1, 1, 0)
        .expect("release")
    page.resize(geometry.Size.of(420.0, 620.0), 2.0).expect("resize")
    page.close()
}

pub extern "C" fn run() -> i32 as "latte_heap_run" {
    let start: int = Census.instance.live
    for round: int in 0..30 { one_round() }
    let after: int = Census.instance.live

    io.println("panels built: {Census.instance.made}")
    io.println("panels still alive: {after - start}")
    // 30 mounts that each hold a closure over their component, and none of
    // them outlives its scene.
    io.println("every panel released: {after == start}")
    return if after == start { 0 } else { 1 }
}

fn main() { run() }
