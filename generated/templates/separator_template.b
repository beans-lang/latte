// Generated from templates/separator_template.bx by latte. Do not edit.
//
// The <beans> block below is separator_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change separator_template.bx and regenerate:
//
//     latte generate templates/separator_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class SeparatorTemplate extends compose.ControlTemplate {
    pub fn init() { super.init() }
}

partial class SeparatorTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // separator_template.bx:1
        b.word("background", self.separator)
        b.close()
    }
}
