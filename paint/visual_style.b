package paint

/// Shared drawing values. A zero gradient pair means a solid fill.
pub struct VisualStyle {
    pub fill: int = 0
    pub outline: int = 0
    pub stroke_width: f64 = 0.0
    pub gradient_start: int = 0
    pub gradient_end: int = 0
    pub gradient_enabled: bool = false
    pub shadow_color: int = 0
    pub shadow_blur: f64 = 0.0
    pub shadow_dx: f64 = 0.0
    pub shadow_dy: f64 = 0.0
    pub clip_radius: f64 = 0.0
    /// 0 butt, 1 round, 2 square.
    pub stroke_cap: int = 0
    /// 0 miter, 1 round, 2 bevel.
    pub stroke_join: int = 0
}
