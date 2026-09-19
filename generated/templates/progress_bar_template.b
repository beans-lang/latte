// Generated from templates/progress_bar_template.bx by latte. Do not edit.
//
// The <beans> block below is progress_bar_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls.
// Change progress_bar_template.bx and regenerate:
//
//     latte generate templates/progress_bar_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class ProgressBarTemplate extends compose.RangeControlTemplate {
    pub fn init() { super.init() }
}

partial class ProgressBarTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // progress_bar_template.bx:1
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.open("Box")  // progress_bar_template.bx:2
        b.number("y", ((self.bar_control_height - self.bar_height) / 2.0) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height", (self.bar_height) as f64)
        b.word("background", self.bar_track)
        b.number("border_width", (0.5) as f64)
        b.word("border_color", self.bar_border)
        b.number("corner_radius", (self.bar_radius) as f64)
        b.close()
        b.open("Box")  // progress_bar_template.bx:6
        b.number("y", ((self.bar_control_height - self.bar_height) / 2.0) as f64)
        b.number("width_percent", (if self.indeterminate { 35.0 } else { self.percent }) as f64)
        b.number("height", (self.bar_height) as f64)
        b.word("background", self.accent)
        b.number("corner_radius", (self.bar_radius) as f64)
        b.close()
        b.close()
    }
}
