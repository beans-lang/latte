// Generated from templates/check_box_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is check_box_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change check_box_template.bx and regenerate:
//
//     latte-bx build templates/check_box_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class CheckBoxTemplate extends compose.ToggleControlTemplate {
    pub fn init() { super.init() }
}

partial class CheckBoxTemplate {
    pub override fn render(b: Builder) {
        b.open("HStack")  // check_box_template.bx:1
        b.number("spacing", (self.toggle_gap) as f64)
        b.word("align", "start")
        b.open("Box")  // check_box_template.bx:2
        b.number("width", (self.toggle_size) as f64)
        b.number("height", (self.toggle_size) as f64)
        b.word("background", if self.checked || self.mixed { self.accent_fill } else { self.track_off })
        b.number("corner_radius", (self.toggle_radius) as f64)
        if self.checked {  // check_box_template.bx:5
            b.open("Path")  // check_box_template.bx:8
            b.text("M{self.toggle_size * 0.22} {self.toggle_size * 0.49} L{self.toggle_size * 0.43} {self.toggle_size * 0.735} L{self.toggle_size * 0.72} {self.toggle_size * 0.285}")
            b.word("stroke", self.on_accent)
            b.number("stroke_width", (self.mark_stroke) as f64)
            b.word("stroke_cap", "round")
            b.word("stroke_join", "round")
            b.word("fill", "#00000000")
            b.close()
        }
        if self.mixed {  // check_box_template.bx:12
            b.open("Path")  // check_box_template.bx:13
            b.number("x", ((self.toggle_size - self.dash_width) / 2.0) as f64)
            b.number("y", ((self.toggle_size - self.dash_thickness) / 2.0) as f64)
            b.number("width", (self.dash_width) as f64)
            b.number("height", (self.dash_thickness) as f64)
            b.text("M{self.dash_thickness / 2.0} {self.dash_thickness / 2.0} L{self.dash_width - self.dash_thickness / 2.0} {self.dash_thickness / 2.0}")
            b.word("stroke", self.on_accent)
            b.number("stroke_width", (self.dash_thickness) as f64)
            b.word("stroke_cap", "round")
            b.word("fill", "#00000000")
            b.close()
        }
        b.close()
        b.open("Label")  // check_box_template.bx:21
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
