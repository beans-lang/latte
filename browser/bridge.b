// The functions the page supplies, and how text crosses to them.
package browser

/// Every import a Latte WebAssembly module has. `js/latte-runtime.js` is the
/// other half and `tools/wasm_abi.sh` pairs them; no pointer ever travels.

/// 1 is standard output, 2 is standard error — the same two the runtime's
/// write hook uses.
pub extern "C" fn latte_js_write(stream: i32, bytes: RawPtr<i8>, len: i32)
pub extern "C" fn latte_js_exit(code: i32)

/// A monotonic clock in seconds. `performance.now()` divided by a thousand;
/// only differences are used, so its origin does not matter.
pub extern "C" fn latte_js_now() -> f64

/// Whether the page can do something. `js/latte-runtime.js` answers from
/// feature detection rather than from a browser name.
pub extern "C" fn latte_js_can(capability: i32) -> i32

/// 1 dark, 0 light — `prefers-color-scheme`.
pub extern "C" fn latte_js_appearance() -> i32
/// `devicePixelRatio`, which moves with browser zoom as well as with the
/// display.
pub extern "C" fn latte_js_scale() -> f64
/// 1 when `prefers-reduced-motion: reduce`.
pub extern "C" fn latte_js_reduce_motion() -> i32

/// Asks for one `requestAnimationFrame`. The page calls `latte_frame` back.
pub extern "C" fn latte_js_request_frame() -> i32
/// Cancels a pending one. 1 when there was one to cancel.
pub extern "C" fn latte_js_cancel_frame() -> i32

pub extern "C" fn latte_js_clipboard_write(bytes: RawPtr<i8>, len: i32) -> i32
/// The two-call shape: a null buffer answers the length, then one that size is
/// filled. A negative answer is a refusal, never a length.
pub extern "C" fn latte_js_clipboard_read(out: RawPtr<i8>, cap: i32) -> i32

/// Where text is being edited, so an input method can place its candidate
/// window and the page can keep its own editing element in step.
pub extern "C" fn latte_js_text_input(active: i32, bytes: RawPtr<i8>, len: i32,
                                      anchor: i32, caret: i32,
                                      x: f64, y: f64, width: f64, height: f64) -> i32

pub extern "C" fn latte_js_semantics_begin() -> i32
pub extern "C" fn latte_js_semantics_node(id: u64,
                                          role: RawPtr<i8>, role_len: i32,
                                          label: RawPtr<i8>, label_len: i32,
                                          value: RawPtr<i8>, value_len: i32,
                                          x: f64, y: f64, width: f64, height: f64,
                                          enabled: i32, focused: i32) -> i32
pub extern "C" fn latte_js_semantics_end() -> i32

/// Moving text across the boundary: never NUL-terminated, always a pointer and
/// a count, and copied immediately. A zero byte is refused before it travels.
pub class Text {
    /// The UTF-8 bytes of `text` as (pointer, length). Hold the `Bytes` in a
    /// local for the whole call: inlined, it may be dropped first.
    pub static fn encode(text: string, attempt: string) -> Result<Bytes> {
        if text.contains("\u{0}") {
            return err("could not {attempt}: the text has a NUL byte in it, and it would be cut there on the way through the page",
                       "text_has_nul")
        }
        return ok(Bytes.from(text))
    }

    /// The same address seen as the `const char *` the import declares. Beans
    /// keeps `u8` and `i8` pointers apart; the C ABI does not.
    pub static fn pointer(buffer: Bytes) -> RawPtr<i8> {
        unsafe { return RawPtr.from_address(buffer.as_ptr().address()) }
    }

    /// Copies text the page wrote into this module's memory. Copied, not kept:
    /// the handler that follows may grow the memory, which moves everything.
    pub static fn copy_in(pointer: RawPtr<i8>, length: int) -> string {
        if pointer.is_null() || length <= 0 { return "" }
        unsafe {
            let bytes: RawPtr<u8> = RawPtr.from_address(pointer.address())
            let copy: Bytes = Bytes.from_raw(bytes, length)
            return copy.to_string()
        }
    }

    /// Reads text back with the two-call shape.
    pub static fn read(attempt: string, probe: fn(RawPtr<i8>, i32) -> i32) -> Result<string> {
        let needed: int = probe(RawPtr.null(), 0) as int
        if needed < 0 {
            return err("could not {attempt}: the page refused", "platform_refused")
        }
        if needed == 0 { return ok("") }
        var buffer: Bytes = Bytes.filled(needed, 0)
        let written: int = probe(Text.pointer(buffer), needed as i32) as int
        if written < 0 {
            return err("could not {attempt}: the page refused", "platform_refused")
        }
        // A longer length the second time means the text changed between the
        // calls; the first length would read past what was copied.
        if written != needed {
            return err("could not {attempt}: the text changed while it was being read",
                       "host_raced")
        }
        return ok(buffer.to_string())
    }
}

/// Writes `text` into a caller's buffer and answers the bytes it needed, the
/// two-call shape. Written once: three copies is three chances to get it wrong.
pub fn write_text(text: string, out: RawPtr<i8>, cap: int) -> int {
    let bytes: Bytes = Bytes.from(text)
    if out.is_null() || cap <= 0 { return bytes.len() }
    if bytes.len() > cap { return bytes.len() }
    unsafe {
        let target: RawPtr<u8> = RawPtr.from_address(out.address())
        for index: int in 0..bytes.len() { target.offset(index).write(bytes.get(index) as u8) }
    }
    return bytes.len()
}
