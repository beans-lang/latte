// paint.Renderer over a page's CanvasKit surface.
package canvaskit

import latte.geometry
import latte.paint

/// The renderer a Latte page draws with.
///
/// It owns no pixels and no Skia objects. Every one of those lives in the
/// CanvasKit module, and this holds **handles** — small integers the page
/// issued — which it gives back explicitly. That is the whole ownership story,
/// and it is the reason a paragraph going out of scope in Beans frees Skia
/// memory in the same breath rather than at the next collection.
///
/// It draws straight onto the page's GPU surface. There is no frame readback:
/// `end()` flushes the surface the browser is already compositing. Reading
/// pixels back is what `snapshot()` does, it costs a full copy, and it is
/// there for the screenshot gates and nothing else.
pub class CanvasKitRenderer implements paint.Renderer {
    /// Scratch for the out-parameters. One buffer, owned here, rather than an
    /// allocation per measurement: `paragraph.size()` is called once per
    /// control per layout pass and a buffer per call would be the hot path's
    /// allocation.
    reals: RawPtr<f64> = RawPtr.null()
    wholes: RawPtr<i32> = RawPtr.null()
    frame_open: bool = false

    pub fn init() {
        unsafe {
            self.reals = RawPtr.alloc(8)
            self.wholes = RawPtr.alloc(2)
        }
    }

    fn deinit() {
        unsafe {
            if !self.reals.is_null() { self.reals.free() }
            if !self.wholes.is_null() { self.wholes.free() }
        }
    }

    fn real(index: int) -> f64 {
        unsafe { return self.reals.offset(index).read() }
    }

    /// Whether the page has a surface at all. Asked before a frame, so a
    /// renderer whose canvas has not been attached refuses by name instead of
    /// drawing into nothing.
    pub fn ready() -> bool {
        unsafe { return latte_js_ck_ready() == 1 }
    }

    pub fn revision() -> int {
        unsafe { return latte_js_ck_revision() as int }
    }

    pub fn software() -> bool {
        unsafe { return latte_js_ck_software() == 1 }
    }

    /// Pins one font file as the family every later paragraph uses.
    ///
    /// Fetching it is asynchronous and this does not wait — a WebAssembly call
    /// cannot. It answers whether the file is *already* the family: false
    /// means loading, and `font_ready()` is what a caller polls. A screenshot
    /// gate must wait for true before it measures anything, because the same
    /// text in a fallback face is a different width and the comparison would
    /// be against the wrong layout.
    pub fn use_font(path: string) -> Result<bool> {
        let bytes: Bytes = Bytes.from(path)
        unsafe {
            if latte_js_ck_use_font(pointer_of(bytes), bytes.len() as i32) < 0 {
                return err("could not use the font at {path}: the page refused it",
                           "platform_refused")
            }
            return ok(latte_js_ck_font_state() == 2)
        }
    }

    /// 2 ready, 1 loading, 0 none asked for, -1 failed.
    pub fn font_state() -> int {
        unsafe { return latte_js_ck_font_state() as int }
    }

    pub fn font_ready() -> bool { return self.font_state() == 2 }

    pub fn paragraph(text: string, size: f64, width: f64, color: int) -> Result<paint.Paragraph> {
        return self.styled_paragraph(text, paint.TextStyle.of(size), width, color)
    }

    pub fn styled_paragraph(text: string, style: paint.TextStyle, width: f64,
                            color: int) -> Result<paint.Paragraph> {
        if style.size <= 0.0 {
            return err("could not shape text: a point size is a positive number, and {style.size} is not",
                       "out_of_range")
        }
        let bytes: Bytes = Bytes.from(text)
        var handle: int = 0
        unsafe {
            handle = latte_js_ck_paragraph(pointer_of(bytes), bytes.len() as i32,
                                           style.size, style.weight as i32,
                                           style.tracking, style.align as i32,
                                           width, color as i32) as int
        }
        if handle < 0 {
            return err("could not shape text: the page has no font to shape it with",
                       "renderer_error")
        }
        return ok(new CkParagraph(self, handle))
    }

    pub fn begin(size: geometry.Size, scale: f64, background: int) -> Result<paint.Canvas> {
        if self.frame_open {
            return err("could not start a frame: the previous one was never ended",
                       "wrong_moment")
        }
        if !self.ready() {
            return err("could not start a frame: the page has no drawing surface yet",
                       "wrong_moment")
        }
        unsafe {
            if latte_js_ck_begin(size.width, size.height, scale, background as i32) < 0 {
                return err("could not start a frame: the page refused the surface",
                           "renderer_error")
            }
        }
        self.frame_open = true
        return ok(new CkCanvas(self))
    }

    pub fn end() -> Result<bool> {
        if !self.frame_open {
            return err("could not end a frame: none was started", "wrong_moment")
        }
        self.frame_open = false
        unsafe {
            if latte_js_ck_end() < 0 {
                return err("could not finish a frame: the surface was lost while it was being drawn",
                           "renderer_error")
            }
        }
        return ok(true)
    }

    pub fn graphemes(text: string) -> Result<List<int>> {
        return self.offsets(text, "find the grapheme boundaries", true)
    }

    pub fn words(text: string) -> Result<List<int>> {
        return self.offsets(text, "find the word boundaries", false)
    }

    /// Both boundary questions have the same shape: ask the count, then fill a
    /// buffer that size. Written once, because two copies of a two-call
    /// protocol is two chances to trust the first length.
    fn offsets(text: string, attempt: string, graphemes: bool) -> Result<List<int>> {
        let bytes: Bytes = Bytes.from(text)
        var needed: int = 0
        unsafe {
            needed = if graphemes {
                latte_js_ck_graphemes(pointer_of(bytes), bytes.len() as i32,
                                      RawPtr.null(), 0) as int
            } else {
                latte_js_ck_words(pointer_of(bytes), bytes.len() as i32,
                                  RawPtr.null(), 0) as int
            }
        }
        if needed < 0 {
            return err("could not {attempt}: the page refused", "renderer_error")
        }
        if needed == 0 { return ok([]) }
        var out: List<int> = []
        unsafe {
            let buffer: RawPtr<i32> = RawPtr.alloc(needed)
            let wrote: int = if graphemes {
                latte_js_ck_graphemes(pointer_of(bytes), bytes.len() as i32,
                                      buffer, needed as i32) as int
            } else {
                latte_js_ck_words(pointer_of(bytes), bytes.len() as i32,
                                  buffer, needed as i32) as int
            }
            if wrote != needed {
                buffer.free()
                return err("could not {attempt}: the text changed while it was being read",
                           "host_raced")
            }
            for index: int in 0..needed { out.push(buffer.offset(index).read() as int) }
            buffer.free()
        }
        return ok(move out)
    }

    pub fn image(source: string) -> Result<paint.ImageResource> {
        let bytes: Bytes = Bytes.from(source)
        var handle: int = 0
        unsafe {
            handle = latte_js_ck_image_load(pointer_of(bytes), bytes.len() as i32) as int
        }
        if handle < 0 {
            return err("could not load the image {source}: the page refused it",
                       "renderer_error")
        }
        return ok(new CkImage(self, handle, source))
    }

    pub fn snapshot() -> Result<paint.Pixels> {
        var needed: int = 0
        unsafe {
            needed = latte_js_ck_snapshot(RawPtr.null(), 0, self.wholes) as int
        }
        if needed < 0 {
            return err("could not read the frame back: the surface cannot be read",
                       "unsupported")
        }
        if needed == 0 {
            return err("could not read the frame back: nothing has been drawn yet",
                       "wrong_moment")
        }
        var width: int = 0
        var height: int = 0
        unsafe {
            width = self.wholes.offset(0).read() as int
            height = self.wholes.offset(1).read() as int
        }
        var rgba: Bytes = Bytes.filled(needed, 0)
        unsafe {
            let wrote: int = latte_js_ck_snapshot(rgba.as_ptr(), needed as i32,
                                                  self.wholes) as int
            if wrote != needed {
                return err("could not read the frame back: it changed size while it was being read",
                           "host_raced")
            }
        }
        return ok(new paint.Pixels(width, height, move rgba))
    }
}

/// The same address seen as the `const char *` an import declares.
fn pointer_of(buffer: Bytes) -> RawPtr<i8> {
    unsafe { return RawPtr.from_address(buffer.as_ptr().address()) }
}

/// A shaped paragraph, by handle.
///
/// Measurements are asked for once and kept: a paragraph is immutable once
/// shaped, and `size()` is called for every control on every layout pass. The
/// handle is released in `deinit`, so Skia's copy goes when this does.
pub class CkParagraph implements paint.Paragraph {
    owner: CanvasKitRenderer
    pub handle: int
    measured: geometry.Size = geometry.Size.zero()
    line: paint.LineMetrics = paint.LineMetrics {}
    released: bool = false

    pub fn init(owner: CanvasKitRenderer, handle: int) {
        self.owner = owner
        self.handle = handle
        unsafe {
            if latte_js_ck_paragraph_size(handle as i32, owner.reals) >= 0 {
                self.measured = geometry.Size.of(owner.real(0), owner.real(1))
            }
            if latte_js_ck_paragraph_metrics(handle as i32, owner.reals) >= 0 {
                self.line = paint.LineMetrics {
                    ascent: owner.real(0), descent: owner.real(1),
                    height: owner.real(2), baseline: owner.real(3),
                }
            }
        }
    }

    pub fn size() -> geometry.Size { return self.measured }
    pub fn metrics() -> paint.LineMetrics { return self.line }

    pub fn hit_test(x: f64, y: f64) -> int {
        if self.released { return 0 }
        unsafe { return latte_js_ck_paragraph_hit(self.handle as i32, x, y) as int }
    }

    pub fn caret(byte_offset: int) -> geometry.Rect {
        if self.released { return geometry.Rect.zero() }
        unsafe {
            if latte_js_ck_paragraph_caret(self.handle as i32, byte_offset as i32,
                                           self.owner.reals) < 0 {
                return geometry.Rect.zero()
            }
        }
        return geometry.Rect.of(self.owner.real(0), self.owner.real(1),
                                self.owner.real(2), self.owner.real(3))
    }

    pub fn selection(first_byte: int, last_byte: int) -> Result<List<geometry.Rect>> {
        if self.released {
            return err("could not measure a selection: the paragraph has been released",
                       "stale_handle")
        }
        var count: int = 0
        unsafe {
            count = latte_js_ck_paragraph_selection(self.handle as i32,
                        first_byte as i32, last_byte as i32, RawPtr.null(), 0) as int
        }
        if count < 0 {
            return err("could not measure a selection: {first_byte}..{last_byte} is outside this paragraph",
                       "out_of_range")
        }
        var boxes: List<geometry.Rect> = []
        if count == 0 { return ok(move boxes) }
        unsafe {
            let buffer: RawPtr<f64> = RawPtr.alloc(count * 4)
            let wrote: int = latte_js_ck_paragraph_selection(self.handle as i32,
                                 first_byte as i32, last_byte as i32,
                                 buffer, count as i32) as int
            if wrote != count {
                buffer.free()
                return err("could not measure a selection: it changed while it was being read",
                           "host_raced")
            }
            for index: int in 0..count {
                boxes.push(geometry.Rect.of(buffer.offset(index * 4).read(),
                                            buffer.offset(index * 4 + 1).read(),
                                            buffer.offset(index * 4 + 2).read(),
                                            buffer.offset(index * 4 + 3).read()))
            }
            buffer.free()
        }
        return ok(move boxes)
    }

    pub fn release() {
        if self.released { return }
        self.released = true
        unsafe { latte_js_ck_paragraph_release(self.handle as i32) }
    }

    fn deinit() { self.release() }
}

/// A decoded image, by handle.
pub class CkImage implements paint.ImageResource {
    owner: CanvasKitRenderer
    pub handle: int
    source: string
    released: bool = false

    pub fn init(owner: CanvasKitRenderer, handle: int, source: string) {
        self.owner = owner
        self.handle = handle
        self.source = source
    }

    /// Zero until the image has decoded. A caller drawing it before then draws
    /// nothing rather than stretching an empty picture over its box.
    pub fn size() -> geometry.Size {
        if self.released { return geometry.Size.zero() }
        unsafe {
            if latte_js_ck_image_size(self.handle as i32, self.owner.reals) < 0 {
                return geometry.Size.zero()
            }
        }
        return geometry.Size.of(self.owner.real(0), self.owner.real(1))
    }

    /// 1 ready, 0 still decoding, -1 failed. A page that answers -1 has told
    /// the caller something useful: the source is wrong, not slow.
    pub fn state() -> int {
        if self.released { return -1 }
        unsafe { return latte_js_ck_image_state(self.handle as i32) as int }
    }

    pub fn ready() -> bool { return self.state() == 1 }
    pub fn failed() -> bool { return self.state() < 0 }
    pub fn where_from() -> string { return self.source }

    pub fn release() {
        if self.released { return }
        self.released = true
        unsafe { latte_js_ck_image_release(self.handle as i32) }
    }

    fn deinit() { self.release() }
}

/// The canvas a frame is drawn onto.
///
/// It holds no state of its own: the page keeps the current canvas between
/// `begin` and `end`, because CanvasKit's canvas is owned by its surface and a
/// handle to it would be a handle to something the surface may replace. So a
/// `CkCanvas` is a permission to draw, valid for one frame.
pub class CkCanvas implements paint.Canvas {
    owner: CanvasKitRenderer
    /// Thirteen numbers, the layout `latte_js_ck_visual` reads a VisualStyle
    /// as. Owned here so a drawing command allocates nothing.
    style_buffer: RawPtr<f64> = RawPtr.null()

    pub fn init(owner: CanvasKitRenderer) {
        self.owner = owner
        unsafe { self.style_buffer = RawPtr.alloc(13) }
    }

    fn deinit() {
        unsafe { if !self.style_buffer.is_null() { self.style_buffer.free() } }
    }

    fn checked(code: i32, attempt: string) -> Result<bool> {
        if code < 0 {
            return err("could not {attempt}: the drawing surface refused it", "renderer_error")
        }
        return ok(true)
    }

    pub fn save() -> Result<bool> {
        unsafe { return self.checked(latte_js_ck_save(), "save the drawing state") }
    }

    pub fn restore() -> Result<bool> {
        unsafe { return self.checked(latte_js_ck_restore(), "restore the drawing state") }
    }

    pub fn translate(x: f64, y: f64) -> Result<bool> {
        unsafe { return self.checked(latte_js_ck_translate(x, y), "move the origin") }
    }

    pub fn rotate(degrees: f64) -> Result<bool> {
        unsafe { return self.checked(latte_js_ck_rotate(degrees), "rotate") }
    }

    pub fn scale(x: f64, y: f64) -> Result<bool> {
        unsafe { return self.checked(latte_js_ck_scale(x, y), "scale") }
    }

    pub fn clip(rect: geometry.Rect, radius: f64) -> Result<bool> {
        unsafe {
            return self.checked(latte_js_ck_clip(rect.x, rect.y, rect.width,
                                                 rect.height, radius), "clip")
        }
    }

    pub fn rectangle(rect: geometry.Rect, radius: f64, color: int,
                     stroke: f64) -> Result<bool> {
        unsafe {
            return self.checked(latte_js_ck_rect(rect.x, rect.y, rect.width,
                                                 rect.height, radius,
                                                 color as i32, stroke),
                                "draw a rectangle")
        }
    }

    pub fn ellipse(rect: geometry.Rect, fill: int, outline: int,
                   stroke: f64) -> Result<bool> {
        unsafe {
            return self.checked(latte_js_ck_ellipse(rect.x, rect.y, rect.width,
                                                    rect.height, fill as i32,
                                                    outline as i32, stroke),
                                "draw an ellipse")
        }
    }

    pub fn path(data: string, fill: int, outline: int, stroke: f64) -> Result<bool> {
        let bytes: Bytes = Bytes.from(data)
        unsafe {
            return self.checked(latte_js_ck_path(pointer_of(bytes), bytes.len() as i32,
                                                 fill as i32, outline as i32, stroke),
                                "draw a path")
        }
    }

    pub fn visual(kind: int, rect: geometry.Rect, data: string,
                  style: paint.VisualStyle) -> Result<bool> {
        let bytes: Bytes = Bytes.from(data)
        unsafe {
            self.style_buffer.offset(0).write(style.fill as f64)
            self.style_buffer.offset(1).write(style.outline as f64)
            self.style_buffer.offset(2).write(style.stroke_width)
            self.style_buffer.offset(3).write(style.gradient_start as f64)
            self.style_buffer.offset(4).write(style.gradient_end as f64)
            self.style_buffer.offset(5).write(if style.gradient_enabled { 1.0 } else { 0.0 })
            self.style_buffer.offset(6).write(style.shadow_color as f64)
            self.style_buffer.offset(7).write(style.shadow_blur)
            self.style_buffer.offset(8).write(style.shadow_dx)
            self.style_buffer.offset(9).write(style.shadow_dy)
            self.style_buffer.offset(10).write(style.clip_radius)
            self.style_buffer.offset(11).write(style.stroke_cap as f64)
            self.style_buffer.offset(12).write(style.stroke_join as f64)
            return self.checked(latte_js_ck_visual(kind as i32, rect.x, rect.y,
                                                   rect.width, rect.height,
                                                   pointer_of(bytes),
                                                   bytes.len() as i32,
                                                   self.style_buffer),
                                "draw a shape")
        }
    }

    pub fn image(value: paint.ImageResource, rect: geometry.Rect) -> Result<bool> {
        match value as? CkImage {
            none => {
                return err("could not draw an image: it was made by a different renderer",
                           "bad_owner")
            }
            some(picture) => {
                if picture.state() == 0 {
                    // Still decoding. Drawing nothing is right: stretching an
                    // empty picture over the box would flash, and refusing
                    // would fail a frame for something that will be there in a
                    // moment. The scene repaints when it arrives.
                    return ok(false)
                }
                if picture.failed() {
                    return err("could not draw the image {picture.where_from()}: it did not decode",
                               "renderer_error")
                }
                unsafe {
                    return self.checked(latte_js_ck_draw_image(picture.handle as i32,
                                            rect.x, rect.y, rect.width, rect.height),
                                        "draw an image")
                }
            }
        }
    }

    pub fn paragraph(value: paint.Paragraph, x: f64, y: f64) -> Result<bool> {
        match value as? CkParagraph {
            none => {
                return err("could not draw text: the paragraph was shaped by a different renderer",
                           "bad_owner")
            }
            some(shaped) => {
                unsafe {
                    return self.checked(latte_js_ck_draw_paragraph(shaped.handle as i32, x, y),
                                        "draw text")
                }
            }
        }
    }
}
