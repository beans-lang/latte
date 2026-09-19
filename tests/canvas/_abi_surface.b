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
package main

import latte.browser
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
    return touched as i32
}

fn main() { surface() }
