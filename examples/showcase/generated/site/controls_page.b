// Generated from examples/showcase/site/controls_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is controls_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change controls_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/controls_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import {view} from latte.annotations

@view
pub partial class ControlsPage extends compose.Component {
    pub milk: int = 0
    pub size: int = 0
    pub notify: int = 1
    pub intensity: f64 = 40.0
    pub shots: f64 = 2.0
    pub roast: int = 1
    pub grind: int = 0
    pub details: int = 0
    pub notes: int = 0
    pub roasts: List<string> = ["Light", "Medium", "Dark"]
    pub grinds: List<string> = ["Fine", "Medium", "Coarse"]

    pub fn init() { super.init() }

    pub fn set_milk(value: int) { self.milk = value; self.request_render() }
    pub fn set_notify(value: int) { self.notify = value; self.request_render() }
    pub fn set_details(value: int) { self.details = value; self.request_render() }
    pub fn note() { self.notes = self.notes + 1; self.request_render() }
    pub fn slide(value: int) { self.intensity = value as f64; self.request_render() }
    pub fn step(value: int) { self.shots = value as f64; self.request_render() }
    pub fn choose_roast(index: int) { self.roast = index; self.request_render() }
    pub fn choose_grind(index: int) { self.grind = index; self.request_render() }

    /// A radio group is two controls and one fact. The `change` a radio raises
    /// says whether *it* is now on, so the one that switched off raises one
    /// too — and acting on that would clear the choice the other just made.
    pub fn choose(which: int, on: int) {
        if on != 1 { return }
        self.size = which
        self.request_render()
    }

    pub fn summary() -> string {
        let milk: string = if self.milk == 1 { "with milk" } else { "black" }
        let size: string = if self.size == 1 { "large" } else { "small" }
        return "{size}, {milk}, {self.shots as int} shot(s), {self.roasts[self.roast]} roast, {self.grinds[self.grind]} grind, {self.notes} note(s)"
    }
}

partial class ControlsPage {
    pub override fn render(b: Builder) {
        b.open("ScrollView")  // controls_page.bx:1
        b.number("height", (520) as f64)
        b.open("VStack")  // controls_page.bx:2
        b.number("padding", (20) as f64)
        b.number("spacing", (12) as f64)
        b.word("align", "stretch")
        b.open("Label")  // controls_page.bx:3
        b.text("Controls")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // controls_page.bx:4
        b.text("Every control below is drawn by Latte from a .bx template.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("CheckBox")  // controls_page.bx:6
        b.key("{"milk"}")
        b.text("Include milk")
        b.flag("checked", self.milk == 1)
        b.on("change", fn(e: UiEvent) { self.set_milk(e.index) })
        b.close()
        b.open("HStack")  // controls_page.bx:8
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.open("RadioButton")  // controls_page.bx:9
        b.key("{"small"}")
        b.text("Small")
        b.flag("checked", self.size == 0)
        b.on("change", fn(e: UiEvent) { self.choose(0, e.index) })
        b.close()
        b.open("RadioButton")  // controls_page.bx:11
        b.key("{"large"}")
        b.text("Large")
        b.flag("checked", self.size == 1)
        b.on("change", fn(e: UiEvent) { self.choose(1, e.index) })
        b.close()
        b.close()
        b.open("HStack")  // controls_page.bx:15
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.open("Label")  // controls_page.bx:16
        b.text("Notifications")
        b.number("grow", (1) as f64)
        b.close()
        b.open("Switch")  // controls_page.bx:17
        b.key("{"notify"}")
        b.flag("checked", self.notify == 1)
        b.on("change", fn(e: UiEvent) { self.set_notify(e.index) })
        b.close()
        b.close()
        b.open("Label")  // controls_page.bx:21
        b.key("{"intensity-label"}")
        b.text("Intensity {self.intensity}")
        b.close()
        b.open("Slider")  // controls_page.bx:22
        b.key("{"intensity"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.intensity) as f64)
        b.number("step", (5.0) as f64)
        b.on("change", fn(e: UiEvent) { self.slide(e.index) })
        b.close()
        b.open("HStack")  // controls_page.bx:25
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.open("Label")  // controls_page.bx:26
        b.text("Shots")
        b.number("grow", (1) as f64)
        b.close()
        b.open("Stepper")  // controls_page.bx:27
        b.key("{"shots"}")
        b.number("min", (0.0) as f64)
        b.number("max", (10.0) as f64)
        b.number("value", (self.shots) as f64)
        b.number("step", (1.0) as f64)
        b.on("change", fn(e: UiEvent) { self.step(e.index) })
        b.close()
        b.close()
        b.open("Label")  // controls_page.bx:31
        b.text("Progress {self.intensity}%")
        b.close()
        b.open("ProgressBar")  // controls_page.bx:32
        b.key("{"progress"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.intensity) as f64)
        b.close()
        b.open("LevelIndicator")  // controls_page.bx:33
        b.key("{"level"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.intensity) as f64)
        b.close()
        b.open("HStack")  // controls_page.bx:35
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.open("Label")  // controls_page.bx:36
        b.text("Roast")
        b.number("grow", (1) as f64)
        b.close()
        b.open("ComboBox")  // controls_page.bx:37
        b.key("{"roast"}")
        b.items(self.roasts)
        b.number("selected", (self.roast) as f64)
        b.on("change", fn(e: UiEvent) { self.choose_roast(e.index) })
        b.close()
        b.close()
        b.open("Segmented")  // controls_page.bx:41
        b.key("{"grind"}")
        b.items(self.grinds)
        b.number("selected", (self.grind) as f64)
        b.on("change", fn(e: UiEvent) { self.choose_grind(e.index) })
        b.close()
        b.open("Separator")  // controls_page.bx:44
        b.number("height", (1) as f64)
        b.close()
        b.open("GroupBox")  // controls_page.bx:46
        b.text("Order options")
        b.number("height", (72) as f64)
        b.open("Label")  // controls_page.bx:47
        b.text("Beans, milk, and cup size")
        b.close()
        b.close()
        b.open("Disclosure")  // controls_page.bx:50
        b.key("{"details"}")
        b.text("Order details")
        b.flag("open", self.details == 1)
        b.number("height", (80) as f64)
        b.on("change", fn(e: UiEvent) { self.set_details(e.index) })
        b.open("Button")  // controls_page.bx:52
        b.key("{"detail"}")
        b.text("Roasted today")
        b.on("click", fn(e: UiEvent) { self.note() })
        b.close()
        b.close()
        b.open("Label")  // controls_page.bx:56
        b.key("{"summary"}")
        b.text("{self.summary()}")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.close()
    }
}
