// Generated from templates/combo_box_template.bx by latte. Do not edit.
//
// The <beans> block below is combo_box_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change combo_box_template.bx and regenerate:
//
//     latte generate templates/combo_box_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class ComboBoxTemplate extends compose.ChoiceControlTemplate {
    pub fn init() { super.init() }
}

partial class ComboBoxTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // combo_box_template.bx:1
        b.word("background", self.fill)
        b.number("corner_radius", (self.radius) as f64)
        b.open("Label")  // combo_box_template.bx:2
        b.text("{self.selected_text}")
        b.word("text_color", self.ink)
        b.number("font_size", (self.font_size) as f64)
        b.number("baseline", (self.baseline) as f64)
        b.number("x", (self.control_padding) as f64)
        b.number("y", (0) as f64)
        b.number("right", (self.chevron_inset + self.chevron_width + self.control_padding) as f64)
        b.number("height_percent", (100.0) as f64)
        b.close()
        b.open("Path")  // combo_box_template.bx:6
        b.number("right", (self.chevron_inset) as f64)
        b.number("y", ((self.control_height - self.chevron_block) / 2.0) as f64)
        b.number("width", (self.chevron_width) as f64)
        b.number("height", (self.chevron_height) as f64)
        b.text("M{self.chevron_stroke / 2.0} {self.chevron_height - self.chevron_stroke / 2.0} L{self.chevron_width / 2.0} {self.chevron_stroke / 2.0} L{self.chevron_width - self.chevron_stroke / 2.0} {self.chevron_height - self.chevron_stroke / 2.0}")
        b.word("stroke", self.ink)
        b.number("stroke_width", (self.chevron_stroke) as f64)
        b.word("stroke_cap", "round")
        b.word("stroke_join", "round")
        b.word("fill", "#00000000")
        b.close()
        b.open("Path")  // combo_box_template.bx:11
        b.number("right", (self.chevron_inset) as f64)
        b.number("y", ((self.control_height + self.chevron_block) / 2.0 - self.chevron_height) as f64)
        b.number("width", (self.chevron_width) as f64)
        b.number("height", (self.chevron_height) as f64)
        b.text("M{self.chevron_stroke / 2.0} {self.chevron_stroke / 2.0} L{self.chevron_width / 2.0} {self.chevron_height - self.chevron_stroke / 2.0} L{self.chevron_width - self.chevron_stroke / 2.0} {self.chevron_stroke / 2.0}")
        b.word("stroke", self.ink)
        b.number("stroke_width", (self.chevron_stroke) as f64)
        b.word("stroke_cap", "round")
        b.word("stroke_join", "round")
        b.word("fill", "#00000000")
        b.close()
        if self.focused {  // combo_box_template.bx:17
            b.open("Rectangle")  // combo_box_template.bx:18
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
