// Generated from examples/showcase/site/panes_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is panes_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change panes_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/panes_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import {view} from latte.annotations

@view
pub partial class PanesPage extends compose.Component {
    pub sections: List<string> = ["Orders", "Roasts", "People"]
    pub tabs: List<string> = ["About", "Rows", "Notes"]
    pub chosen: string = "Orders"
    pub tab: int = 0
    pub divider: f64 = 180.0

    pub fn init() { super.init() }

    pub fn choose(name: string) { self.chosen = name; self.request_render() }
    pub fn choose_tab(index: int) { self.tab = index; self.request_render() }
}

partial class PanesPage {
    pub override fn render(b: Builder) {
        b.open("VStack")  // panes_page.bx:1
        b.number("padding", (20) as f64)
        b.number("spacing", (10) as f64)
        b.word("align", "stretch")
        b.open("Label")  // panes_page.bx:2
        b.text("Panes and pages")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // panes_page.bx:3
        b.text("A split view, a tab view, and a scrolling list — the containers a real screen is made of.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("SplitView")  // panes_page.bx:5
        b.key("{"split"}")
        b.flag("stacked", false)
        b.number("divider", (self.divider) as f64)
        b.number("height", (200) as f64)
        b.open("VStack")  // panes_page.bx:6
        b.number("padding", (10) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.word("background", "#f6f6f8")
        b.open("Label")  // panes_page.bx:7
        b.text("Sidebar")
        b.number("font_weight", (5) as f64)
        b.close()
        var _latte_row_0: int = 0
        for name in self.sections {  // panes_page.bx:8
            b.open("Button")  // panes_page.bx:9
            b.key("{"section-{name}"}")
            b.text("{name}")
            b.on("click", fn(e: UiEvent) { self.choose(name) })
            b.close()
            _latte_row_0 += 1
        }
        b.close()
        b.open("VStack")  // panes_page.bx:13
        b.number("padding", (10) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // panes_page.bx:14
        b.key("{"chosen"}")
        b.text("Showing: {self.chosen}")
        b.number("font_weight", (5) as f64)
        b.close()
        b.open("Label")  // panes_page.bx:15
        b.text("The divider is a number in Beans, so a test can put it anywhere.")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.close()
        b.open("TabView")  // panes_page.bx:19
        b.key("{"tabs"}")
        b.labels(self.tabs)
        b.number("selected", (self.tab) as f64)
        b.number("height", (180) as f64)
        b.on("change", fn(e: UiEvent) { self.choose_tab(e.index) })
        b.open("VStack")  // panes_page.bx:21
        b.number("padding", (12) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // panes_page.bx:22
        b.text("Beans owns the layout.")
        b.close()
        b.open("Label")  // panes_page.bx:23
        b.text("A tab's page is laid out only while it is showing.")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.open("ScrollView")  // panes_page.bx:25
        b.number("height", (140) as f64)
        b.open("VStack")  // panes_page.bx:26
        b.number("padding", (8) as f64)
        b.number("spacing", (8) as f64)
        b.word("align", "stretch")
        var _latte_row_1: int = 0
        for row in 0..40 {  // panes_page.bx:27
            b.open("HStack")  // panes_page.bx:28
            b.key("{"row-{row}"}")
            b.number("padding", (8) as f64)
            b.number("spacing", (10) as f64)
            b.word("background", "#ffffff")
            b.number("corner_radius", (8) as f64)
            b.number("border_width", (1) as f64)
            b.word("border_color", "#e4e4ea")
            b.open("Label")  // panes_page.bx:30
            b.text("Row {row}")
            b.number("grow", (1) as f64)
            b.close()
            b.open("Label")  // panes_page.bx:31
            b.text("{if row % 3 == 0 { "ready" } else { "waiting" }}")
            b.word("text_color", if row % 3 == 0 { "#2f6f4f" } else { "#8a8f9c" })
            b.close()
            b.close()
            _latte_row_1 += 1
        }
        b.close()
        b.close()
        b.open("VStack")  // panes_page.bx:37
        b.number("padding", (12) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // panes_page.bx:38
        b.text("Three pages, one selected index.")
        b.close()
        b.close()
        b.close()
        b.close()
    }
}
