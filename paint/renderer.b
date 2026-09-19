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
