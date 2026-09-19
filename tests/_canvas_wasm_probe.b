package main
import latte.geometry
import latte.paint
import latte.layout
import latte.input
import latte.visual
import latte.motion
import latte.platform
import latte.scene
import latte.controls
import latte.compose
import latte.headless

pub extern "C" fn probe() -> i32 as "latte_probe" {
    let r: headless.MetricRenderer = new headless.MetricRenderer()
    match r.paragraph("hello", 13.0, 0.0, 0) {
        ok(p) => { return p.size().width as i32 }
        err(_) => { return -1 }
    }
}
