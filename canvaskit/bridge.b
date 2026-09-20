// What a page's drawing surface offers, as WebAssembly imports.
package canvaskit

/// The drawing half of the boundary: plain scalars, offsets into *this*
/// module's memory, and opaque handles. Why: docs/notes.md.

/// 1 when a surface exists and is ready to draw into.
pub extern "C" fn latte_js_ck_ready() -> i32
/// Bumps whenever the surface is replaced: a lost GPU context, a resize, or a
/// fall back to the CPU.
pub extern "C" fn latte_js_ck_revision() -> i32
/// 1 when the current surface is a CPU one.
pub extern "C" fn latte_js_ck_software() -> i32

/// Registers one font file as the family later paragraphs use; an empty path
/// returns to the page's UI font. `latte_js_ck_font_state` says how it went.
pub extern "C" fn latte_js_ck_use_font(source: RawPtr<i8>, len: i32) -> i32
/// 0 none asked for, 1 loading, 2 ready, -1 failed.
pub extern "C" fn latte_js_ck_font_state() -> i32

/// Starts a frame, in logical points, with `scale` device pixels per point.
/// The page owns the multiplication, or a rounding split shows as a seam.
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
/// A shape with a full `paint.VisualStyle`, which travels as numbers in a
/// caller-owned buffer: as arguments it would be renumbered every time it grew.
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

/// Starts loading an image and answers its handle, which is valid at once;
/// `latte_js_ck_image_state` says whether there are pixels behind it yet.
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
