// Generated from examples/showcase/site/gallery_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is gallery_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change gallery_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/gallery_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import latte.controls
import {view} from latte.annotations

/// Five hundred rows built as they are asked for, so the table has something
/// to be virtual about without holding anything.
pub class GalleryRows implements controls.TableRows {
    pub fn init() {}
    pub fn row_count() -> int { return 500 }
    pub fn cell(row: int, column: int) -> string {
        if column == 0 { return "#{1000 + row}" }
        if column == 1 {
            if row % 3 == 0 { return "Espresso" }
            if row % 3 == 1 { return "Latte" }
            return "Cortado"
        }
        return "{2 + row % 4} min"
    }
}

/// Every control latte draws, on one screen.
///
/// `<Canvas>` is the one tag missing and it is not an oversight: see
/// `docs/unfinished.md`. The shapes below ARE canvas nodes.
@view
pub partial class GalleryPage extends compose.Component {
    pub milk: bool = false
    pub size: int = 1
    pub notify: bool = true
    pub strength: f64 = 45.0
    pub shots: f64 = 2.0
    pub orders: int = 0

    pub name: string = "Julfikar"
    pub query: string = ""
    pub secret: string = ""
    pub note: string = ""

    pub drinks: List<string> = ["Espresso", "Latte", "Cortado", "Flat white"]
    pub drink: int = 2
    pub roasts: List<string> = ["Light", "Medium", "Dark"]
    pub roast: int = 1
    pub sizes: List<string> = ["Small", "Medium", "Large"]
    pub tabs: List<string> = ["Recipe", "Notes"]
    pub tab: int = 0

    pub details: bool = false
    pub divider: f64 = 140.0

    pub rows: GalleryRows
    pub titles: List<string> = ["Order", "Drink", "Wait"]
    pub widths: List<f64> = [120.0, 160.0, 100.0]
    pub row: int = -1

    pub fn init() { self.rows = new GalleryRows(); super.init() }

    pub fn headline() -> string {
        return "Thirty-one controls, one .bx file. {self.orders} order(s) placed."
    }

    pub fn order() { self.orders = self.orders + 1; self.request_render() }
    pub fn undo() { if self.orders > 0 { self.orders = self.orders - 1; self.request_render() } }
    pub fn clear() { self.orders = 0; self.request_render() }

    pub fn set_milk(value: int) { self.milk = value == 1; self.request_render() }
    pub fn set_notify(value: int) { self.notify = value == 1; self.request_render() }
    pub fn set_details(value: int) { self.details = value == 1; self.request_render() }
    pub fn set_strength(value: int) { self.strength = value as f64; self.request_render() }
    pub fn set_shots(value: int) { self.shots = value as f64; self.request_render() }
    pub fn set_drink(index: int) { self.drink = index; self.request_render() }
    pub fn set_roast(index: int) { self.roast = index; self.request_render() }
    pub fn set_tab(index: int) { self.tab = index; self.request_render() }
    pub fn select_row(index: int) { self.row = index; self.request_render() }

    /// A radio group is three controls and one fact. The one switching OFF
    /// raises a change too, and acting on it would clear the new choice.
    pub fn set_size(which: int, on: int) {
        if on != 1 { return }
        self.size = which
        self.request_render()
    }

    pub fn recipe() -> string {
        return "{self.roasts[self.roast]} · {self.drinks[self.drink]} · {self.sizes[self.size]}"
    }

    pub fn extras() -> string {
        let milk: string = if self.milk { "with milk" } else { "black" }
        let told: string = if self.notify { "notify" } else { "quiet" }
        return "{self.shots as int} shots, strength {self.strength as int}, {milk}, {told}"
    }

    pub fn row_note() -> string {
        if self.row < 0 { return "No row selected" }
        return "Row {self.row} selected"
    }
}

partial class GalleryPage {
    pub override fn render(b: Builder) {
        b.open("ScrollView")  // gallery_page.bx:1
        b.number("height", (520) as f64)
        b.open("VStack")  // gallery_page.bx:2
        b.number("padding", (16) as f64)
        b.number("spacing", (10) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:3
        b.text("Gallery")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:4
        b.key("{"gallery-note"}")
        b.text("{self.headline()}")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("HStack")  // gallery_page.bx:6
        b.number("spacing", (16) as f64)
        b.word("align", "start")
        b.flag("wrap", true)
        b.open("VStack")  // gallery_page.bx:8
        b.number("grow", (1) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:9
        b.text("ACTIONS")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:10
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.flag("wrap", true)
        b.open("Button")  // gallery_page.bx:11
        b.key("{"act-order"}")
        b.text("Order")
        b.on("click", fn(e: UiEvent) { self.order() })
        b.close()
        b.open("Button")  // gallery_page.bx:12
        b.key("{"act-undo"}")
        b.text("Undo")
        b.on("click", fn(e: UiEvent) { self.undo() })
        b.close()
        b.open("Button")  // gallery_page.bx:13
        b.key("{"act-clear"}")
        b.text("Clear")
        b.on("click", fn(e: UiEvent) { self.clear() })
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:15
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.flag("wrap", true)
        b.open("Button")  // gallery_page.bx:16
        b.key("{"act-normal"}")
        b.text("Normal")
        b.close()
        b.open("Button")  // gallery_page.bx:17
        b.key("{"act-prominent"}")
        b.text("Prominent")
        b.flag("prominent", true)
        b.close()
        b.open("Button")  // gallery_page.bx:18
        b.key("{"act-off"}")
        b.text("Disabled")
        b.flag("enabled", false)
        b.close()
        b.open("Button")  // gallery_page.bx:19
        b.key("{"act-prominent-off"}")
        b.text("Prominent off")
        b.flag("prominent", true)
        b.flag("enabled", false)
        b.close()
        b.close()
        b.open("Separator")  // gallery_page.bx:22
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:23
        b.text("TOGGLES")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:24
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.flag("wrap", true)
        b.open("CheckBox")  // gallery_page.bx:25
        b.key("{"tog-on"}")
        b.text("Checked")
        b.flag("checked", true)
        b.close()
        b.open("CheckBox")  // gallery_page.bx:26
        b.key("{"tog-off"}")
        b.text("Unchecked")
        b.close()
        b.open("CheckBox")  // gallery_page.bx:27
        b.key("{"tog-dis"}")
        b.text("Disabled")
        b.flag("checked", true)
        b.flag("enabled", false)
        b.close()
        b.close()
        b.open("CheckBox")  // gallery_page.bx:29
        b.key("{"tog-milk"}")
        b.text("Include milk")
        b.flag("checked", self.milk)
        b.on("change", fn(e: UiEvent) { self.set_milk(e.index) })
        b.close()
        b.open("HStack")  // gallery_page.bx:31
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.flag("wrap", true)
        b.open("RadioButton")  // gallery_page.bx:32
        b.key("{"tog-small"}")
        b.text("Small")
        b.flag("checked", self.size == 0)
        b.on("change", fn(e: UiEvent) { self.set_size(0, e.index) })
        b.close()
        b.open("RadioButton")  // gallery_page.bx:34
        b.key("{"tog-medium"}")
        b.text("Medium")
        b.flag("checked", self.size == 1)
        b.on("change", fn(e: UiEvent) { self.set_size(1, e.index) })
        b.close()
        b.open("RadioButton")  // gallery_page.bx:36
        b.key("{"tog-large"}")
        b.text("Large")
        b.flag("checked", self.size == 2)
        b.on("change", fn(e: UiEvent) { self.set_size(2, e.index) })
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:39
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:40
        b.text("Notify when ready")
        b.number("grow", (1) as f64)
        b.close()
        b.open("Switch")  // gallery_page.bx:41
        b.key("{"tog-notify"}")
        b.flag("checked", self.notify)
        b.on("change", fn(e: UiEvent) { self.set_notify(e.index) })
        b.close()
        b.close()
        b.open("Separator")  // gallery_page.bx:45
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:46
        b.text("TYPOGRAPHY")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("Label")  // gallery_page.bx:47
        b.text("Large title")
        b.number("font_size", (26) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:48
        b.text("Title")
        b.number("font_size", (22) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:49
        b.text("Headline")
        b.number("font_size", (13) as f64)
        b.number("font_weight", (5) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:50
        b.text("Body — the control font at its default size")
        b.close()
        b.open("Label")  // gallery_page.bx:51
        b.text("Footnote")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("Separator")  // gallery_page.bx:53
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:54
        b.text("VALUES")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:55
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:56
        b.key("{"val-strength"}")
        b.text("Strength {self.strength as int}")
        b.number("width", (92) as f64)
        b.close()
        b.open("Slider")  // gallery_page.bx:57
        b.key("{"val-slider"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.strength) as f64)
        b.number("step", (5.0) as f64)
        b.number("grow", (1) as f64)
        b.on("change", fn(e: UiEvent) { self.set_strength(e.index) })
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:60
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:61
        b.key("{"val-shots"}")
        b.text("Shots {self.shots as int}")
        b.number("width", (92) as f64)
        b.close()
        b.open("Stepper")  // gallery_page.bx:62
        b.key("{"val-stepper"}")
        b.number("min", (0.0) as f64)
        b.number("max", (6.0) as f64)
        b.number("value", (self.shots) as f64)
        b.number("step", (1.0) as f64)
        b.on("change", fn(e: UiEvent) { self.set_shots(e.index) })
        b.close()
        b.open("Box")  // gallery_page.bx:64
        b.number("grow", (1) as f64)
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:66
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:67
        b.text("Brewing")
        b.number("width", (92) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("ProgressBar")  // gallery_page.bx:68
        b.key("{"val-progress"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.strength) as f64)
        b.number("grow", (1) as f64)
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:70
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:71
        b.text("Working")
        b.number("width", (92) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("ProgressBar")  // gallery_page.bx:72
        b.key("{"val-spin"}")
        b.flag("indeterminate", true)
        b.number("grow", (1) as f64)
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:74
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:75
        b.text("Bean level")
        b.number("width", (92) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("LevelIndicator")  // gallery_page.bx:76
        b.key("{"val-level"}")
        b.number("min", (0.0) as f64)
        b.number("max", (100.0) as f64)
        b.number("value", (self.strength) as f64)
        b.number("grow", (1) as f64)
        b.close()
        b.close()
        b.close()
        b.open("VStack")  // gallery_page.bx:80
        b.number("grow", (1) as f64)
        b.number("spacing", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:81
        b.text("TEXT")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:82
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:83
        b.text("Name")
        b.number("width", (60) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("TextField")  // gallery_page.bx:84
        b.key("{"txt-name"}")
        b.on("commit", fn(_e: UiEvent) { self.name = _e.text })
        b.a11y_label("Your name")
        b.number("grow", (1) as f64)
        b.text("{self.name}")
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:86
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:87
        b.text("Search")
        b.number("width", (60) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("SearchField")  // gallery_page.bx:88
        b.key("{"txt-search"}")
        b.on("commit", fn(_e: UiEvent) { self.query = _e.text })
        b.a11y_label("Search orders")
        b.number("grow", (1) as f64)
        b.text("{self.query}")
        b.close()
        b.close()
        b.open("HStack")  // gallery_page.bx:90
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:91
        b.text("Secret")
        b.number("width", (60) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("SecureField")  // gallery_page.bx:92
        b.key("{"txt-secret"}")
        b.on("commit", fn(_e: UiEvent) { self.secret = _e.text })
        b.a11y_label("Password")
        b.number("grow", (1) as f64)
        b.text("{self.secret}")
        b.close()
        b.close()
        b.open("TextArea")  // gallery_page.bx:94
        b.key("{"txt-note"}")
        b.on("commit", fn(_e: UiEvent) { self.note = _e.text })
        b.number("height", (52) as f64)
        b.a11y_label("Order notes")
        b.text("{self.note}")
        b.close()
        b.open("Separator")  // gallery_page.bx:96
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:97
        b.text("CHOICES")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:98
        b.number("spacing", (6) as f64)
        b.word("align", "center")
        b.open("Label")  // gallery_page.bx:99
        b.text("Drink")
        b.number("width", (60) as f64)
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("ComboBox")  // gallery_page.bx:100
        b.key("{"chc-drink"}")
        b.items(self.drinks)
        b.number("selected", (self.drink) as f64)
        b.on("change", fn(e: UiEvent) { self.set_drink(e.index) })
        b.close()
        b.open("Box")  // gallery_page.bx:102
        b.number("grow", (1) as f64)
        b.close()
        b.close()
        b.open("Segmented")  // gallery_page.bx:104
        b.key("{"chc-roast"}")
        b.items(self.roasts)
        b.number("selected", (self.roast) as f64)
        b.on("change", fn(e: UiEvent) { self.set_roast(e.index) })
        b.close()
        b.open("TabView")  // gallery_page.bx:106
        b.key("{"chc-tabs"}")
        b.labels(self.tabs)
        b.number("selected", (self.tab) as f64)
        b.number("height", (92) as f64)
        b.on("change", fn(e: UiEvent) { self.set_tab(e.index) })
        b.open("VStack")  // gallery_page.bx:108
        b.number("padding", (8) as f64)
        b.number("spacing", (2) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:109
        b.key("{"chc-recipe"}")
        b.text("{self.recipe()}")
        b.close()
        b.open("Label")  // gallery_page.bx:110
        b.key("{"chc-extras"}")
        b.text("{self.extras()}")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.close()
        b.open("VStack")  // gallery_page.bx:112
        b.number("padding", (8) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:113
        b.key("{"chc-notes"}")
        b.text("{if self.note == "" { "No notes yet." } else { self.note }}")
        b.close()
        b.close()
        b.close()
        b.open("Separator")  // gallery_page.bx:117
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:118
        b.text("CONTAINERS")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("GroupBox")  // gallery_page.bx:119
        b.text("Order options")
        b.number("height", (58) as f64)
        b.open("Label")  // gallery_page.bx:120
        b.text("Beans, milk, and cup size")
        b.close()
        b.close()
        b.open("Disclosure")  // gallery_page.bx:122
        b.key("{"con-details"}")
        b.text("Order details")
        b.flag("open", self.details)
        b.number("height", (62) as f64)
        b.on("change", fn(e: UiEvent) { self.set_details(e.index) })
        b.open("Button")  // gallery_page.bx:124
        b.key("{"con-roasted"}")
        b.text("Roasted today")
        b.on("click", fn(e: UiEvent) { self.order() })
        b.close()
        b.close()
        b.open("SplitView")  // gallery_page.bx:127
        b.key("{"con-split"}")
        b.flag("stacked", false)
        b.number("divider", (self.divider) as f64)
        b.number("height", (64) as f64)
        b.open("VStack")  // gallery_page.bx:128
        b.number("padding", (6) as f64)
        b.word("align", "stretch")
        b.word("background", "#f6f6f8")
        b.open("Label")  // gallery_page.bx:129
        b.text("Drag the divider")
        b.close()
        b.close()
        b.open("VStack")  // gallery_page.bx:131
        b.number("padding", (6) as f64)
        b.word("align", "stretch")
        b.open("Label")  // gallery_page.bx:132
        b.key("{"con-across"}")
        b.text("{self.divider as int} across")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.close()
        b.close()
        b.open("Label")  // gallery_page.bx:137
        b.text("A Grid places its children on named tracks.")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("Grid")  // gallery_page.bx:138
        b.word("columns", "72 1fr auto")
        b.number("column_gap", (8) as f64)
        b.number("row_gap", (4) as f64)
        b.open("Label")  // gallery_page.bx:139
        b.text("Roast")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:140
        b.key("{"grd-roast"}")
        b.text("{self.roasts[self.roast]}")
        b.close()
        b.open("Label")  // gallery_page.bx:141
        b.text("•")
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("Label")  // gallery_page.bx:142
        b.text("Drink")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:143
        b.key("{"grd-drink"}")
        b.text("{self.drinks[self.drink]}")
        b.close()
        b.open("Label")  // gallery_page.bx:144
        b.text("•")
        b.word("text_color", "#8a8f9c")
        b.close()
        b.close()
        b.open("Label")  // gallery_page.bx:147
        b.text("A Container holds a subtree and places nothing itself.")
        b.word("text_color", "#8a8f9c")
        b.number("font_size", (10) as f64)
        b.close()
        b.open("Container")  // gallery_page.bx:148
        b.number("height", (30) as f64)
        b.word("background", "#f6f6f8")
        b.number("corner_radius", (6) as f64)
        b.close()
        b.close()
        b.close()
        b.open("Separator")  // gallery_page.bx:152
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:153
        b.text("DRAWING")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("HStack")  // gallery_page.bx:154
        b.number("spacing", (12) as f64)
        b.word("align", "center")
        b.flag("wrap", true)
        b.open("Box")  // gallery_page.bx:155
        b.number("width", (76) as f64)
        b.number("height", (48) as f64)
        b.open("Rectangle")  // gallery_page.bx:156
        b.word("fill", "#2f6f4f")
        b.number("clip_radius", (10) as f64)
        b.close()
        b.close()
        b.open("Box")  // gallery_page.bx:158
        b.number("width", (76) as f64)
        b.number("height", (48) as f64)
        b.open("Ellipse")  // gallery_page.bx:159
        b.word("fill", "#365eea")
        b.word("stroke", "#101828")
        b.number("stroke_width", (2) as f64)
        b.close()
        b.close()
        b.open("Box")  // gallery_page.bx:161
        b.number("width", (76) as f64)
        b.number("height", (48) as f64)
        b.open("Path")  // gallery_page.bx:162
        b.text("M8 42 L38 8 L68 42 Z")
        b.word("fill", "#b03030")
        b.word("stroke", "#5a1414")
        b.number("stroke_width", (2) as f64)
        b.close()
        b.close()
        b.open("Box")  // gallery_page.bx:164
        b.number("width", (76) as f64)
        b.number("height", (48) as f64)
        b.open("Rectangle")  // gallery_page.bx:165
        b.word("gradient_start", "#d5a665")
        b.word("gradient_end", "#87582f")
        b.number("clip_radius", (8) as f64)
        b.word("shadow_color", "#00000055")
        b.number("shadow_blur", (10) as f64)
        b.number("shadow_dy", (3) as f64)
        b.close()
        b.close()
        b.open("Box")  // gallery_page.bx:168
        b.number("width", (48) as f64)
        b.number("height", (48) as f64)
        b.open("ResourceImage")  // gallery_page.bx:169
        b.text("mark.png")
        b.close()
        b.close()
        b.close()
        b.open("Separator")  // gallery_page.bx:173
        b.number("height", (1) as f64)
        b.close()
        b.open("Label")  // gallery_page.bx:174
        b.text("TABLE — 500 rows, only the visible ones are read")
        b.number("font_size", (10) as f64)
        b.word("text_color", "#8a8f9c")
        b.close()
        b.open("Table")  // gallery_page.bx:175
        b.key("{"gal-orders"}")
        b.columns(self.titles)
        b.column_widths(self.widths)
        b.table_source(self.rows)
        b.number("height", (160) as f64)
        b.on("select", fn(e: UiEvent) { self.select_row(e.index) })
        b.close()
        b.open("Label")  // gallery_page.bx:178
        b.key("{"gal-row"}")
        b.text("{self.row_note()}")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.close()
    }
}
