// Generated from templates/radio_button_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is radio_button_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change radio_button_template.bx and regenerate:
//
//     latte-bx build templates/radio_button_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class RadioButtonTemplate extends compose.ToggleControlTemplate {
    pub fn init() { super.init() }
}

partial class RadioButtonTemplate {
    pub override fn render(b: Builder) {
        b.open("HStack")  // radio_button_template.bx:1
        b.number("spacing", (self.toggle_gap) as f64)
        b.word("align", "start")
        b.open("Box")  // radio_button_template.bx:2
        b.number("width", (self.toggle_size) as f64)
        b.number("height", (self.toggle_size) as f64)
        b.word("background", if self.checked { self.accent_fill } else { self.track_off })
        b.number("corner_radius", (self.capsule) as f64)
        if self.checked {  // radio_button_template.bx:5
            b.open("Ellipse")  // radio_button_template.bx:8
            b.number("width_percent", (100.0) as f64)
            b.number("height_percent", (100.0) as f64)
            b.number("scale_x", (self.radio_dot / self.toggle_size) as f64)
            b.number("scale_y", (self.radio_dot / self.toggle_size) as f64)
            b.word("fill", self.on_accent)
            b.close()
        }
        b.close()
        b.open("Label")  // radio_button_template.bx:13
        b.text("{self.title}")
        b.word("text_color", self.ink)
        b.number("font_size", (self.font_size) as f64)
        b.number("baseline", (self.toggle_baseline) as f64)
        b.number("grow", (1) as f64)
        b.number("height", (self.toggle_size) as f64)
        b.close()
        b.close()
    }
}
