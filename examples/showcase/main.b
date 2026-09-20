// Latte's browser showcase. Every export below is one line of
// `browser.PageApp`; the screens are `.bx` under `site/`. See docs/browser.md.
package main

import latte.browser
import showcase.generated.site

pub extern "C" fn boot() -> i32 as "latte_boot" {
    return browser.PageApp.instance.boot() as i32
}

pub extern "C" fn mount(width: f64, height: f64, scale: f64) -> i32 as "latte_mount" {
    return browser.PageApp.instance.mount(new site.Shell(), width, height, scale) as i32
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

/// Frames delivered, painted, and asked for. Three numbers, because "it drew"
/// and "it asked to draw" are the two halves of the idle question.
pub extern "C" fn frames() -> i32 as "latte_frames" {
    return browser.PageApp.instance.frames as i32
}
pub extern "C" fn painted() -> i32 as "latte_painted" {
    return browser.PageApp.instance.painted as i32
}
pub extern "C" fn requests() -> i32 as "latte_requests" {
    return browser.PageApp.instance.requests as i32
}

/// The last failure, for a page that got -1 and has to say why.
pub extern "C" fn last_error(out: RawPtr<i8>, cap: i32) -> i32 as "latte_last_error" {
    return browser.write_text(browser.PageApp.instance.error(), out, cap as int) as i32
}

fn main() {}
