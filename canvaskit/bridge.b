// What a page's drawing surface offers, as WebAssembly imports.
package canvaskit

/// The drawing half of the boundary.
///
/// Everything here is a plain scalar or a `(pointer, length)` into **this**
/// module's memory. That is not a style choice. A CanvasKit build is its own
/// WebAssembly module with its own linear memory; handing it an address from
/// here would have it read its own heap at that offset, which is a value
/// rather than a fault, so the mistake would show up as wrong pixels and not
/// as an error. `js/latte-canvaskit.js` decodes every string on this side of
/// the fence and hands CanvasKit JavaScript values.
///
/// Resources — paragraphs and images — are **opaque handles**, small positive
/// integers issued by the page. Beans never sees a pointer to one and cannot
/// dereference one; a handle that has been released answers a refusal rather
/// than reaching a deleted Skia object. Every one is released explicitly, from
/// a `deinit`, so a paragraph that goes out of scope in Beans frees its Skia
/// memory in the same breath.

/// 1 when a surface exists and is ready to draw into.
pub extern "C" fn latte_js_ck_ready() -> i32
/// Bumps whenever the surface is replaced: a lost GPU context, a resize, or a
/// fall back to the CPU.
pub extern "C" fn latte_js_ck_revision() -> i32
/// 1 when the current surface is a CPU one.
pub extern "C" fn latte_js_ck_software() -> i32

/// Registers one font file as the family every later paragraph uses. An empty
/// path returns to the page's own UI font. Fetching is asynchronous, so this
/// only starts it; `latte_js_ck_font_state` says how it went.
pub extern "C" fn latte_js_ck_use_font(source: RawPtr<i8>, len: i32) -> i32
/// 0 none asked for, 1 loading, 2 ready, -1 failed.
pub extern "C" fn latte_js_ck_font_state() -> i32

/// Starts a frame. The size is in logical points and `scale` is device pixels
/// per point; the page owns the multiplication, because the backing store's
/// size is the page's business and a rounding difference between the two would
/// show as a half-pixel seam.
pub extern "C" fn latte_js_ck_begin(width: f64, height: f64, scale: f64,
                                    background: i32) -> i32
/// Ends it and puts it on screen. No pixels are read back: the surface is the
/// page's own GPU surface and flushing it is what shows it.
pub extern "C" fn latte_js_ck_end() -> i32

pub extern "C" fn latte_js_ck_save() -> i32
pub extern "C" fn latte_js_ck_restore() -> i32
pub extern "C" fn latte_js_ck_translate(x: f64, y: f64) -> i32
pub extern "C" fn latte_js_ck_rotate(degrees: f64) -> i32
pub extern "C" fn latte_js_ck_scale(x: f64, y: f64) -> i32
pub extern "C" fn latte_js_ck_clip(x: f64, y: f64, width: f64, height: f64,
                                   radius: f64) -> i32
pub extern "C" fn latte_js_ck_rect(x: f64, y: f64, width: f64, height: f64,
                                   radius: f64, color: i32, stroke: f64) -> i32
pub extern "C" fn latte_js_ck_ellipse(x: f64, y: f64, width: f64, height: f64,
                                      fill: i32, outline: i32, stroke: f64) -> i32
pub extern "C" fn latte_js_ck_path(data: RawPtr<i8>, len: i32, fill: i32,
                                   outline: i32, stroke: f64) -> i32
/// A shape with a full `paint.VisualStyle` behind it. The style travels as
/// thirteen numbers in a caller-owned buffer rather than as thirteen
/// arguments: it grows, and a call that took them one by one would have to be
/// renumbered on both sides every time it did.
pub extern "C" fn latte_js_ck_visual(kind: i32, x: f64, y: f64, width: f64,
                                     height: f64, data: RawPtr<i8>, len: i32,
                                     style: RawPtr<f64>) -> i32
pub extern "C" fn latte_js_ck_draw_image(handle: i32, x: f64, y: f64,
                                         width: f64, height: f64) -> i32
pub extern "C" fn latte_js_ck_draw_paragraph(handle: i32, x: f64, y: f64) -> i32

/// Shapes a paragraph and answers its handle, or a negative refusal.
pub extern "C" fn latte_js_ck_paragraph(text: RawPtr<i8>, len: i32, size: f64,
                                        weight: i32, tracking: f64, align: i32,
                                        width: f64, color: i32) -> i32
/// Two numbers: width and height.
pub extern "C" fn latte_js_ck_paragraph_size(handle: i32, out: RawPtr<f64>) -> i32
/// Four numbers: ascent, descent, height, baseline.
pub extern "C" fn latte_js_ck_paragraph_metrics(handle: i32, out: RawPtr<f64>) -> i32
/// The byte offset a point lands on.
pub extern "C" fn latte_js_ck_paragraph_hit(handle: i32, x: f64, y: f64) -> i32
/// Four numbers: the caret's x, y, width and height.
pub extern "C" fn latte_js_ck_paragraph_caret(handle: i32, byte_offset: i32,
                                              out: RawPtr<f64>) -> i32
/// The boxes covering a byte range, four numbers each. The two-call shape: a
/// null buffer answers the count.
pub extern "C" fn latte_js_ck_paragraph_selection(handle: i32, first: i32, last: i32,
                                                  out: RawPtr<f64>, cap: i32) -> i32
pub extern "C" fn latte_js_ck_paragraph_release(handle: i32)

/// Grapheme and word boundaries, as byte offsets. The two-call shape again.
pub extern "C" fn latte_js_ck_graphemes(text: RawPtr<i8>, len: i32,
                                        out: RawPtr<i32>, cap: i32) -> i32
pub extern "C" fn latte_js_ck_words(text: RawPtr<i8>, len: i32,
                                    out: RawPtr<i32>, cap: i32) -> i32

/// Starts loading an image and answers its handle. Decoding is asynchronous;
/// the handle is valid at once and `latte_js_ck_image_state` says whether
/// there are pixels behind it yet.
pub extern "C" fn latte_js_ck_image_load(source: RawPtr<i8>, len: i32) -> i32
/// 0 loading, 1 ready, -1 failed.
pub extern "C" fn latte_js_ck_image_state(handle: i32) -> i32
/// Two numbers: width and height. Zeroes while it is still loading.
pub extern "C" fn latte_js_ck_image_size(handle: i32, out: RawPtr<f64>) -> i32
pub extern "C" fn latte_js_ck_image_release(handle: i32)

/// The pixels of the last finished frame, RGBA. The two-call shape: a null
/// buffer answers the byte count and writes the size into `size`.
pub extern "C" fn latte_js_ck_snapshot(out: RawPtr<u8>, cap: i32,
                                       size: RawPtr<i32>) -> i32
