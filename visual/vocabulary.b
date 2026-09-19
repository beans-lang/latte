// Shared drawing vocabulary. Both the .bx compiler and the runtime read this file.
package visual

pub const FILL: int = 1101
pub const STROKE: int = 1102
pub const STROKE_WIDTH: int = 1103
pub const ROTATION: int = 1104
pub const SCALE_X: int = 1105
pub const SCALE_Y: int = 1106
pub const GRADIENT_START: int = 1107
pub const GRADIENT_END: int = 1108
pub const SHADOW_COLOR: int = 1109
pub const SHADOW_BLUR: int = 1110
pub const SHADOW_DX: int = 1111
pub const SHADOW_DY: int = 1112
pub const CLIP_RADIUS: int = 1113
pub const TRANSITION_SECONDS: int = 1114
pub const TRANSITION_EASING: int = 1115
pub const STROKE_CAP: int = 1116
pub const STROKE_JOIN: int = 1117
pub const OFFSET_X: int = 1118
pub const OFFSET_Y: int = 1119

pub enum Kind {
    rectangle
    ellipse
    path
    resource_image

    pub fn tag() -> string {
        return match self {
            rectangle => "Rectangle",
            ellipse => "Ellipse",
            path => "Path",
            resource_image => "ResourceImage",
        }
    }
}

pub fn kind_of(tag: string) -> Option<Kind> {
    if tag == "Rectangle" { return some(Kind.rectangle) }
    if tag == "Ellipse" { return some(Kind.ellipse) }
    if tag == "Path" { return some(Kind.path) }
    if tag == "ResourceImage" { return some(Kind.resource_image) }
    return none
}

pub fn is_tag(tag: string) -> bool { return kind_of(tag) != none }
pub fn tags() -> List<string> { return ["Ellipse", "Path", "Rectangle", "ResourceImage"] }
pub fn attribute_names() -> List<string> {
    return ["clip_radius", "d", "fill", "gradient_end", "gradient_start", "offset_x", "offset_y",
            "rotation", "scale_x", "scale_y", "shadow_blur", "shadow_color", "shadow_dx", "shadow_dy",
            "source", "stroke", "stroke_cap", "stroke_join", "stroke_width",
            "transition_easing", "transition_seconds"]
}
pub fn attribute_note(name: string) -> string {
    if name == "d" { return "SVG path data for Path" }
    if name == "fill" { return "fill colour for a drawing shape" }
    if name == "stroke" { return "outline colour for a drawing shape" }
    if name == "stroke_width" { return "outline width for a drawing shape" }
    if name == "stroke_cap" { return "butt, round or square ends on an open stroke" }
    if name == "stroke_join" { return "miter, round or bevel corners on a stroke" }
    if name == "rotation" { return "shape rotation in degrees" }
    if name == "offset_x" || name == "offset_y" { return "points the drawing moves from its layout box" }
    if name == "scale_x" || name == "scale_y" { return "positive shape scale" }
    if name == "gradient_start" { return "top colour of a vertical linear fill gradient" }
    if name == "gradient_end" { return "bottom colour of a vertical linear fill gradient" }
    if name == "shadow_color" { return "colour of a shape's drop shadow" }
    if name == "shadow_blur" { return "shadow blur radius in points" }
    if name == "shadow_dx" || name == "shadow_dy" { return "shadow offset in points" }
    if name == "clip_radius" { return "rounded clip radius for the drawing bounds" }
    if name == "source" { return "local image file path for ResourceImage" }
    if name == "transition_seconds" { return "seconds to animate later visual property changes; initial mount is immediate" }
    if name == "transition_easing" { return "linear or ease_in_out timing for later visual changes" }
    return ""
}
pub fn attribute_call(name: string) -> string {
    if name == "d" || name == "source" { return "text" }
    if name == "transition_easing" { return "word" }
    if name == "stroke_cap" || name == "stroke_join" { return "word" }
    if name == "fill" || name == "stroke" || name == "gradient_start" ||
       name == "gradient_end" || name == "shadow_color" { return "word" }
    if name == "stroke_width" || name == "rotation" || name == "scale_x" || name == "scale_y" ||
       name == "shadow_blur" || name == "shadow_dx" || name == "shadow_dy" ||
       name == "clip_radius" || name == "transition_seconds" ||
       name == "offset_x" || name == "offset_y" {
        return "number"
    }
    return ""
}
pub fn property_of(name: string) -> int {
    if name == "fill" { return FILL }
    if name == "stroke" { return STROKE }
    if name == "stroke_width" { return STROKE_WIDTH }
    if name == "rotation" { return ROTATION }
    if name == "scale_x" { return SCALE_X }
    if name == "scale_y" { return SCALE_Y }
    if name == "gradient_start" { return GRADIENT_START }
    if name == "gradient_end" { return GRADIENT_END }
    if name == "shadow_color" { return SHADOW_COLOR }
    if name == "shadow_blur" { return SHADOW_BLUR }
    if name == "shadow_dx" { return SHADOW_DX }
    if name == "shadow_dy" { return SHADOW_DY }
    if name == "clip_radius" { return CLIP_RADIUS }
    if name == "transition_seconds" { return TRANSITION_SECONDS }
    if name == "transition_easing" { return TRANSITION_EASING }
    if name == "stroke_cap" { return STROKE_CAP }
    if name == "stroke_join" { return STROKE_JOIN }
    if name == "offset_x" { return OFFSET_X }
    if name == "offset_y" { return OFFSET_Y }
    return -1
}
pub fn is_colour(name: string) -> bool {
    return name == "fill" || name == "stroke" || name == "gradient_start" ||
           name == "gradient_end" || name == "shadow_color"
}
pub fn carries(kind: Kind, name: string) -> bool {
    if name == "hidden" { return true }
    // A drawing's painted box can reach past its layout box, the same way a
    // control's can: a slider knob is taller than the track it sits on.
    if name == "overhang" { return true }
    // A drawn rectangle rounds its corners; the other kinds have their own shape.
    if name == "corner_radius" { return kind == Kind.rectangle }
    if attribute_call(name) == "" { return false }
    if name == "d" { return kind == Kind.path }
    if name == "source" { return kind == Kind.resource_image }
    if kind == Kind.resource_image {
        return name == "clip_radius" || name == "rotation" || name == "scale_x" || name == "scale_y" ||
               name == "offset_x" || name == "offset_y" ||
               name == "transition_seconds" || name == "transition_easing"
    }
    return true
}

/// A stroke's ends: 0 butt, 1 round, 2 square. AppKit's own glyphs are drawn
/// with round ends, so a butt-capped copy of one reads as a different mark.
pub fn cap_code(name: string) -> int {
    if name == "butt" { return 0 }
    if name == "round" { return 1 }
    if name == "square" { return 2 }
    return -1
}
/// A stroke's corners: 0 miter, 1 round, 2 bevel.
pub fn join_code(name: string) -> int {
    if name == "miter" { return 0 }
    if name == "round" { return 1 }
    if name == "bevel" { return 2 }
    return -1
}

pub fn easing_code(name: string) -> int {
    if name == "linear" { return 0 }
    if name == "ease_in_out" { return 1 }
    return -1
}
