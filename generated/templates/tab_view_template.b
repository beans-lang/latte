// Generated from templates/tab_view_template.bx by latte. Do not edit.
//
// The <beans> block below is tab_view_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change tab_view_template.bx and regenerate:
//
//     latte generate templates/tab_view_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class TabViewTemplate extends compose.TabControlTemplate {
    pub fn init() { super.init() }
}

partial class TabViewTemplate {
    pub override fn render(b: Builder) {
        b.open("VStack")  // tab_view_template.bx:1
        b.word("background", self.card)
        b.word("border_color", self.separator)
        b.number("border_width", (self.hairline_width) as f64)
        b.number("corner_radius", (self.radius) as f64)
        b.word("align", "stretch")
        if !self.borderless {  // tab_view_template.bx:3
            b.open("HStack")  // tab_view_template.bx:6
            b.number("height", (self.control_height + self.spacing) as f64)
            b.word("align", "center")
            b.word("justify", "center")
            b.open("Box")  // tab_view_template.bx:7
            b.word("background", self.surface)
            b.number("corner_radius", (self.radius) as f64)
            b.number("width", (self.row_width) as f64)
            b.number("height", (self.control_height) as f64)
            b.number("shrink", (0) as f64)
            if self.selection_width > 0.0 {  // tab_view_template.bx:9
                b.open("Rectangle")  // tab_view_template.bx:10
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
            for index in 0..self.labels.len() {  // tab_view_template.bx:16
                b.open("Label")  // tab_view_template.bx:17
                b.key("{"tab-{index}"}")
                b.text("{self.labels[index]}")
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
            b.close()
        }
        b.close()
    }
}
