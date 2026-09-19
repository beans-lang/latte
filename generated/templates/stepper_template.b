// Generated from templates/stepper_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is stepper_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change stepper_template.bx and regenerate:
//
//     latte-bx build templates/stepper_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class StepperTemplate extends compose.RangeControlTemplate {
    pub fn init() { super.init() }
}

partial class StepperTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // stepper_template.bx:1
        b.word("background", self.surface)
        b.number("corner_radius", (self.radius) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.open("Path")  // stepper_template.bx:5
        b.number("x", ((self.stepper_width - self.stepper_glyph_width) / 2.0) as f64)
        b.number("y", (self.stepper_glyph_top) as f64)
        b.number("width", (self.stepper_glyph_width) as f64)
        b.number("height", (self.stepper_glyph_height) as f64)
        b.text("M{self.stepper_stroke / 2.0} {self.stepper_glyph_height - self.stepper_stroke / 2.0} L{self.stepper_glyph_width / 2.0} {self.stepper_stroke / 2.0} L{self.stepper_glyph_width - self.stepper_stroke / 2.0} {self.stepper_glyph_height - self.stepper_stroke / 2.0}")
        b.word("stroke", self.ink)
        b.number("stroke_width", (self.stepper_stroke) as f64)
        b.word("stroke_cap", "round")
        b.word("stroke_join", "round")
        b.word("fill", "#00000000")
        b.close()
        b.open("Box")  // stepper_template.bx:11
        b.number("x", (self.stepper_divider_inset) as f64)
        b.number("y", ((self.stepper_height - self.stepper_divider_height) / 2.0) as f64)
        b.number("width", (self.stepper_width - self.stepper_divider_inset * 2.0) as f64)
        b.number("height", (self.stepper_divider_height) as f64)
        b.word("background", self.stepper_divider)
        b.close()
        b.open("Path")  // stepper_template.bx:16
        b.number("x", ((self.stepper_width - self.stepper_glyph_width) / 2.0) as f64)
        b.number("y", (self.stepper_height - self.stepper_glyph_bottom - self.stepper_glyph_height) as f64)
        b.number("width", (self.stepper_glyph_width) as f64)
        b.number("height", (self.stepper_glyph_height) as f64)
        b.text("M{self.stepper_stroke / 2.0} {self.stepper_stroke / 2.0} L{self.stepper_glyph_width / 2.0} {self.stepper_glyph_height - self.stepper_stroke / 2.0} L{self.stepper_glyph_width - self.stepper_stroke / 2.0} {self.stepper_stroke / 2.0}")
        b.word("stroke", self.ink)
        b.number("stroke_width", (self.stepper_stroke) as f64)
        b.word("stroke_cap", "round")
        b.word("stroke_join", "round")
        b.word("fill", "#00000000")
        b.close()
        b.close()
    }
}
