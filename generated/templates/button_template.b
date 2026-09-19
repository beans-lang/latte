// Generated from templates/button_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is button_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change button_template.bx and regenerate:
//
//     latte-bx build templates/button_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               

import latte.compose
import {view} from latte.annotations

@view
pub partial class ButtonTemplate extends compose.ControlTemplate {
    pub fn init() { super.init() }
}

partial class ButtonTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // button_template.bx:1
        b.word("background", if self.prominent { self.accent_fill } else { self.fill })
        b.number("corner_radius", (self.radius) as f64)
        b.open("Label")  // button_template.bx:3
        b.text("{self.title}")
        b.word("text_color", if self.prominent { self.on_accent } else { self.ink })
        b.number("font_size", (self.font_size) as f64)
        b.number("font_weight", (self.font_weight) as f64)
        b.number("baseline", (self.baseline) as f64)
        b.number("alignment", (1) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.close()
        if self.focused {  // button_template.bx:8
            b.open("Rectangle")  // button_template.bx:9
            b.number("x", (0) as f64)
            b.number("y", (0) as f64)
            b.number("width_percent", (100.0) as f64)
            b.number("height_percent", (100.0) as f64)
            b.number("overhang", (self.focus_width / 2.0) as f64)
            b.number("corner_radius", (self.radius + self.focus_width / 2.0) as f64)
            b.word("fill", "#00000000")
            b.word("stroke", self.focus_ring)
            b.number("stroke_width", (self.focus_width) as f64)
            b.close()
        }
        b.close()
    }
}
