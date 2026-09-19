// Generated from templates/level_indicator_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is level_indicator_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change level_indicator_template.bx and regenerate:
//
//     latte-bx build templates/level_indicator_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import {view} from latte.annotations
@view
pub partial class LevelIndicatorTemplate extends compose.RangeControlTemplate {
    pub fn init() { super.init() }
}

partial class LevelIndicatorTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // level_indicator_template.bx:1
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        var _latte_row_0: int = 0
        for index in 0..self.level_cells {  // level_indicator_template.bx:2
            b.open("Box")  // level_indicator_template.bx:5
            b.key("{"cell-{index}"}")
            b.number("x", (index as f64 * (self.level_cell_width + self.level_cell_gap)) as f64)
            b.number("y", (0) as f64)
            b.number("width", (self.level_cell_width) as f64)
            b.number("height", (self.level_cell_height) as f64)
            b.number("corner_radius", (self.level_cell_radius) as f64)
            b.word("background", if (index as f64 + 1.0) * (100.0 / self.level_cells as f64) <= self.percent + 0.001 { self.level_fill } else { self.level_empty })
            b.number("border_width", (self.hairline_width / 2.0) as f64)
            b.word("border_color", if (index as f64 + 1.0) * (100.0 / self.level_cells as f64) <= self.percent + 0.001 { self.level_fill_border } else { self.level_border })
            b.close()
            _latte_row_0 += 1
        }
        b.close()
    }
}
