// The channel a page gives a canvas application.
package browser

import latte.link

/// Sending an action. The page decides how it travels — a fetch, a WebSocket
/// frame, a message to a worker — and answers whether it went.
pub extern "C" fn latte_js_link_send(action: RawPtr<i8>, action_len: i32,
                                     payload: RawPtr<i8>, payload_len: i32) -> i32
/// 1 when the channel is usable.
pub extern "C" fn latte_js_link_ready() -> i32
/// The next message waiting: a null buffer answers the bytes needed and takes
/// nothing off the queue, and 0 means nothing is waiting.
pub extern "C" fn latte_js_link_receive(out: RawPtr<i8>, cap: i32) -> i32

/// `link.Link` over a page. One string, `topic\npayload`, because two calls
/// could be interleaved and hand one message's topic to another's body.
pub class PageLink implements link.Link {
    pub fn init() {}

    pub fn send(action: string, payload: string) -> Result<bool> {
        let action_bytes: Bytes = Text.encode(action, "send {action}")?
        let payload_bytes: Bytes = Text.encode(payload, "send {action}")?
        unsafe {
            if latte_js_link_send(Text.pointer(action_bytes), action_bytes.len() as i32,
                                  Text.pointer(payload_bytes),
                                  payload_bytes.len() as i32) < 0 {
                return err("could not send {action}: the page has no server to send it to",
                           "unsupported")
            }
        }
        return ok(true)
    }

    pub fn ready() -> bool {
        unsafe { return latte_js_link_ready() == 1 }
    }

    pub fn receive() -> Option<link.Message> {
        var text: string = ""
        match Text.read("read a message", fn(out: RawPtr<i8>, cap: i32) -> i32 {
            unsafe { return latte_js_link_receive(out, cap) }
        }) {
            ok(value) => { text = value }
            err(problem) => { return none }
        }
        if text == "" { return none }
        match text.find("\n") {
            none => { return some(link.Message.of(text, "")) }
            some(split) => {
                return some(link.Message.of(text.slice(0, split),
                                            text.slice(split + 1, text.len())))
            }
        }
    }
}
