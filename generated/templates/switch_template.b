// Generated from templates/switch_template.bx by latte. Do not edit.
//
// The <beans> block below is switch_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change switch_template.bx and regenerate:
//
//     latte generate templates/switch_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class SwitchTemplate extends compose.ToggleControlTemplate {
    pub fn init() { super.init() }
}

partial class SwitchTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // switch_template.bx:1
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.open("Rectangle")  // switch_template.bx:2
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.number("corner_radius", (self.switch_height / 2.0) as f64)
        b.number("transition_seconds", (if self.pressed { 0.0 } else { self.motion_switch }) as f64)
        b.word("transition_easing", "ease_in_out")
        b.word("fill", if self.checked { self.accent_fill } else { self.track_off })
        b.close()
        b.open("Rectangle")  // switch_template.bx:9
        b.number("x", (self.switch_inset) as f64)
        b.number("y", (self.switch_inset) as f64)
        b.number("width", (self.switch_knob_width) as f64)
        b.number("height", (self.switch_knob_height) as f64)
        b.number("offset_x", (if self.checked { self.switch_travel } else { 0.0 }) as f64)
        b.number("corner_radius", (self.switch_knob_height / 2.0) as f64)
        b.number("transition_seconds", (if self.pressed { 0.0 } else { self.motion_switch }) as f64)
        b.word("transition_easing", "ease_in_out")
        b.word("fill", self.knob)
        b.word("shadow_color", self.knob_shadow)
        b.number("shadow_blur", (1.5) as f64)
        b.number("shadow_dy", (0.5) as f64)
        b.close()
        b.close()
    }
}
