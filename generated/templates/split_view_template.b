// Generated from templates/split_view_template.bx by latte. Do not edit.
//
// The <beans> block below is split_view_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change split_view_template.bx and regenerate:
//
//     latte generate templates/split_view_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class SplitViewTemplate extends compose.SplitControlTemplate {
    pub fn init() { super.init() }
}

partial class SplitViewTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // split_view_template.bx:1
        b.word("background", self.card)
        if self.stacked {  // split_view_template.bx:2
            b.open("Box")  // split_view_template.bx:3
            b.number("y", (self.divider_half) as f64)
            b.number("height", (1) as f64)
            b.number("width_percent", (100.0) as f64)
            b.word("background", self.separator)
            b.close()
        }
        if !self.stacked {  // split_view_template.bx:5
            b.open("Box")  // split_view_template.bx:6
            b.number("x", (self.divider_half) as f64)
            b.number("width", (1) as f64)
            b.number("height_percent", (100.0) as f64)
            b.word("background", self.separator)
            b.close()
        }
        b.close()
    }
}
