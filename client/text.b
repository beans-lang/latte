// Moving text across the WebAssembly boundary: a pointer and a count, copied
// on the way in, and the two-call shape on the way out.
//
// `latte.browser`'s `Text` is the same idea for the canvas target. It is not
// shared, and the reason is the import graph rather than taste: that package
// also holds the scene, the renderer and the platform host, so an HTML page
// that imported it for two functions would link CanvasKit. Twenty lines
// twice is the cheaper of the two mistakes, and `tools/wasm_abi.sh` checks
// the surface either way.
package latte_client

/// Copies text the page wrote into this module's memory.
///
/// Copied, not kept: the call that follows may grow the memory, which moves
/// everything a borrowed pointer was looking at.
pub fn text_in(pointer: RawPtr<i8>, length: int) -> string {
    if pointer.is_null() || length <= 0 { return "" }
    unsafe {
        let bytes: RawPtr<u8> = RawPtr.from_address(pointer.address())
        let copy: Bytes = Bytes.from_raw(bytes, length)
        return copy.to_string()
    }
}

/// Writes `text` into a caller's buffer and answers the bytes it needed.
///
/// The two-call shape: a null buffer answers the length, then one that size
/// is filled. A caller that passes a buffer too small gets the length again
/// and nothing written, so a short read is never a truncated string.
pub fn text_out(text: string, out: RawPtr<i8>, cap: int) -> int {
    let bytes: Bytes = Bytes.from(text)
    if out.is_null() || cap <= 0 { return bytes.len() }
    if bytes.len() > cap { return bytes.len() }
    unsafe {
        let target: RawPtr<u8> = RawPtr.from_address(out.address())
        for index: int in 0..bytes.len() { target.offset(index).write(bytes.get(index) as u8) }
    }
    return bytes.len()
}
