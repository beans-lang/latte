// Generated from templates/slider_template.bx by latte. Do not edit.
//
// The <beans> block below is slider_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change slider_template.bx and regenerate:
//
//     latte generate templates/slider_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class SliderTemplate extends compose.RangeControlTemplate {
    pub fn init() { super.init() }
}

partial class SliderTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // slider_template.bx:1
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.open("Box")  // slider_template.bx:2
        b.number("y", ((self.slider_height - self.slider_track) / 2.0) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height", (self.slider_track) as f64)
        b.word("background", self.track_off)
        b.number("corner_radius", (self.capsule) as f64)
        b.close()
        b.open("Box")  // slider_template.bx:6
        b.number("y", ((self.slider_height - self.slider_track) / 2.0) as f64)
        b.number("width", (self.thumb_leading) as f64)
        b.number("height", (self.slider_track) as f64)
        b.word("background", self.accent_fill)
        b.number("corner_radius", (self.capsule) as f64)
        b.close()
        b.open("Rectangle")  // slider_template.bx:11
        b.number("x", (self.thumb_leading) as f64)
        b.number("y", ((self.slider_height - self.slider_knob_height) / 2.0) as f64)
        b.number("width", (self.slider_knob) as f64)
        b.number("height", (self.slider_knob_height) as f64)
        b.number("corner_radius", (self.slider_knob_height / 2.0) as f64)
        b.number("overhang", (self.slider_overhang) as f64)
        b.word("fill", self.knob)
        b.word("shadow_color", self.knob_shadow)
        b.number("shadow_blur", (1.5) as f64)
        b.number("shadow_dy", (0.5) as f64)
        b.close()
        b.close()
    }
}
