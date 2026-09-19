// The page, as a platform.Host.
package browser

import latte.platform

/// `platform.Host` over a browser page.
///
/// Every method is one import away from the DOM, and every refusal is the
/// page's own: a clipboard write outside a user gesture, an input method on a
/// host with no editing element, an accessibility tree with nowhere to publish
/// to. They arrive as a negative number and leave as a `Result` naming what
/// was being attempted — never as a quiet no-op, which is what a missing
/// paste looks like when nothing reports it.
pub class BrowserHost implements platform.Host {
    /// The one frame callback outstanding, if any. The page's own
    /// `requestAnimationFrame` handle is JavaScript's business; this side only
    /// has to know whether it asked.
    pending: Option<fn(f64)> = none

    pub fn init() {}

    pub fn can(what: platform.Capability) -> bool {
        unsafe { return latte_js_can(BrowserHost.code(what) as i32) == 1 }
    }

    /// The wire number for a capability. Stated here rather than derived from
    /// the enum's declaration order, because a member inserted in the middle
    /// would otherwise silently renumber every one after it and the page would
    /// answer the wrong question.
    static fn code(what: platform.Capability) -> int {
        return match what {
            frame_clock => 1,
            clipboard => 2,
            text_input => 3,
            accessibility => 4,
            gpu => 5,
            snapshot => 6,
            fonts => 7,
            images => 8,
            pointer_capture => 9,
            appearance => 10,
            reduce_motion => 11,
        }
    }

    pub fn appearance() -> platform.Appearance {
        unsafe {
            if latte_js_appearance() == 1 { return platform.Appearance.dark }
        }
        return platform.Appearance.light
    }

    pub fn scale() -> f64 {
        unsafe {
            let ratio: f64 = latte_js_scale()
            // A page that answers nonsense gets 1.0 rather than a scene that
            // cannot be drawn: every caller of this multiplies a size by it.
            if ratio > 0.0 && ratio < 16.0 { return ratio }
        }
        return 1.0
    }

    pub fn reduce_motion() -> bool {
        unsafe { return latte_js_reduce_motion() == 1 }
    }

    pub fn clipboard_write(text: string) -> Result<bool> {
        let bytes: Bytes = Text.encode(text, "copy text")?
        unsafe {
            if latte_js_clipboard_write(Text.pointer(bytes), bytes.len() as i32) < 0 {
                return err("could not copy text: the page refused, which is usually a clipboard write outside a user gesture",
                           "platform_refused")
            }
        }
        return ok(true)
    }

    pub fn clipboard_read() -> Result<string> {
        return Text.read("paste text", fn(out: RawPtr<i8>, cap: i32) -> i32 {
            unsafe { return latte_js_clipboard_read(out, cap) }
        })
    }

    pub fn now_nanos() -> int {
        unsafe { return (latte_js_now() * 1000000000.0) as int }
    }

    pub fn request_frame(handler: fn(f64)) -> Result<bool> {
        self.pending = some(handler)
        unsafe {
            if latte_js_request_frame() < 0 {
                self.pending = none
                return err("could not ask for a frame: the page refused", "platform_refused")
            }
        }
        return ok(true)
    }

    pub fn cancel_frame() -> Result<bool> {
        let had: bool = self.pending != none
        self.pending = none
        unsafe { latte_js_cancel_frame() }
        return ok(had)
    }

    /// The page calling back. One request buys one callback, so the handler is
    /// taken before it runs — a handler that asks for another frame from
    /// inside this one must not be overwritten by the clearing afterwards.
    pub fn deliver_frame(seconds: f64) {
        match self.pending {
            none => {}
            some(handler) => { self.pending = none; handler(seconds) }
        }
    }

    pub fn text_input(active: bool, text: string, anchor: int, caret: int,
                      x: f64, y: f64, width: f64, height: f64) -> Result<bool> {
        let bytes: Bytes = Text.encode(text, "tell the input method where the caret is")?
        unsafe {
            if latte_js_text_input(if active { 1 } else { 0 },
                                   Text.pointer(bytes), bytes.len() as i32,
                                   anchor as i32, caret as i32,
                                   x, y, width, height) < 0 {
                return err("could not tell the input method where the caret is: the page has no editing element",
                           "unsupported")
            }
        }
        return ok(true)
    }

    pub fn semantics_begin() -> Result<bool> {
        unsafe {
            if latte_js_semantics_begin() < 0 {
                return err("could not publish an accessibility tree: the page has nowhere to put one",
                           "unsupported")
            }
        }
        return ok(true)
    }

    pub fn semantics_node(id: u64, role: string, label: string, value: string,
                          x: f64, y: f64, width: f64, height: f64,
                          enabled: bool, focused: bool) -> Result<bool> {
        let role_bytes: Bytes = Text.encode(role, "name an accessibility role")?
        let label_bytes: Bytes = Text.encode(label, "name an accessibility node")?
        let value_bytes: Bytes = Text.encode(value, "give an accessibility node its value")?
        unsafe {
            if latte_js_semantics_node(id,
                    Text.pointer(role_bytes), role_bytes.len() as i32,
                    Text.pointer(label_bytes), label_bytes.len() as i32,
                    Text.pointer(value_bytes), value_bytes.len() as i32,
                    x, y, width, height,
                    if enabled { 1 } else { 0 },
                    if focused { 1 } else { 0 }) < 0 {
                return err("could not publish an accessibility node: the page refused",
                           "platform_refused")
            }
        }
        return ok(true)
    }

    pub fn semantics_end() -> Result<bool> {
        unsafe {
            if latte_js_semantics_end() < 0 {
                return err("could not publish an accessibility tree: the page refused",
                           "platform_refused")
            }
        }
        return ok(true)
    }
}

/// The one host a page has, kept here so the frame callback can reach it.
///
/// `platform.HostDesk` holds it as a `Host`, and a frame arriving from
/// JavaScript needs the `BrowserHost` behind that interface. Storing it twice
/// would let the two disagree, so this is the one place that owns it and
/// `install` is what puts it in both.
pub singleton class PageHost {
    current: Option<BrowserHost> = none

    fn init() {}

    pub fn install() -> BrowserHost {
        match self.current {
            some(host) => { return host }
            none => {
                let host: BrowserHost = new BrowserHost()
                self.current = some(host)
                platform.HostDesk.instance.install(host)
                return host
            }
        }
    }

    pub fn deliver_frame(seconds: f64) {
        match self.current {
            some(host) => { host.deliver_frame(seconds) }
            none => {}
        }
    }
}
