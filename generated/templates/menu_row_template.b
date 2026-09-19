// Generated from templates/menu_row_template.bx by latte. Do not edit.
//
// The <beans> block below is menu_row_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change menu_row_template.bx and regenerate:
//
//     latte generate templates/menu_row_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class MenuRowTemplate extends compose.MenuRowControlTemplate {
    pub fn init() { super.init() }
}

partial class MenuRowTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // menu_row_template.bx:1
        b.word("background", if self.prominent { self.accent_fill } else { self.clear })
        b.number("corner_radius", (self.menu_row_radius) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        if self.checked {  // menu_row_template.bx:4
            b.open("Path")  // menu_row_template.bx:6
            b.number("x", (self.menu_mark_inset - self.menu_row_inset) as f64)
            b.number("y", ((self.menu_row_height - self.menu_mark_height) / 2.0) as f64)
            b.number("width", (self.menu_mark_width) as f64)
            b.number("height", (self.menu_mark_height) as f64)
            b.text("M{self.menu_mark_stroke / 2.0} {self.menu_mark_height * 0.52} L{self.menu_mark_width * 0.3} {self.menu_mark_height - self.menu_mark_stroke / 2.0} L{self.menu_mark_width - self.menu_mark_stroke / 2.0} {self.menu_mark_stroke / 2.0}")
            b.word("stroke", if self.prominent { self.on_accent } else { self.ink })
            b.number("stroke_width", (self.menu_mark_stroke) as f64)
            b.word("stroke_cap", "round")
            b.word("stroke_join", "round")
            b.word("fill", "#00000000")
            b.close()
        }
        b.open("Label")  // menu_row_template.bx:14
        b.text("{self.title}")
        b.word("text_color", if self.prominent { self.on_accent } else if self.enabled { self.ink } else { self.faint })
        b.number("font_size", (self.menu_font_size) as f64)
        b.number("baseline", (self.menu_baseline) as f64)
        b.number("x", (self.menu_text_inset - self.menu_row_inset) as f64)
        b.number("right", (self.menu_trailing - self.menu_row_inset) as f64)
        b.number("height_percent", (100.0) as f64)
        b.close()
        b.close()
    }
}
