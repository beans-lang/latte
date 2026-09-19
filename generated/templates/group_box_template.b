// Generated from templates/group_box_template.bx by latte. Do not edit.
//
// The <beans> block below is group_box_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change group_box_template.bx and regenerate:
//
//     latte generate templates/group_box_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class GroupBoxTemplate extends compose.ControlTemplate {
    pub fn init() { super.init() }
}

partial class GroupBoxTemplate {
    pub override fn render(b: Builder) {
        b.open("VStack")  // group_box_template.bx:1
        b.word("background", self.card)
        b.number("corner_radius", (self.radius) as f64)
        b.number("padding", (6) as f64)
        b.number("border_width", (1) as f64)
        b.word("border_color", self.separator)
        b.word("align", "stretch")
        b.open("Label")  // group_box_template.bx:3
        b.text("{self.title}")
        b.word("text_color", self.muted)
        b.number("font_size", (self.footnote) as f64)
        b.close()
        b.close()
    }
}
