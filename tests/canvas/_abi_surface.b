// Every import a Latte module can have, in one module.
//
// Scratch to the suite loop (a leading underscore), and a build target to
// `tools/wasm_abi.sh`. Its job is to *reference* each import so the linker
// keeps it: an unreferenced `extern "C"` is not in the import table, so a
// module that happened to use only half of them would let the other half drift
// away from the JavaScript loader unnoticed.
//
// It is never run. Calling these outside a browser would reach functions that
// do not exist.
//
// Both halves of the boundary are here: the page's own services, and the
// drawing surface. They are separate Beans packages and one WebAssembly import
// table, so one file has to name them all.
package main

import latte.browser
import latte.canvaskit
import latte.link
import latte.paint
import latte.platform
import latte.geometry
import latte.stage
import latte.headless

pub extern "C" fn surface() -> i32 as "latte_abi_surface" {
    let host: browser.BrowserHost = browser.PageHost.instance.install()
    var touched: int = 0
    for what: platform.Capability in platform.Capability.all() {
        if host.can(what) { touched = touched + 1 }
    }
    if host.appearance() == platform.Appearance.dark { touched = touched + 1 }
    touched = touched + host.scale() as int
    if host.reduce_motion() { touched = touched + 1 }
    touched = touched + host.now_nanos()
    match host.clipboard_write("x") { ok(_) => { touched = touched + 1 } err(_) => {} }
    match host.clipboard_read() { ok(text) => { touched = touched + text.len() } err(_) => {} }
    match host.request_frame(fn(seconds: f64) {}) { ok(_) => {} err(_) => {} }
    match host.cancel_frame() { ok(_) => {} err(_) => {} }
    match host.text_input(true, "x", 0, 1, 0.0, 0.0, 1.0, 1.0) { ok(_) => {} err(_) => {} }
    match host.semantics_begin() { ok(_) => {} err(_) => {} }
    match host.semantics_node(1, "button", "Add", "", 0.0, 0.0, 1.0, 1.0, true, false) {
        ok(_) => {} err(_) => {}
    }
    match host.semantics_end() { ok(_) => {} err(_) => {} }
    let r: canvaskit.CanvasKitRenderer = new canvaskit.CanvasKitRenderer()
    if r.ready() { touched = touched + 1 }
    touched = touched + r.revision()
    if r.software() { touched = touched + 1 }
    match r.use_font("") { ok(_) => {} err(_) => {} }
    touched = touched + r.font_state()
    match r.paragraph("hi", 13.0, 0.0, 0) {
        ok(p) => { touched = touched + p.size().width as int + p.hit_test(1.0, 1.0) }
        err(_) => {}
    }
    match r.styled_paragraph("hi", paint.TextStyle.weighted(13.0, 5), 100.0, 0) {
        ok(p) => { touched = touched + p.metrics().height as int
                   touched = touched + p.caret(1).width as int
                   match p.selection(0, 1) { ok(boxes) => { touched = touched + boxes.len() } err(_) => {} } }
        err(_) => {}
    }
    match r.graphemes("hi") { ok(g) => { touched = touched + g.len() } err(_) => {} }
    match r.words("hi") { ok(w) => { touched = touched + w.len() } err(_) => {} }
    match r.image("x.png") { ok(i) => { touched = touched + i.size().width as int } err(_) => {} }
    match r.snapshot() { ok(px) => { touched = touched + px.width } err(_) => {} }
    match r.begin(geometry.Size.of(10.0, 10.0), 1.0, 0) {
        ok(c) => {
            c.save(); c.restore(); c.translate(1.0, 1.0); c.rotate(1.0); c.scale(1.0, 1.0)
            c.clip(geometry.Rect.of(0.0, 0.0, 1.0, 1.0), 0.0)
            c.rectangle(geometry.Rect.of(0.0, 0.0, 1.0, 1.0), 0.0, 0, 0.0)
            c.ellipse(geometry.Rect.of(0.0, 0.0, 1.0, 1.0), 0, 0, 0.0)
            c.path("M0 0", 0, 0, 0.0)
            c.visual(0, geometry.Rect.of(0.0, 0.0, 1.0, 1.0), "", paint.VisualStyle {})
            match r.image("y.png") { ok(i) => { c.image(i, geometry.Rect.of(0.0, 0.0, 1.0, 1.0)) } err(_) => {} }
            match r.paragraph("z", 13.0, 0.0, 0) { ok(p) => { c.paragraph(p, 0.0, 0.0) } err(_) => {} }
        }
        err(_) => {}
    }
    match r.end() { ok(_) => {} err(_) => {} }
    let channel: browser.PageLink = new browser.PageLink()
    if channel.ready() { touched = touched + 1 }
    match channel.send("ping", "none") { ok(_) => { touched = touched + 1 } err(_) => {} }
    match channel.receive() { some(message) => { touched = touched + message.topic.len() } none => {} }
    return touched as i32
}

fn main() { surface() }
