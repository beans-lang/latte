// The Stage 3 drawing proof: real pixels, through CanvasKit, in a page.
//
// Scratch to the suite loop and a build target to `tools/paint.html`. It is a
// module rather than a program: `latte_*` below are what a page calls, and the
// page is `js/latte-page.js`.
package main

import latte.browser
import latte.compose
import latte.input

/// One screen with something of every drawing primitive on it.
pub class PaintDemo extends compose.Component {
    pub clicks: int = 0
    pub typed: string = "type here"

    pub fn init() { super.init() }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 16.0)
        b.number("spacing", 12.0)

        b.open("Label")
        b.text("Latte draws with CanvasKit")
        b.number("font_size", 18.0)
        b.close()

        b.open("HStack")
        b.number("spacing", 12.0)
        b.open("Box")
        b.number("width", 64.0)
        b.number("height", 40.0)
        b.open("Rectangle")
        b.word("fill", "#2f6f4f")
        b.number("clip_radius", 8.0)
        b.close()
        b.close()
        b.open("Box")
        b.number("width", 64.0)
        b.number("height", 40.0)
        b.open("Ellipse")
        b.word("fill", "#365eea")
        b.word("stroke", "#101828")
        b.number("stroke_width", 2.0)
        b.close()
        b.close()
        b.open("Box")
        b.number("width", 64.0)
        b.number("height", 40.0)
        b.open("Rectangle")
        b.word("gradient_start", "#d5a665")
        b.word("gradient_end", "#87582f")
        b.number("clip_radius", 6.0)
        b.word("shadow_color", "#00000055")
        b.number("shadow_blur", 8.0)
        b.number("shadow_dy", 2.0)
        b.close()
        b.close()
        b.open("Box")
        b.number("width", 64.0)
        b.number("height", 40.0)
        b.open("Path")
        b.text("M8 32 L32 8 L56 32 Z")
        b.word("fill", "#b03030")
        b.close()
        b.close()
        b.close()

        b.open("Button")
        b.text("Clicked {self.clicks} times")
        b.on("click", fn(e: input.UiEvent) { self.clicks = self.clicks + 1; self.request_render() })
        b.close()

        b.open("TextField")
        b.text(self.typed)
        b.number("width", 220.0)
        b.on("commit", fn(e: input.UiEvent) { self.typed = e.text; self.request_render() })
        b.close()

        b.open("Label")
        b.text("Slider, switch and a check box below")
        b.number("font_size", 11.0)
        b.close()

        b.open("HStack")
        b.number("spacing", 12.0)
        b.open("Switch")
        b.close()
        b.open("CheckBox")
        b.text("ready")
        b.close()
        b.open("Slider")
        b.number("width", 120.0)
        b.number("min", 0.0)
        b.number("max", 100.0)
        b.number("value", 40.0)
        b.close()
        b.close()

        b.close()
    }
}

// ---- what the page calls ------------------------------------------------
//
// One export per thing a page can do. They are written here rather than in
// `latte.browser` because wasm-ld exports only the names it can see in the
// module being linked, and `PageApp` is in a package.

pub extern "C" fn boot() -> i32 as "latte_boot" {
    return browser.PageApp.instance.boot() as i32
}

pub extern "C" fn mount(width: f64, height: f64, scale: f64) -> i32 as "latte_mount" {
    return browser.PageApp.instance.mount(new PaintDemo(), width, height, scale) as i32
}

pub extern "C" fn frame(seconds: f64) -> i32 as "latte_frame" {
    return browser.PageApp.instance.frame(seconds) as i32
}

pub extern "C" fn pointer(kind: i32, x: f64, y: f64, button: i32, clicks: i32,
                          modifiers: i32) -> i32 as "latte_pointer" {
    return browser.PageApp.instance.pointer(kind as int, x, y, button as int,
                                            clicks as int, modifiers as int) as i32
}

pub extern "C" fn key(kind: i32, code: i32, text: RawPtr<i8>, len: i32,
                      modifiers: i32) -> i32 as "latte_key" {
    return browser.PageApp.instance.key(kind as int, code as int,
                                        browser.Text.copy_in(text, len as int),
                                        modifiers as int) as i32
}

pub extern "C" fn text_input(kind: i32, text: RawPtr<i8>, len: i32, anchor: i32,
                             caret: i32) -> i32 as "latte_text_input" {
    return browser.PageApp.instance.text_input(kind as int,
                                               browser.Text.copy_in(text, len as int),
                                               anchor as int, caret as int) as i32
}

pub extern "C" fn scroll(x: f64, y: f64, dx: f64, dy: f64) -> i32 as "latte_scroll" {
    return browser.PageApp.instance.scroll(x, y, dx, dy) as i32
}

pub extern "C" fn resize(width: f64, height: f64, scale: f64) -> i32 as "latte_resize" {
    return browser.PageApp.instance.resize(width, height, scale) as i32
}

pub extern "C" fn semantics_action(handle: u64, action: i32) -> i32 as "latte_semantics_action" {
    return browser.PageApp.instance.semantics_action(handle, action as int) as i32
}

pub extern "C" fn unmount() -> i32 as "latte_unmount" {
    return browser.PageApp.instance.unmount() as i32
}

pub extern "C" fn software() -> i32 as "latte_software" {
    return if browser.PageApp.instance.software() { 1 } else { 0 }
}

/// The counters a gate reads: frames delivered, frames that painted, frames
/// asked for. Three numbers rather than one, because "it drew" and "it asked
/// to draw" are the two halves of the idle question.
pub extern "C" fn frames() -> i32 as "latte_frames" {
    return browser.PageApp.instance.frames as i32
}
pub extern "C" fn painted() -> i32 as "latte_painted" {
    return browser.PageApp.instance.painted as i32
}
pub extern "C" fn requests() -> i32 as "latte_requests" {
    return browser.PageApp.instance.requests as i32
}

/// The last failure, for a page that got -1 and needs to say why.
pub extern "C" fn last_error(out: RawPtr<i8>, cap: i32) -> i32 as "latte_last_error" {
    let message: string = browser.PageApp.instance.error()
    let bytes: Bytes = Bytes.from(message)
    if out.is_null() || cap <= 0 { return bytes.len() as i32 }
    if bytes.len() > cap as int { return bytes.len() as i32 }
    unsafe {
        let target: RawPtr<u8> = RawPtr.from_address(out.address())
        for index: int in 0..bytes.len() { target.offset(index).write(bytes.get(index) as u8) }
    }
    return bytes.len() as i32
}

fn main() {}
