// Generated from examples/showcase/site/drawing_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is drawing_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change drawing_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/drawing_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import {view} from latte.annotations

@view
pub partial class DrawingPage extends compose.Component {
    pub lit: bool = false
    pub hue: f64 = 30.0

    pub fn init() { super.init() }

    pub fn flip() { self.lit = !self.lit; self.request_render() }

    pub fn set_lit(value: int) { self.lit = value == 1; self.request_render() }

    pub fn set_hue(value: int) { self.hue = value as f64; self.request_render() }

    /// A colour built in Beans rather than picked from a list, so the
    /// transition has somewhere to go on every step of the slider.
    pub fn shade() -> string {
        let red: int = 40 + (self.hue * 2.0) as int
        let green: int = 90
        let blue: int = 220 - (self.hue * 1.6) as int
        return "#{two(red)}{two(green)}{two(blue)}"
    }
}

/// One byte as two hex digits. Beans has no hex formatting, and a colour is
/// written the way a stylesheet writes one.
fn two(value: int) -> string {
    var clamped: int = value
    if clamped < 0 { clamped = 0 }
    if clamped > 255 { clamped = 255 }
    let digits: string = "0123456789abcdef"
    return "{digits.slice(clamped / 16, clamped / 16 + 1)}{digits.slice(clamped % 16, clamped % 16 + 1)}"
}

partial class DrawingPage {
    pub override fn render(b: Builder) {
        b.open("ScrollView")  // drawing_page.bx:1
        b.number("height", (520) as f64)
        b.open("VStack")  // drawing_page.bx:2
        b.number("padding", (20) as f64)
        b.number("spacing", (14) as f64)
        b.word("align", "stretch")
        b.open("Label")  // drawing_page.bx:3
        b.text("Drawing and motion")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // drawing_page.bx:4
        b.text("Shapes, gradients, shadows and transitions, all from markup.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("HStack")  // drawing_page.bx:6
        b.number("spacing", (14) as f64)
        b.word("align", "center")
        b.open("Box")  // drawing_page.bx:7
        b.number("width", (90) as f64)
        b.number("height", (60) as f64)
        b.open("Rectangle")  // drawing_page.bx:8
        b.word("fill", "#2f6f4f")
        b.number("clip_radius", (10) as f64)
        b.close()
        b.close()
        b.open("Box")  // drawing_page.bx:10
        b.number("width", (90) as f64)
        b.number("height", (60) as f64)
        b.open("Ellipse")  // drawing_page.bx:11
        b.word("fill", "#365eea")
        b.word("stroke", "#101828")
        b.number("stroke_width", (2) as f64)
        b.close()
        b.close()
        b.open("Box")  // drawing_page.bx:13
        b.number("width", (90) as f64)
        b.number("height", (60) as f64)
        b.open("Rectangle")  // drawing_page.bx:14
        b.word("gradient_start", "#d5a665")
        b.word("gradient_end", "#87582f")
        b.number("clip_radius", (8) as f64)
        b.word("shadow_color", "#00000055")
        b.number("shadow_blur", (10) as f64)
        b.number("shadow_dy", (3) as f64)
        b.close()
        b.close()
        b.open("Box")  // drawing_page.bx:17
        b.number("width", (90) as f64)
        b.number("height", (60) as f64)
        b.open("Path")  // drawing_page.bx:18
        b.text("M10 50 L45 10 L80 50 Z")
        b.word("fill", "#b03030")
        b.word("stroke", "#5a1414")
        b.number("stroke_width", (2) as f64)
        b.close()
        b.close()
        b.close()
        b.open("Separator")  // drawing_page.bx:22
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // drawing_page.bx:24
        b.text("A transition runs in Beans, one frame at a time.")
        b.close()
        b.open("HStack")  // drawing_page.bx:25
        b.number("spacing", (14) as f64)
        b.word("align", "center")
        b.open("Box")  // drawing_page.bx:26
        b.key("{"fade"}")
        b.number("width", (140) as f64)
        b.number("height", (54) as f64)
        b.open("Rectangle")  // drawing_page.bx:27
        b.word("fill", if self.lit { "#365eea" } else { "#c7ccd8" })
        b.number("clip_radius", (12) as f64)
        b.number("transition_seconds", (0.35) as f64)
        b.word("transition_easing", "ease_in_out")
        b.close()
        b.close()
        b.open("Button")  // drawing_page.bx:31
        b.key("{"toggle"}")
        b.text("{if self.lit { "Fade out" } else { "Fade in" }}")
        b.on("click", fn(e: UiEvent) { self.flip() })
        b.close()
        b.open("Switch")  // drawing_page.bx:33
        b.key("{"lit"}")
        b.flag("checked", self.lit)
        b.on("change", fn(e: UiEvent) { self.set_lit(e.index) })
        b.close()
        b.close()
        b.open("Separator")  // drawing_page.bx:37
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // drawing_page.bx:39
        b.text("A canvas control with a shape inside it is an ordinary control: it lays out, it takes a frame, and it can be named for a screen reader.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("Box")  // drawing_page.bx:40
        b.key("{"badge"}")
        b.number("width", (120) as f64)
        b.number("height", (120) as f64)
        b.a11y_label("A round badge")
        b.open("Ellipse")  // drawing_page.bx:41
        b.word("fill", self.shade())
        b.word("stroke", "#101828")
        b.number("stroke_width", (3) as f64)
        b.number("transition_seconds", (0.5) as f64)
        b.word("transition_easing", "linear")
        b.close()
        b.close()
        b.open("Slider")  // drawing_page.bx:44
        b.key("{"hue"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.hue) as f64)
        b.number("step", (1.0) as f64)
        b.on("change", fn(e: UiEvent) { self.set_hue(e.index) })
        b.close()
        b.close()
        b.close()
    }
}
