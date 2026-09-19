// Generated from templates/segmented_template.bx by latte. Do not edit.
//
// The <beans> block below is segmented_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change segmented_template.bx and regenerate:
//
//     latte generate templates/segmented_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class SegmentedTemplate extends compose.ChoiceControlTemplate {
    pub fn init() { super.init() }
}

partial class SegmentedTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // segmented_template.bx:1
        b.word("background", self.surface)
        b.number("corner_radius", (self.radius) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        if self.selection_width > 0.0 {  // segmented_template.bx:5
            b.open("Rectangle")  // segmented_template.bx:6
            b.number("x", (0) as f64)
            b.number("y", (0) as f64)
            b.number("width", (self.selection_width) as f64)
            b.number("height_percent", (100.0) as f64)
            b.number("offset_x", (self.selection_x) as f64)
            b.number("corner_radius", (self.radius) as f64)
            b.word("fill", self.selection_fill)
            b.number("transition_seconds", (self.motion_selection) as f64)
            b.word("transition_easing", "ease_in_out")
            b.close()
        }
        var _cortado_row_0: int = 0
        for index in 0..self.choices.len() {  // segmented_template.bx:12
            b.open("Label")  // segmented_template.bx:13
            b.key("{"segment-{index}"}")
            b.text("{self.choices[index]}")
            b.number("x", (self.item_x[index]) as f64)
            b.number("y", (0) as f64)
            b.number("width", (self.item_width[index]) as f64)
            b.number("height_percent", (100.0) as f64)
            b.word("text_color", if self.selected == index && self.active { self.on_accent } else { self.ink })
            b.number("font_weight", (if self.selected == index { self.selected_weight } else { 0 }) as f64)
            b.word("background", self.clear)
            b.number("font_size", (self.font_size) as f64)
            b.number("baseline", (self.baseline) as f64)
            b.number("alignment", (1) as f64)
            b.close()
            _cortado_row_0 += 1
        }
        b.close()
    }
}
