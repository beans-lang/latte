package paint

/// How a run of text is shaped. One value so a caller cannot pass a size
/// without the weight and tracking that go with it.
pub struct TextStyle {
    pub size: f64 = 13.0
    /// 0 default, 1 light, 2 regular, 3 medium, 4 semibold, 5 bold, 6 heavy.
    pub weight: int = 0
    /// Extra space between glyphs, in points. Apple bakes its own into the
    /// optical size, so this stays 0 unless a role asks for more.
    pub tracking: f64 = 0.0
    /// 0 leading, 1 centre, 2 trailing.
    pub align: int = 0

    pub static fn of(size: f64) -> TextStyle {
        return TextStyle { size: size }
    }
    pub static fn weighted(size: f64, weight: int) -> TextStyle {
        return TextStyle { size: size, weight: weight }
    }
    pub fn same(other: TextStyle) -> bool {
        return self.size == other.size && self.weight == other.weight &&
               self.tracking == other.tracking && self.align == other.align
    }
}

/// What a shaped line occupies vertically. `baseline` is measured down from the
/// top of the line box, which is where a caller must put a native baseline.
pub struct LineMetrics {
    pub ascent: f64 = 0.0
    pub descent: f64 = 0.0
    pub height: f64 = 0.0
    pub baseline: f64 = 0.0
}
