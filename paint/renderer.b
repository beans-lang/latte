package paint

import latte.geometry

/// The only drawing dependency of the Beans UI. Implementations own their
/// resources; no platform or graphics-library type crosses this interface.
pub interface Renderer {
    fn paragraph(text: string, size: f64, width: f64, color: int) -> Result<Paragraph>
    /// The same shaping with a weight, tracking and alignment.
    fn styled_paragraph(text: string, style: TextStyle, width: f64, color: int) -> Result<Paragraph>
    /// Makes one font file the family every later paragraph uses, on every
    /// platform. An empty path returns to the platform's own UI font.
    fn use_font(path: string) -> Result<bool>
    fn begin(size: geometry.Size, scale: f64, background: int) -> Result<Canvas>
    fn end() -> Result<bool>
    fn graphemes(text: string) -> Result<List<int>>
    /// Word boundaries, by the Unicode rules — what a double-click and an
    /// option-arrow select. Byte offsets, like graphemes.
    fn words(text: string) -> Result<List<int>>
    fn image(source: string) -> Result<ImageResource>

    /// Bumps whenever the drawing surface is replaced — a lost GPU context, a
    /// resize, a fall back to the CPU. A scene compares it with the number it
    /// last drew under and repaints everything when they differ, because a new
    /// surface holds none of the old one's pixels.
    fn revision() -> int

    /// Whether this renderer is currently drawing on the CPU. A GPU renderer
    /// that has lost its context answers true until it has one again.
    fn software() -> bool

    /// The pixels of the last finished frame.
    ///
    /// What the screenshot checks read. Refused rather than faked by a renderer
    /// with no readable surface, so a suite that cannot compare images fails
    /// instead of passing on an empty picture.
    fn snapshot() -> Result<Pixels>
}

/// A frame read back out of a renderer: RGBA, eight bits a channel, rows
/// top to bottom with no padding between them.
pub class Pixels {
    pub width: int = 0
    pub height: int = 0
    pub rgba: Bytes = Bytes.filled(0, 0)

    pub fn init(width: int, height: int, move rgba: Bytes) {
        self.width = width
        self.height = height
        self.rgba = move rgba
    }

    /// One pixel, or `none` outside the image.
    pub fn at(x: int, y: int) -> Option<List<int>> {
        if x < 0 || y < 0 || x >= self.width || y >= self.height { return none }
        let start: int = (y * self.width + x) * 4
        return some([self.rgba.get(start), self.rgba.get(start + 1),
                     self.rgba.get(start + 2), self.rgba.get(start + 3)])
    }

    pub fn show() -> string {
        return "{self.width}x{self.height} rgba"
    }
}

/// An opaque decoded image retained by the renderer while Beans uses it.
pub interface ImageResource {
    fn size() -> geometry.Size
}

/// A shaped paragraph is used for both measurement and painting.
pub interface Paragraph {
    fn size() -> geometry.Size
    fn metrics() -> LineMetrics
    fn hit_test(x: f64, y: f64) -> int
    fn caret(byte_offset: int) -> geometry.Rect
    fn selection(first_byte: int, last_byte: int) -> Result<List<geometry.Rect>>
}

/// Colors are RGBA, packed most significant channel first. Coordinates are
/// logical points, with a top-left origin. All clips and transforms nest.
pub interface Canvas {
    fn save() -> Result<bool>
    fn restore() -> Result<bool>
    fn translate(x: f64, y: f64) -> Result<bool>
    fn rotate(degrees: f64) -> Result<bool>
    fn scale(x: f64, y: f64) -> Result<bool>
    fn clip(rect: geometry.Rect, radius: f64) -> Result<bool>
    fn rectangle(rect: geometry.Rect, radius: f64, color: int, stroke: f64) -> Result<bool>
    fn ellipse(rect: geometry.Rect, fill: int, outline: int, stroke: f64) -> Result<bool>
    fn path(data: string, fill: int, outline: int, stroke: f64) -> Result<bool>
    fn visual(kind: int, rect: geometry.Rect, data: string, style: VisualStyle) -> Result<bool>
    fn image(value: ImageResource, rect: geometry.Rect) -> Result<bool>
    fn paragraph(value: Paragraph, x: f64, y: f64) -> Result<bool>
}
